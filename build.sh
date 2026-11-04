#!/bin/sh
# Builds build/MKV Player.app. Pass "universal" to include an Intel slice.
set -e
cd "$(dirname "$0")"

NAME="MKV Player"
EXE=MKVPlayer
APP="build/$NAME.app"
MIN_OS=13.0
FLAGS="-Osize -wmo -swift-version 5 -Xlinker -dead_strip"

ARCHS="arm64"
[ "$1" = "universal" ] && ARCHS="arm64 x86_64"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
SLICES=""
for arch in $ARCHS; do
    xcrun swiftc $FLAGS -target "$arch-apple-macos$MIN_OS" Sources/*.swift -o "build/obj/$EXE-$arch"
    SLICES="$SLICES build/obj/$EXE-$arch"
done
lipo -create $SLICES -output "$APP/Contents/MacOS/$EXE"
strip -x "$APP/Contents/MacOS/$EXE"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign -s - --force "$APP" 2>/dev/null
echo "built $APP ($(du -sk "$APP" | cut -f1) KB)"
