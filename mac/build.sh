#!/bin/zsh
# Builds "KVM Dashboard.app" with the Command Line Tools (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/KVM Dashboard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/KVMDashboard"

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $PWD/$APP"
