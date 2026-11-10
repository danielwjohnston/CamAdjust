#!/bin/bash
# Builds a universal (arm64 + x86_64) Webcam Settings.app.
# Run on a Mac with Xcode Command Line Tools installed: xcode-select --install
set -euo pipefail

cd "$(dirname "$0")"
MIN_OS="13.0"
APP="build/WebcamSettings.app"
SOURCES=(Sources/*.swift)
FRAMEWORKS=(-framework Cocoa -framework IOKit -framework ServiceManagement)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target "arm64-apple-macos${MIN_OS}" "${FRAMEWORKS[@]}" \
  -o build/WebcamSettings-arm64 "${SOURCES[@]}"
swiftc -O -target "x86_64-apple-macos${MIN_OS}" "${FRAMEWORKS[@]}" \
  -o build/WebcamSettings-x86_64 "${SOURCES[@]}"

lipo -create -output "$APP/Contents/MacOS/WebcamSettings" \
  build/WebcamSettings-arm64 build/WebcamSettings-x86_64
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so the hardened runtime and Gatekeeper accept the local build.
codesign --force --deep --sign - "$APP"

lipo -info "$APP/Contents/MacOS/WebcamSettings"
echo "Built $APP"
