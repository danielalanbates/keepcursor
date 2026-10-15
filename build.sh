#!/bin/bash
# Build KeepCursor.app for the current Mac architecture.
# The bundle is assembled OFF iCloud (in /tmp) because iCloud constantly re-adds
# extended attributes that codesign rejects ("resource fork ... detritus").
# Override the output dir with BUILD_DIR=...
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="KeepCursor"
BUILD_DIR="${BUILD_DIR:-/tmp/keepcursor-build}"
APP="$BUILD_DIR/$NAME.app"

echo "› Cleaning previous build ($BUILD_DIR)"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "› Copying source off iCloud"
cp "$ROOT"/Sources/*.swift "$BUILD_DIR/"

echo "› Compiling native binary"
swiftc -O "$BUILD_DIR"/*.swift -o "$APP/Contents/MacOS/$NAME"

echo "› Installing Info.plist"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

echo "› Code signing (ad-hoc; release.sh re-signs with Developer ID)"
codesign --force --deep --sign - "$APP"

echo "› Built: $APP"
lipo -info "$APP/Contents/MacOS/$NAME"
