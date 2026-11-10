#!/bin/bash
# Builds a universal (arm64 + x86_64) CamAdjust.app.
# Run on a Mac with Xcode Command Line Tools installed: xcode-select --install
set -euo pipefail

cd "$(dirname "$0")"
MIN_OS="13.0"
APP="build/CamAdjust.app"
SOURCES=(Sources/*.swift)
FRAMEWORKS=(-framework Cocoa -framework IOKit -framework ServiceManagement -framework AVFoundation -framework SwiftUI)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target "arm64-apple-macos${MIN_OS}" "${FRAMEWORKS[@]}" \
  -o build/CamAdjust-arm64 "${SOURCES[@]}"
swiftc -O -target "x86_64-apple-macos${MIN_OS}" "${FRAMEWORKS[@]}" \
  -o build/CamAdjust-x86_64 "${SOURCES[@]}"

lipo -create -output "$APP/Contents/MacOS/CamAdjust" \
  build/CamAdjust-arm64 build/CamAdjust-x86_64
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so the hardened runtime and Gatekeeper accept the local build.
codesign --force --deep --sign - "$APP"

lipo -info "$APP/Contents/MacOS/CamAdjust"
echo "Built $APP"
