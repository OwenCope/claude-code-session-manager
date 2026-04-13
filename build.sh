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

echo "→ Compiling Swift..."
swiftc -O \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -framework SwiftUI -framework AppKit \
    -o "$BUILD/$APP/Contents/MacOS/SessionManager" \
    main.swift

cp Info.plist "$BUILD/$APP/Contents/Info.plist"

echo "→ Code signing (ad-hoc)..."
codesign --force --deep --sign - "$BUILD/$APP"

mkdir -p "$DIST"

# Build a friendly DMG layout: app + Applications shortcut + helper script + README
DMG_STAGE="$BUILD/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$BUILD/$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

# Helper that strips the quarantine attribute (fixes "cannot be opened" on Macs without Apple Developer signing)
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

2.  Because this app is signed ad-hoc (not Apple-notarized), macOS will
    block it on first launch with:
        "Apple could not verify [...] is free of malware"

    OPEN TERMINAL (Applications > Utilities > Terminal) AND PASTE:

        xattr -dr com.apple.quarantine "/Applications/Session Manager.app"

    Press Return. Then double-click Session Manager normally — done.

    (The "Fix Gatekeeper.command" file in this DMG does the same thing,
     but Gatekeeper blocks .command files too, so the Terminal one-liner
     above is the most reliable approach.)

3.  Where do deleted sessions go?
    They are MOVED (not permanently deleted) to:
        ~/.claude/projects/.trash/
    Click "Show Trash" in the app's toolbar to open it in Finder.
    Restore by moving files back to ~/.claude/projects/<project-dir>/

TXT

echo "→ Building DMG..."
DMG="$DIST/SessionManager.dmg"
rm -f "$DMG"
hdiutil create -volname "Session Manager" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

# Strip quarantine from local app copy so the developer's machine can launch it directly
xattr -dr com.apple.quarantine "$BUILD/$APP" || true
cp -R "$BUILD/$APP" "$DIST/"
xattr -dr com.apple.quarantine "$DIST/$APP" || true

echo ""
echo "Built:"
echo "  App: $here/$DIST/$APP"
echo "  DMG: $DMG"
