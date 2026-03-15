set -euo pipefail

scheme=${scheme:-ComicDeck}
archive_path=${archive_path:-archive-maccatalyst}
artifact_name=${artifact_name:-$scheme}
volume_name=${volume_name:-ComicDeck}

ARCHIVE_DIR="$archive_path.xcarchive"
APP_PATH="$ARCHIVE_DIR/Products/Applications/$scheme.app"

if [ ! -d "$ARCHIVE_DIR" ]; then
  echo "Archive not found at $ARCHIVE_DIR"
  exit 1
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Archived app not found at $APP_PATH"
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
  echo "Info.plist not found at $INFO_PLIST"
  exit 1
fi

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"
if [ -z "$EXECUTABLE_NAME" ] || [ ! -f "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" ]; then
  echo "Archived app is incomplete: executable is missing from $APP_PATH"
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$artifact_name.dmg"
hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$artifact_name.dmg"
