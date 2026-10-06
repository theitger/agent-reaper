#!/usr/bin/env bash
# Builds Reaper.app (release) into ~/Applications. Same recipe as Muxy.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Reaper.app"
ICNS="$REPO/Packaging/AppIcon.icns"

echo "[reaper] release build …"
swift build -c release --package-path "$REPO"

if [ ! -f "$ICNS" ]; then
    echo "[reaper] rendering icon …"
    tmp="$(mktemp -d)"
    swift "$REPO/Scripts/make-icon.swift" "$tmp/AppIcon.iconset"
    iconutil -c icns "$tmp/AppIcon.iconset" -o "$ICNS"
fi

echo "[reaper] assembling bundle …"
pkill -x ReaperApp 2>/dev/null || true
mkdir -p "$APP_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO/.build/release/ReaperApp" "$APP/Contents/MacOS/ReaperApp"
cp "$REPO/.build/release/reaper" "$APP/Contents/MacOS/reaper"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$REPO/Packaging/en.lproj" "$REPO/Packaging/de.lproj" "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1
# Launchers (Spotlight, Raycast) read the icon from LaunchServices' cache.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "[reaper] done: $APP"
