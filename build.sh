#!/bin/bash
# Build KeepCursor.app as a universal binary.
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
SRC="$BUILD_DIR/main.swift"
cp "$ROOT/Sources/main.swift" "$SRC"

echo "› Compiling universal binary (arm64 + x86_64)"
swiftc -O -target arm64-apple-macos13.0  "$SRC" -o "$BUILD_DIR/${NAME}-arm64"
swiftc -O -target x86_64-apple-macos13.0 "$SRC" -o "$BUILD_DIR/${NAME}-x86_64"
lipo -create -output "$APP/Contents/MacOS/$NAME" \
    "$BUILD_DIR/${NAME}-arm64" "$BUILD_DIR/${NAME}-x86_64"
rm -f "$BUILD_DIR/${NAME}-arm64" "$BUILD_DIR/${NAME}-x86_64"

echo "› Installing Info.plist"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

echo "› Code signing (ad-hoc; release.sh re-signs with Developer ID)"
codesign --force --deep --sign - "$APP"

echo "› Built: $APP"
lipo -info "$APP/Contents/MacOS/$NAME"
