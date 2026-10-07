#!/bin/bash
# Builds build/HoldSeek.app (universal) and build/HoldSeek.zip.
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)"  sign for distribution (default: first identity in your keychain, else ad-hoc)
#   NOTARY_PROFILE=name   notarize and staple, using a profile saved with `xcrun notarytool store-credentials`
set -euo pipefail
cd "$(dirname "$0")"

APP=build/HoldSeek.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" HoldSeek.swift -o "build/HoldSeek-$arch"
done
lipo -create build/HoldSeek-arm64 build/HoldSeek-x86_64 -output "$APP/Contents/MacOS/HoldSeek"
rm build/HoldSeek-arm64 build/HoldSeek-x86_64
"$APP/Contents/MacOS/HoldSeek" --selftest

cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
cp -R extension "$APP/Contents/Resources/ChromeExtension"
# A real identity keeps the Accessibility permission across rebuilds; ad-hoc (-) loses it every time.
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' 'NR==1 {print $2}')}
SIGN_ID=${SIGN_ID:--}
# Chrome launches a copy of this standalone-signed helper, which stays valid outside the bundle.
cp "$APP/Contents/MacOS/HoldSeek" "$APP/Contents/MacOS/HoldSeekBridge"
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/MacOS/HoldSeekBridge"
codesign --force --options runtime --entitlements HoldSeek.entitlements --sign "$SIGN_ID" "$APP"

ditto -c -k --keepParent "$APP" build/HoldSeek.zip
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit build/HoldSeek.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" build/HoldSeek.zip  # re-zip so the download carries the ticket
fi
echo "Built $APP"
