#!/bin/bash
# Usage: ./build.sh [--install]
#   --install  copy DockEcho.app to /Applications, replacing (and quitting) any running copy,
#              then launch it from there. Recommended: macOS ties the privacy permissions
#              (Accessibility / Device Control and Data Access, Screen Recording) to the app
#              and its location, and they only work reliably for an app in /Applications.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (see ./build.sh --help)" >&2; exit 1 ;;
  esac
done

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

if [ "$INSTALL" -eq 0 ]; then
  echo "✅ $APP created."
  echo "   Run ./build.sh --install to put it in /Applications and launch it (recommended:"
  echo "   the permissions only work reliably from there)."
  exit 0
fi

DEST="/Applications/$APP"

# Quit the running copy, wherever it was launched from, before replacing it.
if pgrep -x DockEcho >/dev/null; then
  echo "Quitting the running DockEcho…"
  pkill -x DockEcho || true
  for _ in $(seq 1 50); do
    pgrep -x DockEcho >/dev/null || break
    sleep 0.1
  done
  pkill -9 -x DockEcho 2>/dev/null || true
fi

if ! { rm -rf "$DEST" && ditto "$APP" "$DEST"; } 2>/dev/null; then
  echo "❌ Could not write to /Applications. Run: sudo ditto \"$APP\" \"$DEST\"" >&2
  exit 1
fi
echo "✅ Installed in $DEST"
open "$DEST"
