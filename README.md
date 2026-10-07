# HomeKitten

iPhone, iPad, and Mac Catalyst HomeKit manager. It reads and controls HomeKit accessories, and
manages rooms, groups, scenes, automations, backups, and reassignment.
The Mac version uses Mac Catalyst to access HomeKit.

## Prerequisites

1. Open `HomeKitten.xcodeproj` in Xcode.
2. Select the HomeKitten target, then Signing & Capabilities.
3. Choose your Apple Developer team and replace `com.example.HomeKitten` with a unique App ID.
4. Confirm the HomeKit capability remains enabled.

Build from the command line after configuring the team in Xcode:

```sh
xcodebuild -project HomeKitten.xcodeproj -scheme HomeKitten \
  -destination 'platform=macOS,variant=Mac Catalyst' build
```

HomeKit rejects an ad-hoc signature. The signing identity and App ID must belong to a developer team with HomeKit enabled.

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

On iPhone, open **Agent Access** and tap **Connect Paired Mac**. Keep that screen
open and the phone unlocked. The Mac client uses Xcode's paired-device file
service to read configuration and submit changes for review on the phone.
No additional app, paid membership, LAN server, or bearer token is needed.
See [USB agent usage](docs/USB_AGENT.md) for CLI and MCP setup.

## Future Mac agent access

The app is deliberately not an unauthenticated local HomeKit API. The planned
agent bridge keeps HomeKitten as the signed, user-authorized HomeKit client and
adds a separate local tool surface with explicit approval for every state
changing request. See [the bridge design](docs/AGENT_BRIDGE.md) before enabling
it; it includes the pairing, permissions, audit, and rollout requirements.
