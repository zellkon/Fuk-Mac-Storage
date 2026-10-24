#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Sign with a fixed Apple Development identity so macOS keeps folder permissions
# (Desktop, Documents, Downloads, Full Disk Access) across rebuilds. Ad-hoc signatures
# change every build, which makes macOS ask again each time.
# Override with: SIGN_IDENTITY="<SHA-1 or name>" ./build.sh   (use "-" for ad-hoc)
SIGN_IDENTITY="${SIGN_IDENTITY:-8F09E0674A1C11AEEC74D780B84B6DE97546B0D9}"
xcodebuild -project SafeSpace.xcodeproj -scheme SafeSpace -configuration Release \
  -derivedDataPath .build-xcode -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' CODE_SIGNING_ALLOWED=NO build
mkdir -p dist
/usr/bin/ditto ".build-xcode/Build/Products/Release/Fuk Mac Storage.app" "dist/Fuk Mac Storage.app"
/usr/bin/codesign --force --deep --options runtime --entitlements Resources/FukMacStorage.entitlements --sign "$SIGN_IDENTITY" "dist/Fuk Mac Storage.app"
/usr/bin/codesign --verify --strict "dist/Fuk Mac Storage.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "dist/Fuk Mac Storage.app" "dist/Fuk-Mac-Storage-macOS.zip"
printf 'Built: %s/dist/Fuk Mac Storage.app\n' "$PWD"
