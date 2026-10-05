#!/bin/zsh
# Builds a Release NetLens.app (ad-hoc signed) and zips it into ./dist for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(grep MARKETING_VERSION project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
xcodegen generate --quiet
# Universal binary (Apple silicon + Intel).
xcodebuild -project NetLens.xcodeproj -scheme NetLens -configuration Release \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP=build/DerivedData/Build/Products/Release/NetLens.app
mkdir -p dist
rm -f "dist/NetLens-$VERSION-macOS.zip"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "dist/NetLens-$VERSION-macOS.zip"
shasum -a 256 "dist/NetLens-$VERSION-macOS.zip"
