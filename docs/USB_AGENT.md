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

## Supported requests

| operation | Required fields beyond operation and homeID |
| --- | --- |
| rename_accessory | objectID (accessory UUID), name |
| set_characteristic | objectID (characteristic UUID), value (bool, number, string) |
| create_scene | name, actions (characteristicID/value pairs) |
| update_scene | objectID (scene UUID), actions; optional name |
| rename_scene | objectID (scene UUID), name |
| run_scene | objectID (scene UUID) |
| create_timer | name, future fireDate (ISO 8601 UTC), sceneIDs; optional recurrenceMinutes and enabled |
| update_automation | objectID (trigger UUID); name, sceneIDs, or enabled |

`update_scene` replaces all existing scene actions. `update_automation` can
rename, replace attached scenes, and enable/disable an existing trigger; it does
not edit the trigger's events or predicates. `create_timer` is disabled unless
`enabled` is true. Pairing accessories, creating event automations, and deleting
Home objects are not exposed by this first version.

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
Live automatic writes are still to be verified against a user-selected accessory
or scene; deployment itself makes no Home configuration changes.

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
