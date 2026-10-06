#!/usr/bin/env bash
# Builds Reaper.app and zips it for a GitHub release.
# Output: dist/Reaper-<version>.zip (+ sha256 on stdout)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO/Packaging/Info.plist")"

"$REPO/Scripts/make-app.sh"

DIST="$REPO/dist"
mkdir -p "$DIST"
ZIP="$DIST/Reaper-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$HOME/Applications/Reaper.app" "$ZIP"
echo "release: $ZIP"
shasum -a 256 "$ZIP"
