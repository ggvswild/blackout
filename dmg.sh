#!/bin/sh
# 打一个拖进「应用程序」的安装盘。先编译 Blackout.app，再排版窗口。
set -eu
cd "$(dirname "$0")"

./build.sh

VERSION="$(plutil -extract CFBundleShortVersionString raw Blackout.app/Contents/Info.plist)"
VOL="Blackout"
OUT="dist/Blackout-${VERSION}.dmg"
STAGE="$(mktemp -d)"
WORK="$(mktemp -d)"
MOUNT=""

cleanup() {
    if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
        hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGE" "$WORK"
}
trap cleanup EXIT

if [ -d "/Volumes/$VOL" ]; then
    echo "已经挂着 /Volumes/$VOL，先推出后再打包。" >&2
    exit 1
fi

mkdir -p "$STAGE/.background" dist
RENDER_DIR="$(mktemp -d)"
swiftc -swift-version 5 -O -o "$RENDER_DIR/render-background" dmg/render-background.swift -framework AppKit
"$RENDER_DIR/render-background" "$STAGE/.background/background.png"
rm -rf "$RENDER_DIR"
sips -s dpiWidth 144 -s dpiHeight 144 "$STAGE/.background/background.png" >/dev/null

ditto Blackout.app "$STAGE/Blackout.app"
ln -s /Applications "$STAGE/Applications"
cp Blackout.app/Contents/Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg")"
MOUNT="$(printf '%s\n' "$ATTACH" | sed -n 's/.*\(\/Volumes\/.*\)/\1/p' | tail -1)"
if [ -z "$MOUNT" ] || [ ! -d "$MOUNT" ]; then
    echo "安装盘没有挂上。" >&2
    printf '%s\n' "$ATTACH" >&2
    exit 1
fi

SetFile -a V "$MOUNT/.background" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"

# 访达要把图标位置写进 .DS_Store，所以这里会短暂打开一个窗口。
# 排版失败时仍然打出安装盘，只是窗口用系统默认排列。
if ! osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {240, 120, 920, 540}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 120
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Blackout.app" of container window to {175, 230}
        set position of item "Applications" of container window to {505, 230}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
EOF
then
    echo "访达没有排好图标位置，安装盘里仍然有应用。" >&2
fi

RECT="$(osascript <<EOF
tell application "Finder"
    set b to bounds of window of disk "$VOL"
    set x to item 1 of b
    set y to item 2 of b
    set w to (item 3 of b) - x
    set h to (item 4 of b) - y
    return "" & x & "," & y & "," & w & "," & h
end tell
EOF
)" || true
if [ -n "${RECT:-}" ]; then
    screencapture -x -R"$RECT" "dist/dmg-layout.png" || true
fi
osascript -e "tell application \"Finder\" to close window of disk \"$VOL\"" >/dev/null 2>&1 || true

sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
echo "dmg: $PWD/$OUT"
