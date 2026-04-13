#!/usr/bin/env bash
set -euo pipefail

# Usage: ./release.sh 1.0.1 "release notes here"
# - bumps CFBundleShortVersionString in Info.plist
# - rebuilds the app + DMG
# - commits + tags + pushes
# - creates a GitHub release with the DMG attached

if [ $# -lt 1 ]; then
    echo "Usage: $0 <version> [\"release notes\"]"
    echo "Example: $0 1.0.1 \"Fix navigation bug\""
    exit 1
fi

VERSION="$1"
NOTES="${2:-Release v$VERSION}"
TAG="v$VERSION"

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

if ! command -v gh >/dev/null; then
    echo "gh CLI required. Install: brew install gh"
    exit 1
fi

echo "→ Bumping version to $VERSION..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
NEW_BUILD=$((BUILD_NUM + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" Info.plist

echo "→ Building..."
./build.sh

DMG="dist/SessionManager.dmg"
if [ ! -f "$DMG" ]; then
    echo "Build failed: $DMG not found"
    exit 1
fi

echo "→ Committing..."
git add Info.plist
git commit -m "Release $TAG" || echo "(nothing to commit)"
git tag -f "$TAG"
git push origin main --tags

echo "→ Creating GitHub release..."
gh release create "$TAG" "$DMG" --title "$TAG" --notes "$NOTES" || \
    gh release upload "$TAG" "$DMG" --clobber

echo ""
echo "Released $TAG"
echo "  https://github.com/OwenCope/claude-code-session-manager/releases/tag/$TAG"
