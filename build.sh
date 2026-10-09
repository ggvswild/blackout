#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="Blackout.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -swift-version 5 -O -o "$APP/Contents/MacOS/blackout" main.swift \
    -framework AppKit \
    -framework CoreGraphics \
    -framework Carbon \
    -framework ApplicationServices

ICON_DIR="icon/build"
rm -rf "$ICON_DIR"
mkdir -p "$ICON_DIR"
RENDER_DIR="$(mktemp -d)"
swiftc -swift-version 5 -O -o "$RENDER_DIR/render-icon" icon/render.swift -framework AppKit
"$RENDER_DIR/render-icon" "$PWD/$ICON_DIR"
iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$RENDER_DIR"

codesign --force --sign - --identifier local.we.blackout "$APP"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/blackout" <<EOF
#!/bin/sh
exec "$PWD/$APP/Contents/MacOS/blackout" "\$@"
EOF
chmod +x "$BIN_DIR/blackout"
echo "installed: $BIN_DIR/blackout"
echo "bundle: $PWD/$APP"
