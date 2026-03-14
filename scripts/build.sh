#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

xcodebuild \
  -project ComicDeck.xcodeproj \
  -scheme ComicDeck \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath DerivedData \
  build
