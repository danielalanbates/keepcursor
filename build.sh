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

# Sign with a STABLE identity so Accessibility / Input Monitoring grants survive
# rebuilds (TCC keys ad-hoc builds to the cdhash, which changes every build).
IDENTITY="${SIGN_IDENTITY:-7C0CCBA426A5480F0F29F006EC92E0E17173768D}"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "› Code signing with Developer ID ($IDENTITY)"
  codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "› Developer ID not found; ad-hoc signing with a fixed designated requirement"
  codesign --force --deep --sign - -r='designated => identifier "com.batesai.keepcursor"' "$APP"
fi
codesign -d -r- "$APP" 2>&1 | grep designated

echo "› Built: $APP"
lipo -info "$APP/Contents/MacOS/$NAME"
