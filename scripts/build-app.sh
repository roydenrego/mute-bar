#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=".build/app"
APP="$BUILD_DIR/MuteBar.app"

echo "==> swift build (release)"
swift build -c release --product MuteBar
swift build -c release --product mutebar-host

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/MuteBar "$APP/Contents/MacOS/MuteBar"
cp .build/release/mutebar-host "$APP/Contents/MacOS/mutebar-host"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.sfdye.mutebar</string>
    <key>CFBundleName</key>
    <string>MuteBar</string>
    <key>CFBundleExecutable</key>
    <string>MuteBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.5</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>MuteBar opens the microphone during a meeting so macOS delivers the AirPods mute gesture to it. Audio is discarded immediately and never recorded, stored or sent.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing for now; Developer ID + notarization happens in CI (M4).
codesign --force --sign - "$APP"

echo "==> done: $APP"
echo "    Next: launch it — the app registers the native host on start"
