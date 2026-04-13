#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

APP="Session Manager.app"
BUILD="build"
DIST="dist"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD/$APP/Contents/MacOS"
mkdir -p "$BUILD/$APP/Contents/Resources"

echo "→ Generating app icon..."
ICONSET="$BUILD/AppIcon.iconset"
swift make_icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$BUILD/$APP/Contents/Resources/AppIcon.icns"

echo "→ swift build -c release ..."
swift build -c release --product SessionManager

BIN_PATH="$(swift build -c release --show-bin-path)"
cp "$BIN_PATH/SessionManager" "$BUILD/$APP/Contents/MacOS/SessionManager"

# Copy any bundled resources from SwiftTerm or other deps
for bundle in "$BIN_PATH"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$BUILD/$APP/Contents/Resources/"
done

cp Info.plist "$BUILD/$APP/Contents/Info.plist"

echo "→ Code signing (ad-hoc)..."
codesign --force --deep --sign - "$BUILD/$APP"

mkdir -p "$DIST"

DMG_STAGE="$BUILD/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$BUILD/$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

cat > "$DMG_STAGE/Fix Gatekeeper.command" <<'SH'
#!/usr/bin/env bash
APP="/Applications/Session Manager.app"
if [ ! -d "$APP" ]; then
    echo "Drag 'Session Manager.app' into /Applications first, then re-run this."
    read -p "Press enter to close..."
    exit 1
fi
echo "Removing Gatekeeper quarantine from $APP ..."
xattr -dr com.apple.quarantine "$APP" || true
echo "Done. You can now open Session Manager normally."
read -p "Press enter to close..."
SH
chmod +x "$DMG_STAGE/Fix Gatekeeper.command"

cat > "$DMG_STAGE/READ ME FIRST.txt" <<'TXT'
Session Manager — Installation
==============================

1.  Drag "Session Manager.app" into the Applications folder shortcut.

2.  In Terminal (Applications > Utilities > Terminal), paste:

        xattr -dr com.apple.quarantine "/Applications/Session Manager.app"

    Then double-click Session Manager normally — done.

3.  Future versions update via the in-app "Update" button (no quarantine
    fix needed for in-app updates).
TXT

echo "→ Building DMG..."
DMG="$DIST/SessionManager.dmg"
rm -f "$DMG"
hdiutil create -volname "Session Manager" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

xattr -dr com.apple.quarantine "$BUILD/$APP" || true
cp -R "$BUILD/$APP" "$DIST/"
xattr -dr com.apple.quarantine "$DIST/$APP" || true

echo ""
echo "Built:"
echo "  App: $here/$DIST/$APP"
echo "  DMG: $DMG"
