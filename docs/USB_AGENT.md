# HomeKitten paired-device bridge

The installed iPhone app provides configuration reads and automatic HomeKit
changes to a paired Mac through Xcode's device file service. On **Agent Access**,
enable **Allow changes for this session** and tap **Connect & Allow Changes**.
This authorization is remembered across app launches until **Disconnect** is
tapped. **Connect Read Only** provides inventory access without accepting writes.
No paid Apple Developer membership or additional utility is required.

The bridge is owned by the app, not the Agent Access screen: navigation does not
disconnect it. When backgrounded, the app requests finite background execution
time from iOS. When that expires, it publishes a disconnected snapshot and
pauses. It resumes automatically on foreground return with a new session UUID
and the remembered access mode. There is no promise of persistent background
availability. The phone must be connected through the paired device service;
USB is verified, wireless Xcode pairing is not yet verified. Locked-device
restrictions can prevent Mac transfers even during background execution.

## Mac client

Find your phone with `xcrun devicectl list devices`, then:

```sh
python3 scripts/homekit_agent.py --device <phone-UDID> inventory
python3 scripts/homekit_agent.py --device <phone-UDID> submit request.json
python3 scripts/homekit_agent.py --device <phone-UDID> result <transaction-UUID>
```

The client can also run as a standard stdio MCP server:

```sh
python3 /path/to/homekitten/scripts/homekit_agent.py --device <phone-UDID> mcp
```

Its tools are `home_inventory`, `home_change_execute`, and `home_change_result`.
The older `home_change_propose` call name remains accepted as an alias; it now
executes automatically when the connection has write access.
Use the returned UUIDs rather than names to target objects. Inventory values
are explicitly marked as cached; a successful writable-characteristic operation
attempts read-back if supported. A HomeKit completion callback is not proof of
physical accessory behavior.

## Live characteristic reads

`home_read_characteristics` requests fresh HomeKit reads for 1–10 unique
`characteristicIDs` in a specified `homeID`, using UUIDs from inventory.
`home_inventory` remains a fast cached snapshot. Successful entries return
`state: "read"`, `value`, and `readAt`. Failed entries return an error and no
value, including when the three-second per-characteristic timeout expires.
Mixed success and failure preserve each individual outcome; there is no cached
fallback. Responses identify their source as `homekit_read`.

The tool waits up to 40 seconds. If a request remains `queued` or `executing`,
retrieve it with `home_read_result` and the returned `id` rather than submitting
another read. Queued requests can wait behind another read. App interruption
can leave an executing result; a new read cannot change an accessory.

Reads work in active read-only sessions and sessions with changes allowed.
They use separate `reads/` and `read-responses/` queues, validate the current
session and Home/characteristic UUIDs, and never enter the write executor or
create configuration backups. The signed Mac app must be running, or the
paired iOS app must be available. Homebridge freshness depends on the plugin's
read implementation; a HomeKit read is not independent physical confirmation.

The CLI accepts a local request JSON containing `homeID` and
`characteristicIDs`:

```sh
python3 scripts/homekit_agent.py --local-bridge ~/Documents/AgentBridge read request.json
python3 scripts/homekit_agent.py --local-bridge ~/Documents/AgentBridge read-result <request-UUID>
```

Keep requests and outcomes local. Reconnect existing MCP clients after updating
the Python client so they discover the new tools.

## Supported requests

| operation | Required fields beyond operation and homeID |
| --- | --- |
| rename_accessory | objectID (accessory UUID), name |
| create_room | name (must be unique in the selected Home) |
| assign_accessory | objectID (accessory UUID), roomID (destination room UUID in the same Home) |
| set_characteristic | objectID (characteristic UUID), value (bool, number, string) |
| create_scene | name, actions (characteristicID/value pairs) |
| update_scene | objectID (scene UUID), actions; optional name |
| rename_scene | objectID (scene UUID), name |
| run_scene | objectID (scene UUID) |
| delete_scene | objectID (unreferenced, user-defined scene UUID); no other change fields |
| delete_automation | objectID (trigger UUID); no other change fields; shared scenes retained |
| create_timer | name, future fireDate (ISO 8601 UTC), sceneIDs; optional recurrenceMinutes and enabled |
| create_event_automation | name, events, sceneIDs; optional enabled, endEvents, conditions, recurrenceWeekdays, executeOnce |
| update_automation | objectID (trigger UUID); name, sceneIDs, enabled, or event rule fields |

