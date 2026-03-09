#!/bin/bash
set -e

if [ ! -d "Dictato.xcodeproj" ]; then
    echo "Generating Xcode project..."
    xcodegen generate
fi

echo "Building Dictato (Release)..."
xcodebuild -project Dictato.xcodeproj -scheme Dictato -configuration Release -destination 'platform=macOS' build -quiet

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Dictato-*/Build/Products/Release/Dictato.app -maxdepth 0 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "Build failed: Dictato.app not found"
    exit 1
fi

echo "Installing to /Applications..."
rm -rf /Applications/Dictato.app
cp -R "$APP_PATH" /Applications/Dictato.app

echo "Done! Opening Dictato..."
open /Applications/Dictato.app
