#!/bin/zsh
# Regenerates the Xcode project and builds NetLens.app into ./build
#   CONFIG=Release ./scripts/build.sh
# Optional: scripts/signing.local (git-ignored) can set NETLENS_TEAM to sign with
# your Apple Development certificate, so macOS remembers permissions across builds.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f scripts/signing.local ] && source scripts/signing.local
SIGNING=()
if [ -n "${NETLENS_TEAM:-}" ]; then
  SIGNING=(DEVELOPMENT_TEAM="$NETLENS_TEAM" CODE_SIGN_IDENTITY="${NETLENS_IDENTITY:-Apple Development}")
fi
xcodegen generate --quiet
xcodebuild -project NetLens.xcodeproj -scheme NetLens -configuration "${CONFIG:-Debug}" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' "${SIGNING[@]}" build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)|\*\* " || true
APP="build/DerivedData/Build/Products/${CONFIG:-Debug}/NetLens.app"
[ -d "$APP" ] && echo "→ $APP"