`update_scene` replaces all existing scene actions. `update_automation` can
rename, replace attached scenes, enable/disable, and edit event automation rules.
`create_timer` and `create_event_automation` default to disabled. Creation validates
all referenced characteristics/scenes before adding the disabled trigger; enabling
is the last step. Rule updates disable an enabled trigger first, then restore its
prior enabled state (or the requested `enabled`) after all edits succeed. A partial
failure can leave the trigger disabled; inspect its transaction and inventory
before retrying. Rules on timer/unsupported trigger types are rejected.
Scene and automation deletion require `deletionWritesVersion: 1`. Deletion is
permanent: a scene referenced by any automation (even disabled) or owned by
HomeKit is rejected. Automation deletion retains shared user-defined scenes;
HomeKit-owned actions belong to the deleted automation and may be removed by HomeKit. Remove references explicitly first. The app's
scene and automation detail screens expose Delete with a confirmation; MCP uses
the existing authorized session without another approval. Both routes save a Home
backup and public-API automation-rule snapshot before deletion and verify absence
after the callback. Rule snapshots are evidence, not automatic event-rule recovery.
A failed or interrupted deletion must be inspected before retrying. Existing MCP
connections must reconnect to discover the new operation enum. Pairing and
accessory/room/Home/user deletion remain unavailable.

### Event automation writes

Inventory advertises `automationWritesVersion: 1`; clients reject rule writes to
older apps rather than silently ignoring fields. Existing MCP clients must
reconnect to discover the extended `home_change_execute` schema.

`events` replaces all start events (1–32); `endEvents` replaces all end events
(0–32). Multiple start events are alternative triggers. Supported event objects:

- `{"kind":"characteristic","characteristicID":"<UUID>","value":false}`:
  exact state; characteristic must be readable and notify changes.
- `{"kind":"calendar","hour":18,"minute":0}`: local time of day.
- `{"kind":"significant_time","significantEvent":"sunset","offsetMinutes":-18}`:
  sunrise/sunset, with signed offset from -720 to 720 minutes.
- `{"kind":"presence","presenceEvent":"first_entry","presenceUser":"home_users"}`:
  first_entry/last_exit and home_users/current_user.
- `{"kind":"duration","durationSeconds":60}`: end events only; at most 86400 seconds.

`conditions` replaces the entire predicate using a declarative tree. A leaf has
`kind: characteristic`, an exact `characteristicID`, `value`, and optional
`comparison` (equal by default; also not_equal, less_than, greater_than, at_most,
at_least). Ordering requires a numeric characteristic. Compound nodes have
`kind: all` (AND), `any` (OR), or `not` plus `children`. NOT requires one child;
AND/OR accept 1–32. Nesting is bounded to eight levels. UUIDs are resolved within
the selected Home; conditions require readable characteristics and compatible
scalar values. Raw predicate strings/code are never accepted. Conditions are
created with HomeKit's characteristic predicate factory and evaluated by the Home
hub, never against cached inventory values.

`additionalConditions` appends a declarative condition with AND to the original
native predicate, preserving existing presence, time, OR and custom-user clauses.
It requires `conditionCompositionVersion: 1` and cannot be combined with
`conditions` or `clearConditions`. A presence leaf is
`{"kind":"presence","presence":"at_home","presenceUser":"home_users"}`;
`not_home` and `current_user` are also supported. Presence leaves require that
same capability. The app editor defaults to append and offers explicit replacement.
Some legacy accessory references cannot be edited by HomeKit: retain the original
rule and inspect the failed transaction rather than replacing unknown conditions.
Updates disable the rule while editing; after a failed update inspect its enabled
state and restore its previous flag if necessary.

