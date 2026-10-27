#!/bin/sh
# Builds a universal (Apple silicon + Intel) Hop.app into build/, ad-hoc signed
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
APP=build/Hop.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/Hop "$APP/Contents/MacOS/Hop"
cp Info.plist "$APP/Contents/Info.plist"
cp Hop.icns "$APP/Contents/Resources/Hop.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
