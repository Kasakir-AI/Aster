#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
npm --prefix Renderer ci --ignore-scripts --no-audit --no-fund
./test.sh
(cd Renderer && node build.mjs)
xcodebuild -project Aster.xcodeproj -scheme Aster -configuration Release \
  -derivedDataPath .build/Xcode -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO "$@" build