Omit `conditions` to preserve an existing predicate. `clearConditions: true`
explicitly removes it and cannot be combined with `conditions`. An empty
`endEvents` clears end events. `recurrenceWeekdays` replaces weekly recurrence
with unique Foundation weekday numbers (Sunday=1 through Saturday=7); `[]` means
every day. `executeOnce` controls repeat behavior. Omitted update fields remain
unchanged. Event and scene replacement requires the complete desired lists.

For example, trigger on either protection switch turning off, but unlock only
when both are off:

```json
{
  "operation": "create_event_automation",
  "homeID": "<Home UUID>",
  "name": "Sonos Unlock After Shabbos or Yom Tov",
  "events": [
    {"kind":"characteristic","characteristicID":"<Shabbos On UUID>","value":false},
    {"kind":"characteristic","characteristicID":"<Yom Tov On UUID>","value":false}
  ],
  "conditions": {"kind":"all","children":[
    {"kind":"characteristic","characteristicID":"<Shabbos On UUID>","value":false},
    {"kind":"characteristic","characteristicID":"<Yom Tov On UUID>","value":false}
  ]},
  "sceneIDs": ["<Sonos Unlocked scene UUID>"],
  "enabled": true
}
```

Example request file, using UUIDs from inventory:

```json
{
  "operation": "set_characteristic",
  "homeID": "00000000-0000-0000-0000-000000000001",
  "objectID": "00000000-0000-0000-0000-000000000002",
  "value": true
}
```

## Connection authorization and persistence

The Mac submits a request containing a unique transaction UUID and the current
session UUID. HomeKitten validates object identity, writable permissions, scalar
types, and numeric limits before executing automatically in a connection with
write access. No per-change approval is shown. Read-only and stale-session
requests are rejected by the phone. The Mac client also refuses to submit a
write if the current inventory reports `writesAllowed: false`. The phone shows
the current or last request so the operation remains visible.

Before applying a change, HomeKitten records that the transaction has been
consumed, then saves a configuration backup. Replaying the same transaction
does not apply it again. A disconnected/background-expired session cannot start
another operation; an already executing operation may finish. Multi-step HomeKit operations are not atomic; failures
are reported as potentially partial, and existing backup/restore UI remains
available. An interrupted `executing` result is indeterminate: inspect Home
before submitting a new request.

The private app container holds `Documents/AgentBridge/inventory.json`,
`incoming/`, `responses/`, and `backups/`. These contain private Home metadata
and, for backups, scene values. They stay on the device and are not source
artifacts. The Mac client uses temporary directories and does not log or persist
copies automatically. Only trusted paired Macs should access the device.

## Verified and outstanding

On October 6, 2026, signed iPhone and unsigned Catalyst builds passed, along with
client protocol, freshness rejection, read-only rejection, and request identity tests. Installation,
launch, live inventory retrieval over the paired device file service, and
rejection of a nonexistent accessory UUID were verified on a physical iPhone.
That initial deployment made no Home configuration changes.

On October 10, 2026, the signed Mac Catalyst update was installed with the
registered Apple Development certificate; signed iOS and unsigned Catalyst
builds and all 18 client/serializer tests passed. A fresh stdio MCP session
verified `automationWritesVersion: 1`, created the requested Sonos scenes and
guarded exit automation, and updated the existing entry automation. Independent
inventory confirmed both triggers were enabled and active, all scene actions,
and the both-modes-off predicate. Full physical mode transitions were not
performed because the existing entry rule also operates appliances and lights.

## Accessory metadata

Inventory includes HomeKit manufacturer, model, firmware version, category and
bridge identity. Manufacturer/model/serial/firmware/hardware characteristics are
read once per connection, with `metadataReadStatus` (`pending`, `read`, `failed`,
or `not_requested`) per characteristic. Other values remain cached. Unsupported
or unavailable metadata stays empty; accessory firmware is also exposed directly
from HomeKit, since its characteristic value may remain unavailable.

