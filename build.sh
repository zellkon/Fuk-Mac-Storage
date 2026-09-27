#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcodebuild -project SafeSpace.xcodeproj -scheme SafeSpace -configuration Release \
  -derivedDataPath .build-xcode -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' CODE_SIGNING_ALLOWED=NO build
mkdir -p dist
/usr/bin/ditto ".build-xcode/Build/Products/Release/Fuk Mac Storage.app" "dist/Fuk Mac Storage.app"
/usr/bin/codesign --force --sign - "dist/Fuk Mac Storage.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "dist/Fuk Mac Storage.app" "dist/Fuk-Mac-Storage-macOS.zip"
printf 'Built: %s/dist/Fuk Mac Storage.app\n' "$PWD"
