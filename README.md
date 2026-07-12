# HomeKitten

Minimal signed Mac Catalyst HomeKit reader. HomeKit is unavailable to native macOS apps.

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
