#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="Blackout.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -swift-version 5 -O -o "$APP/Contents/MacOS/blackout" main.swift \
    -framework AppKit \
    -framework CoreGraphics \
    -framework Carbon \
    -framework ApplicationServices
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
