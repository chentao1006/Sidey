#!/bin/bash

# Configuration
echo "🔍 Extracting project information..."
PROJ_FILE=$(find . -maxdepth 1 -name "*.xcodeproj" | head -n 1)
if [ -z "$PROJ_FILE" ]; then
    echo "❌ Error: Could not find .xcodeproj file in the current directory."
    exit 1
fi

PROJ_SETTINGS=$(xcodebuild -showBuildSettings -project "$PROJ_FILE" -configuration Release 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "❌ Error: Could not get project build settings from xcodebuild."
    exit 1
fi

APP_NAME=$(echo "$PROJ_SETTINGS" | grep -w "PRODUCT_NAME" | head -n 1 | cut -d'=' -f2 | xargs)
BUNDLE_ID=$(echo "$PROJ_SETTINGS" | grep -w "PRODUCT_BUNDLE_IDENTIFIER" | head -n 1 | cut -d'=' -f2 | xargs)
VERSION=$(echo "$PROJ_SETTINGS" | grep -w "MARKETING_VERSION" | head -n 1 | cut -d'=' -f2 | xargs)
BUILD_NUMBER=$(echo "$PROJ_SETTINGS" | grep -w "CURRENT_PROJECT_VERSION" | head -n 1 | cut -d'=' -f2 | xargs)

if [ -z "$APP_NAME" ] || [ -z "$BUNDLE_ID" ]; then
    echo "❌ Error: Could not extract APP_NAME or BUNDLE_ID from project settings."
    exit 1
fi

echo "   App Name: $APP_NAME"
echo "   Bundle ID: $BUNDLE_ID"
echo "   Version: $VERSION ($BUILD_NUMBER)"

# 0. Localize Bundle Name based on system language
DISPLAY_NAME="$APP_NAME"
SYSTEM_LANG=$(defaults read -g AppleLanguages | grep -oE '[a-zA-Z-]+' | head -n 1)
echo "🔍 System Language: $SYSTEM_LANG"

if [[ "$SYSTEM_LANG" == zh* ]]; then
    # Try to find Chinese InfoPlist.strings
    STRINGS_FILE=$(find "$APP_NAME" -name "InfoPlist.strings" | grep "zh-Hans" | head -n 1 2>/dev/null)
    if [ -z "$STRINGS_FILE" ]; then
        # Fallback to search in all dirs if APP_NAME folder not found
        STRINGS_FILE=$(find . -name "InfoPlist.strings" | grep "zh-Hans" | head -n 1 2>/dev/null)
    fi
    
    if [ -n "$STRINGS_FILE" ]; then
        LOCALIZED_NAME=$(plutil -p "$STRINGS_FILE" | grep -E "CFBundleDisplayName|CFBundleName" | head -n 1 | sed -E 's/.*=> "(.*)".*/\1/')
        if [ -n "$LOCALIZED_NAME" ]; then
            DISPLAY_NAME="$LOCALIZED_NAME"
            echo "🌐 Localized Name found: $DISPLAY_NAME"
        fi
    fi
fi

BUILD_DIR=".build/apple/Products/Release"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"

# 1. Build in Release mode
echo "🏗️ Building $APP_NAME in release mode..."
swift build -c release --arch arm64 --arch x86_64

# 2. Setup App Bundle structure
echo "📂 Creating App Bundle structure..."
rm -rf "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. Handle Icons
echo "🎨 Generating App Icon..."
ICONSET_DIR="/tmp/$APP_NAME.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Mapping files from Assets.xcassets to standard iconset names
SRC_ICON_DIR="Sidey/Resources/Assets.xcassets/AppIcon.appiconset"
cp "$SRC_ICON_DIR/Mac-16.png" "$ICONSET_DIR/icon_16x16.png"
cp "$SRC_ICON_DIR/Mac-16@2x.png" "$ICONSET_DIR/icon_16x16@2x.png"
cp "$SRC_ICON_DIR/Mac-32.png" "$ICONSET_DIR/icon_32x32.png"
cp "$SRC_ICON_DIR/Mac-32@2x.png" "$ICONSET_DIR/icon_32x32@2x.png"
cp "$SRC_ICON_DIR/Mac-128.png" "$ICONSET_DIR/icon_128x128.png"
cp "$SRC_ICON_DIR/Mac-128@2x.png" "$ICONSET_DIR/icon_128x128@2x.png"
cp "$SRC_ICON_DIR/Mac-256.png" "$ICONSET_DIR/icon_256x256.png"
cp "$SRC_ICON_DIR/Mac-256@2x.png" "$ICONSET_DIR/icon_256x256@2x.png"
cp "$SRC_ICON_DIR/Mac-512.png" "$ICONSET_DIR/icon_512x512.png"
cp "$SRC_ICON_DIR/App Store-512@2x.png" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR"

# 4. Handle Info.plist
echo "📝 Processing Info.plist..."
cp "Info.plist" "$APP_BUNDLE/Contents/Info.plist"
# Ensure the app name, ID and versions in Plist match project configuration
plutil -replace CFBundleExecutable -string "$APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleName -string "$DISPLAY_NAME" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"

# 5. Copy binary and resources
echo "🚀 Copying binary and artifacts..."
cp ".build/apple/Products/Release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# SPM generates a resource bundle file, e.g., Sidey_Sidey.bundle
# It should be placed in Contents/Resources/ for the app bundle
find ".build/apple/Products/Release" -name "${APP_NAME}_${APP_NAME}.bundle" -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;
# Copy .lproj folders to top-level Resources so macOS system UI can find them
cp -R "$APP_BUNDLE/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle"/*.lproj "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

echo "🛑 Quitting existing $APP_NAME process..."
pkill -x "$APP_NAME" || true
sleep 1

echo "📦 Installing to /Applications..."
rm -rf "/Applications/$DISPLAY_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/"

echo "✅ Done! You can find the app in the '$DIST_DIR' folder and it has been installed to /Applications."
open "/Applications/$DISPLAY_NAME.app"