Inventory also exports HomeKit zones with room UUID membership. Service groups
retain their service UUIDs; clients can resolve accessory membership without
matching display names.

## Signed Mac local transport

A paid-team signed Mac Catalyst build is now verified with live Home access.
Use `--local-bridge ~/Documents/AgentBridge` instead of `--device <UDID>`
for the installed Mac app. This provides the same inventory, submit, result
and optional stdio MCP interface with no network listener. Local request
files are published atomically; the client rejects traversal outside the
bridge directory. The Mac app stays connected while minimized, provided
it remains running and the Mac stays awake. iPadOS still uses finite
background execution. Do not mix object UUIDs from different source clients.

## Automation rules inventory

Inventory version 2 now includes `automationRulesVersion: 1` and
`automationRulesSource: "HomeKit public API"`. Existing keys and write operations
are retained. Event/predicate writes are described above and independently
advertised by `automationWritesVersion`.

Each event automation exposes `events`, `endEvents`, `predicate`, `recurrences`,
`executeOnce`, and activation state (including missing hub/location permission).
Characteristic and threshold events include stable characteristic/service/accessory
references and trigger values or ranges. Calendar events expose date components;
sunrise/sunset events include signed offset components. Duration events use seconds.
Presence events expose event/user scope; custom user membership is explicitly
marked unavailable because the public API does not expose it. Location events
include the exposed region and entry/exit flags. Timer triggers include their fire
date, time zone, and recurrence components. Unspecified components remain absent;
weekday numbers follow Foundation (Sunday 1, Saturday 7).

Predicates retain their original `format` and a structured tree: AND/OR/NOT,
comparison operator/modifier/options, and expressions. Characteristic constants
resolve to UUIDs; date components, significant-time and presence constants retain
structured details. Unknown predicates, expressions, events, or values include
`supported: false`; unknown triggers report `rulesStatus: "unsupportedTrigger"`.
A null predicate means HomeKit returned no predicate, not that hidden app/shortcut
logic has been inspected. Predicates are never evaluated against cached values.

Each automation also embeds its `actionSets`, and `scenes` includes the union of
home scenes and trigger-owned action sets, deduplicated by UUID. This closes
previous missing scene references. Actions unavailable through the public API are
marked unsupported rather than silently omitted. Exported trigger-owned actions
are for inspection; scene write resolution still follows the existing supported
HomeKit scene scope. Apple Home shortcut internals and third-party runtime rules
are not exposed by this inventory. All rules and location data remain private
bridge-container data and must not be committed.

Run `python3 -m unittest discover -s tests -v` to validate the client and the
production Swift predicate serializer (Swift checks run on macOS). Validate event
exports against a fresh signed-app inventory after installation.

## Network access from Mini-Sefarim

A trusted network client can run the same stdio MCP server over SSH to the Mac.
`scripts/homekit_remote.py` forwards stdin/stdout without copying bridge files,
creating an HTTP service, or changing HomeKit permissions. The existing Mac SSH
account/key and known-host identity must already work. Password prompting and
accepting unknown or changed host keys are disabled. Interrupted writes are not
replayed; retrieve their transaction outcome and inspect state before retrying.

Mini-Sefarim uses its existing `abie-mini` SSH alias and registers this launcher
as `homekitten_network`. The workspace `.mcp.registry.json` holds its non-secret
arguments. If `.local` name resolution fails, `--hostname` selects the Mac's LAN
address while `--host-key-alias abie-mini.local` retains the trusted host identity.
Update the address if the Mac's LAN lease changes; do not disable host checking.

From Projects on Windows:

```powershell
smarthome/.venv/Scripts/python.exe smarthome/scripts/mcp/registry.py --server homekitten_network --apply
```

Verify MCP initialize, tools/list, and a fresh `home_inventory` call from the
Windows host. Registration alone does not establish live access. Refresh MCP
servers or restart Codex to load the connection in an existing chat. HomeKitten
must stay running with Agent Access connected, and the Mac must stay awake.
This path uses the installed signed Mac app; the phone/iPad is not needed.
