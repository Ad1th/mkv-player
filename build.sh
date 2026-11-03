#!/bin/sh
set -e
cd "$(dirname "$0")"
APP="build/MKV Player.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -swift-version 5 Sources/*.swift -o "$APP/Contents/MacOS/MKVPlayer"
cp Resources/Info.plist "$APP/Contents/"
codesign -s - --force "$APP"
echo "built $APP"
