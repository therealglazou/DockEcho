#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/DockEcho"

APP="DockEcho.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DockEcho"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DockEcho</string>
  <key>CFBundleDisplayName</key><string>DockEcho</string>
  <key>CFBundleIdentifier</key><string>com.glazou.DockEcho</string>
  <key>CFBundleExecutable</key><string>DockEcho</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.2</string>
  <key>CFBundleVersion</key><string>1.2.2</string>
  <key>LSMinimumSystemVersion</key><string>12.3</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Signature. macOS ties privacy permissions (Accessibility / Device Control and Data Access,
# Screen Recording) to the signature. An ad-hoc signature changes at every build, so macOS
# keeps showing the permission as granted for the old build while the new one is refused.
# A real identity keeps the permissions across rebuilds. Order of preference:
#   1. SIGN_IDENTITY="..." ./build.sh
#   2. the first code-signing identity in the keychain (e.g. a free "Apple Development"
#      certificate created in Xcode > Settings > Accounts > Manage Certificates)
#   3. ad-hoc
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/ { print $2; exit }' || true)"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "⚠️  Ad-hoc signature: after each rebuild, remove DockEcho from the privacy lists"
  echo "   (or run: tccutil reset Accessibility com.glazou.DockEcho; tccutil reset ScreenCapture com.glazou.DockEcho)"
  echo "   and grant the permissions again."
fi
echo "✅ $APP created. Run: open $APP"
