# HomeKitten

iPhone, iPad, and Mac Catalyst HomeKit manager. It reads and controls HomeKit accessories, and
manages rooms, groups, scenes, automations, backups, and reassignment.
The Mac version uses Mac Catalyst to access HomeKit.

For agent work or a fresh-session handoff, start with [AGENTS.md](AGENTS.md).
It records the current architecture, operating choices, build/install workflow,
and the distinction between verified behavior and remaining live tests.

## Prerequisites

1. Open `HomeKitten.xcodeproj` in Xcode.
2. Select the HomeKitten target, then Signing & Capabilities.
3. The workspace uses team `J8LT8K7ZG7`, automatic Apple Development signing,
   and stable App ID `abie.ios.homekitten` on every platform. Keep this ID on
   upgrades so the installed app retains its data and privacy identity.
4. Confirm the HomeKit capability remains enabled.

Build from the command line after configuring the team in Xcode:

```sh
xcodebuild -project HomeKitten.xcodeproj -scheme HomeKitten \
  -destination 'platform=macOS,variant=Mac Catalyst' build
```

HomeKit rejects an ad-hoc signature. The signing identity and App ID must belong to a developer team with HomeKit enabled.

From Projects, use the shared certificate-pinned build/verification wrapper:

```sh
python3 scripts/apple_apps.py build homekitten --platform mac
python3 scripts/apple_apps.py build homekitten --platform ios --device <paired-device-UDID>
```

See [the shared app policy](../APPLE_APPS.md). Embedded profiles from builds
signed with revoked certificates must be regenerated.
The iOS entitlement file grants HomeKit only. The Mac Catalyst override adds
the existing Shortcuts Apple Events permissions; those Mac permissions are not
included in iPhone/iPad signatures.

### Connected iPhone

Select the connected phone as the run destination in Xcode, then build and run.
The iPhone build can be provisioned with a free Personal Team; this was verified
on a physical iPhone on October 6, 2026, with the HomeKit entitlement present in
the installed app's signature. Accept Home access on the phone before browsing
homes. Free provisioning expires periodically and requires rebuilding.

```sh
xcodebuild -project HomeKitten.xcodeproj -scheme HomeKitten \
  -destination 'platform=iOS,id=<connected-phone-UDID>' \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

The Mac version lists shortcuts through ScriptingBridge. On iPhone and iPad,
the Shortcuts panel opens Apple's Shortcuts app instead.

## Agent access from a paired Mac

On iPhone, open **Agent Access**, enable **Allow changes for this session**, and
tap **Connect & Allow Changes** once. The Mac client uses Xcode's paired-device
file service to read configuration and execute changes automatically.
Access works from every screen and reconnects when the app opens until you tap
**Disconnect**. iOS grants only limited background runtime; access pauses when
that expires and resumes when the app returns. Device transfer may require the
phone to be unlocked.
No additional app, paid membership, LAN server, or bearer token is needed.
See [USB agent usage](docs/USB_AGENT.md) for CLI and MCP setup.
The inventory exposes automation events, conditions, recurrence and timing rules,
plus trigger-owned actions, with explicit markers for unavailable details.

The original [Mac bridge proposal](docs/AGENT_BRIDGE.md) is historical. The
implemented iPhone design is documented in [USB agent usage](docs/USB_AGENT.md).

## Paid development builds and local Mac bridge

The enrolled Developer Team now provisions iPad and Mac Catalyst development
builds with HomeKit. Fresh paid profiles were verified on October 6, 2026,
expiring October 6, 2027 (Central time). Inspect the actual embedded profile
after each release; do not reuse cached seven-day Personal Team profiles.

The signed Mac app is installed under `~/Applications/HomeKitten.app`. Its
Agent Access bridge can be read directly without a paired iPad:

```sh
python3 scripts/homekit_agent.py --local-bridge ~/Documents/AgentBridge inventory
python3 scripts/homekit_agent.py --local-bridge ~/Documents/AgentBridge mcp
```

The app must remain running and the Mac awake. Minimizing the window keeps
the bridge available. Quit or sleep prevents access; stale snapshots are
rejected. Existing session authorization, backups and transaction safeguards
apply to both transports. Paid membership does not remove iPadOS background
suspension. TestFlight/App Store distribution remains a separate release.

### Fresh state queries through MCP

Use `home_read_characteristics` to read selected light/switch or sensor
characteristics from HomeKit on demand, with per-value timestamps and explicit
errors/timeouts. It also works in read-only connections. `home_inventory` keeps
its fast cached behavior. See [live read usage](docs/USB_AGENT.md#live-characteristic-reads)
for limits and request-result retrieval.

### Event automation editing through MCP

`home_change_execute` supports `create_event_automation` and event rule updates
through `update_automation`: accessory states, calendar/solar times, presence,
end durations, AND/OR/NOT characteristic conditions, weekday recurrence and
execute-once behavior. See [event automation writes](docs/USB_AGENT.md#event-automation-writes).
Writes retain session authorization, automatic backups and single-consumption
transactions. New automations default to disabled; updates disable during editing
and re-enable only after success. Reconnect MCP clients after installing the
updated signed app to discover the new schema.
