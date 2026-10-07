# HomeKitten repository guide

## Purpose and current architecture

HomeKitten is the canonical iPhone/iPad and Mac Catalyst HomeKit manager in this
workspace. Read `README.md` and `docs/USB_AGENT.md` before editing or operating
it. `docs/AGENT_BRIDGE.md` is a historical Mac proposal, not the implemented
transport or current approval policy.

The supported agent paths are the signed Mac app with local files, or the iPhone/iPad app plus
`scripts/homekit_agent.py` on the paired Mac. The paired-device mode uses Xcode's `devicectl` app-container file service;
the phone owns HomeKit calls. Local mode uses the signed Mac app's bridge files
and its own `HMHomeManager`.
There is no HTTP listener, cloud relay, bearer token, or additional app to
install. Do not assume the MCP server has been registered with the running
agent: the Python CLI works directly from the terminal, and `mcp` mode is an
optional stdio tool server.

## User's chosen behavior

- The user explicitly rejected approval for every change. Once **Connect &
  Allow Changes** has been enabled, requested operations execute automatically.
  Do not restore approval sheets or ask the user to approve every ordinary
  in-scope write.
- Connection and write mode are remembered in app settings until **Disconnect**
  is tapped. The bridge is owned by `HomeKittenApp`, not a particular screen.
  Navigating away from Agent Access must not disconnect it.
- On Mac Catalyst, minimizing keeps an enabled bridge running; sleep or quit stops access.
- On iPhone/iPad, foreground return resumes an enabled bridge. Background access is best effort
  through finite UIKit background execution, then pauses on expiration. Never
  claim an always-running iOS server, or add unrelated audio/location/Bluetooth
  background modes to evade suspension.
- A phone-side permission mode is not blanket task authorization: act on the
  user's requested Home objects and changes. Do not run arbitrary scenes or
  create test Home objects merely to demonstrate access.
- Preserve automatic configuration backups, UUID validation, read-only mode,
  session validation, consumed-transaction recording, and outcome reporting.

## Start a fresh session

1. Inspect this repo's branch/status, fetch its intended upstream, and
   fast-forward a clean behind checkout before editing. Preserve unrelated
   changes and divergent state. The Projects superproject has its own rules.
2. Discover the currently connected physical phone:

   ```sh
   xcrun devicectl list devices
   xcodebuild -project HomeKitten.xcodeproj -scheme HomeKitten -showdestinations
   ```

   Use the physical device's actual UDID; do not confuse it with an identically
   named simulator or persist personal device identifiers in source.
3. Read inventory from the paired phone:

   ```sh
   python3 scripts/homekit_agent.py --device <phone-UDID> inventory
   ```

   Verify `active`, fresh `capturedAt`, and `writesAllowed` before changes. The
   client rejects stale snapshots. If disconnected, have the user open
   HomeKitten/unlock the phone. The first enablement is under **Agent Access →
   Connect & Allow Changes**; later app launches normally resume automatically.
4. Resolve exact Home, accessory, scene, trigger, and characteristic UUIDs from
   inventory. Names are search hints, not safe write identifiers. Ambiguous names
   need resolution; never guess a device from another repo's name or inventory.
5. For a requested change, create a small request JSON in an ignored temporary
   location, submit it, and retrieve the returned transaction's result:

   ```sh
   python3 scripts/homekit_agent.py --device <phone-UDID> submit request.json
   python3 scripts/homekit_agent.py --device <phone-UDID> result <transaction-UUID>
   ```

   `submitted` is not success. `executing` after an interruption is indeterminate.
   Inspect current Home state before retrying with a new transaction, because
   HomeKit operations can partially complete. Never automatically replay a write
   just because a transfer or result retrieval failed.

## Scope of the bridge

The current tools are `home_inventory`, `home_change_execute`, and
`home_change_result`. The old `home_change_propose` name is accepted as an alias
and now executes automatically when write access is enabled. Supported
operations and exact request fields are documented in `docs/USB_AGENT.md`.

- Accessory rename and writable scalar characteristic values.
- Scene creation, rename, action replacement, and execution.
- Timer automation creation; existing automation rename, attached-scene
  replacement, and enabled-state updates.

