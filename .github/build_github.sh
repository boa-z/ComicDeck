set -e

scheme=${scheme:-ComicDeck}
archive_path=${archive_path:-archive}
artifact_name=${artifact_name:-$scheme}

if [ ! -d "$archive_path.xcarchive" ]; then
  echo "Archive not found at $archive_path.xcarchive"
  exit 1
fi

APP_DIR="$archive_path.xcarchive/Products/Applications"
APP_PATH="$APP_DIR/$scheme.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Archived app not found at $APP_PATH"
  exit 1
fi

INFO_PLIST="$APP_PATH/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
  echo "Info.plist not found at $INFO_PLIST"
  exit 1
fi

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"
if [ -z "$EXECUTABLE_NAME" ] || [ ! -f "$APP_PATH/$EXECUTABLE_NAME" ]; then
  echo "Archived app is incomplete: executable is missing from $APP_PATH"
  exit 1
fi

rm -rf Payload
mv "$APP_DIR" Payload

rm -f "$artifact_name.ipa"
zip -r "$artifact_name.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"
