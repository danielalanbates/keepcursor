#!/bin/bash
# Produce a Developer ID-signed, notarized, stapled KeepCursor.app + zip,
# ready for batesai.org and GitHub Releases. Runs entirely off iCloud.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="KeepCursor"
BUILD_DIR="/tmp/keepcursor-build"
APP="$BUILD_DIR/$NAME.app"
# Use the cert SHA-1 (multiple Developer ID certs share the same name)
DEVID="7C0CCBA426A5480F0F29F006EC92E0E17173768D"
NOTARY_PROFILE="batesai-notary"
DIST="$ROOT/dist"

# 1. Build (compiles + ad-hoc signs into /tmp)
BUILD_DIR="$BUILD_DIR" "$ROOT/build.sh"

# 2. Re-sign with Developer ID + hardened runtime (required for notarization)
echo "› Re-signing with Developer ID + hardened runtime"
codesign --force --options runtime --timestamp --sign "$DEVID" "$APP/Contents/MacOS/$NAME"
codesign --force --options runtime --timestamp --sign "$DEVID" "$APP"
codesign -v --strict "$APP" && echo "  signature OK"

# 3. Zip for notarization
ZIP_TMP="$BUILD_DIR/$NAME.zip"
rm -f "$ZIP_TMP"
ditto -c -k --keepParent "$APP" "$ZIP_TMP"

# 4. Notarize
echo "› Submitting to Apple notary (this can take a minute)…"
xcrun notarytool submit "$ZIP_TMP" --keychain-profile "$NOTARY_PROFILE" --wait

# 5. Staple ticket into the app, then make the final distributable zip
echo "› Stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

mkdir -p "$DIST"
ZIP="$DIST/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 6. Install the notarized build to /Applications (kill dupes first)
pkill -f "KeepCursor.app/Contents/MacOS/KeepCursor" 2>/dev/null || true
sleep 1
rm -rf "/Applications/KeepCursor.app"
ditto "$APP" "/Applications/KeepCursor.app"

echo "› Release artifact: $ZIP"
echo "› Gatekeeper assessment:"
spctl -a -vvv --type execute "/Applications/KeepCursor.app" 2>&1 | head -4 || true
brctl download "$ZIP" 2>/dev/null || true