`update_scene` replaces all actions. `create_timer` is disabled unless explicitly
enabled. Event/predicate editing, accessory pairing, Home/user management, and
destructive deletion are not exposed by the bridge. Do not claim they work just
because HomeKit or the manual UI offers related APIs.

Inventory now includes public-API automation events, end events, predicate trees,
recurrence/timing rules, activation state, and trigger-owned action sets. Check
`automationRulesVersion` and unsupported markers before claiming a complete rule
audit; shortcut internals and custom presence-user lists remain unavailable.
This discovery does not add event/predicate editing.

Inventory characteristic values are cached. A characteristic write attempts
read-back when readable. An API result or cached value does not establish
physical device behavior; report physical/visual verification separately.

## Build, validate, install

The physical iPhone build was verified with a free Personal Team and the actual
HomeKit entitlement. Do not tell the user to buy a developer membership for this
verified iPhone path. Paid-team signed Mac Catalyst provisioning and live Home access are now
verified on this machine. Use `--local-bridge ~/Documents/AgentBridge` for
the installed Mac app; it must remain running with the Mac awake. Do not substitute unsigned/ad-hoc
signing for actual HomeKit authorization.

```sh
python3 -m unittest discover -s tests -v
git diff --check
xcodebuild -project HomeKitten.xcodeproj -scheme HomeKitten \
  -destination 'platform=iOS,id=<phone-UDID>' \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcodebuild -project HomeKitten.xcodeproj -scheme HomeKitten \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
```

For code changes, install only after a successful signed iPhone build. Get the
actual output path from Xcode build settings (`TARGET_BUILD_DIR` and
`FULL_PRODUCT_NAME`); do not hard-code another machine's DerivedData path.

```sh
xcrun devicectl device install app --device <phone-UDID> <built-HomeKitten.app>
xcrun devicectl device process launch --device <phone-UDID> abie.ios.homekitten
```

The optional launch argument `--agent-bridge` selects Agent Access in the detail
navigation; it does not grant write permission. A locked phone can allow
installation while rejecting launch. Report that distinction. Do not terminate
the app during an executing HomeKit transaction. Documentation-only releases
do not need an app reinstall.

Mac-specific ScriptingBridge code stays guarded with `canImport(ScriptingBridge)`.
On iPhone the Shortcuts panel opens Apple's app. Preserve the iPhone icon catalog
entry and the 1024×1024 icon. HomeStore authorization is a bit field: check
`.contains(.authorized)`, not exact equality. WiZ name sync is manual; do not
reintroduce automatic device/name changes just from selecting a Home.

## Privacy and publication

Home inventories, request files, responses, backups, device identifiers,
provisioning profiles, certificates/private keys, build output, and screenshots
remain local. Do not commit or force-add them. App runtime files live under
`Documents/AgentBridge/` in the phone's private container; Python client copies
use temporary directories. Summarize counts or targeted objects in diagnostics
instead of dumping full Home metadata unnecessarily.

For requested source changes, validate, commit intended paths, push this child
repo, and verify local HEAD equals its remote. Then update only the `homekitten`
gitlink in Projects, review the staged submodule log, commit/push the root, and
verify both remotes. Preserve unrelated root/child state. Code releases also
complete the signed phone installation and proportionate live verification;
source push alone is not an installed app release.

## Verified baseline and next work

As of October 6, 2026: paid-team builds are installed on the physical iPad and
in `~/Applications/HomeKitten.app` on the Mac. Both have fresh live inventory;
local Mac access continues with the window minimized. Both paid profiles
expire October 6, 2027 Central. Seven client tests and both signed builds pass.
The earlier signed app was installed on the physical iPhone;
live inventory retrieval, invalid-UUID rejection, and version-2
`active: true` / `writesAllowed: true` were confirmed. Signed iPhone and unsigned
Catalyst builds passed, as did five Python client tests. The workspace was clean
after publication. Treat connection state and inventory counts as transient,
and recheck them in a new session.

Still outstanding: a user-selected live write and physical/result verification,
wireless paired-device transport, and live background-expiration/foreground-resume
testing. Do not present those as already verified. Extend capabilities only when
requested; do not make arbitrary Home changes as a fresh-session smoke test.
