#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DESTINATION="$PWD/build/DJI Mic Remote.app"
if pgrep -x DJIMicRemote >/dev/null; then
    echo 'Quit DJI Mic Remote before replacing its app bundle.' >&2
    exit 1
fi
swift build -c release
mkdir -p "$PWD/build"
STAGING=$(mktemp -d "$PWD/build/.app-stage.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/DJI Mic Remote.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# AppResources resolves the app’s resources without relying on build-machine paths.
for bundle in .build/release/*.bundle; do
    [ -d "$bundle" ] || continue
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
if [ -n "${PARAKEET_MODEL_DIR:-}" ]; then
    python3 scripts/package-model.py "$PARAKEET_MODEL_DIR" "$APP/Contents/Resources/Parakeet"
else
    rm -rf "$APP/Contents/Resources/Parakeet"
fi
cp .build/release/DJIMicRemote "$APP/Contents/MacOS/DJIMicRemote"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.phil.dji-mic-remote</string>
<key>CFBundleName</key><string>DJI Mic Remote</string>
<key>CFBundleExecutable</key><string>DJIMicRemote</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Record your selected microphone for private, on-device transcription when you press the receiver button.</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
bash scripts/sign-app.sh "$APP"
# Never replace a live executable or expose an unsigned/partially copied bundle.
if pgrep -x DJIMicRemote >/dev/null; then
    echo 'DJI Mic Remote started during the build. Quit it and build again.' >&2
    exit 1
fi
if [ -e "$DESTINATION" ]; then mv "$DESTINATION" "$STAGING/previous.app"; fi
if ! mv "$APP" "$DESTINATION"; then
    if [ -e "$STAGING/previous.app" ]; then mv "$STAGING/previous.app" "$DESTINATION"; fi
    exit 1
fi
echo "$DESTINATION"
