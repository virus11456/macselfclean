#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/macsweep-build.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/MacSweep.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -module-cache-path "${TMPDIR:-/tmp}/macsweep-module-cache" -swift-version 6 -O -target arm64-apple-macosx14.0 Sources/*.swift -o "$APP/Contents/MacOS/MacSweep"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacSweep</string>
<key>CFBundleIdentifier</key><string>local.macsweep.desktop</string>
<key>CFBundleName</key><string>MacSweep</string>
<key>CFBundleDisplayName</key><string>MacSweep</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.17</string>
<key>CFBundleVersion</key><string>20</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto --norsrc --noextattr -c -k --keepParent "$APP" "$PWD/MacSweep.zip"
ditto --norsrc --noextattr "$APP" "$PWD/MacSweep.app"
echo "Built: $PWD/MacSweep.app and $PWD/MacSweep.zip"
