#!/bin/bash
set -euo pipefail
# AppKit is built for macOS, independently of the Catalyst SDK slice.
[[ "${IS_MACCATALYST:-NO}" == YES ]] || exit 0
bundle="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/PlugIns/HomeKittenMenuBar.bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
sips -z 64 64 "$SRCROOT/Resources/MenuBarMotif.png" --out "$bundle/Contents/Resources/HomeKittenMenuBar.png" >/dev/null
sdk="$(xcrun --sdk macosx --show-sdk-path)"
arch_flags=()
for architecture in $ARCHS; do arch_flags+=(-arch "$architecture"); done
# Remove Catalyst-specific environment overrides from the native compiler.
env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET xcrun --sdk macosx clang \
  -isysroot "$sdk" "${arch_flags[@]}" -mmacosx-version-min=26.0 \
  -fobjc-arc -fmodules -bundle -framework AppKit \
  "$SRCROOT/Sources/MacMenuBar/MenuBar.m" -o "$bundle/Contents/MacOS/HomeKittenMenuBar"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>abie.ios.homekitten.menubar</string>
<key>CFBundleExecutable</key><string>HomeKittenMenuBar</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>NSPrincipalClass</key><string>HKMenuBar</string>
</dict></plist>
PLIST
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "$EXPANDED_CODE_SIGN_IDENTITY" != - ]]
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$bundle"
fi
