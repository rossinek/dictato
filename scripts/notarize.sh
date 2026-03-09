#!/bin/bash
set -euo pipefail

INSTALL=false
if [ "${1:-}" = "--install" ]; then
  INSTALL=true
fi

if [ -z "${APPLE_ID:-}" ]; then
  echo "Error: APPLE_ID env var is required (your Apple ID email)"
  exit 1
fi

if [ -z "${APP_PASSWORD:-}" ]; then
  echo "Error: APP_PASSWORD env var is required (app-specific password from appleid.apple.com)"
  exit 1
fi

TEAM_ID="H7B584W2D6"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Dictato.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Dictato.app"
ZIP_PATH="$EXPORT_PATH/Dictato.zip"

rm -rf "$BUILD_DIR"

echo "==> Generating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate

echo "==> Archiving..."
xcodebuild -project Dictato.xcodeproj -scheme Dictato \
  -configuration Release \
  -destination 'platform=macOS' \
  archive -archivePath "$ARCHIVE_PATH" \
  | tail -5

echo "==> Exporting..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$PROJECT_DIR/ExportOptions.plist" \
  | tail -3

echo "==> Zipping..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting for notarization..."
xcrun notarytool submit "$ZIP_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait

echo "==> Stapling..."
xcrun stapler staple "$APP_PATH"

echo "==> Re-zipping with stapled ticket..."
rm "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [ "$INSTALL" = true ]; then
  echo "==> Installing to /Applications..."
  rm -rf /Applications/Dictato.app
  cp -R "$APP_PATH" /Applications/Dictato.app
  echo "==> Done! Installed to /Applications/Dictato.app"
else
  echo "==> Done! Distributable at: $ZIP_PATH"
fi
