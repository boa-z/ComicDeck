#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ARCHIVE_PATH="$ROOT_DIR/build/ComicDeck.xcarchive"

xcodebuild \
  -project ComicDeck.xcodeproj \
  -scheme ComicDeck \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive
