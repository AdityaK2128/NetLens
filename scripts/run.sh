#!/bin/zsh
# Builds and (re)launches NetLens.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
pkill -x NetLens 2>/dev/null || true
sleep 0.3
open "build/DerivedData/Build/Products/${CONFIG:-Debug}/NetLens.app"
