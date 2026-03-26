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
# Use xcodebuild to create a full app bundle
xcodebuild -workspace "$APP_NAME.xcworkspace" -scheme "$APP_NAME" -configuration Release -derivedDataPath ".build" -xcconfig "Sidey/Config.xcconfig" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO build

if [ $? -ne 0 ]; then
    echo "❌ Error: Build failed. Please check the errors above."
    exit 1
fi

BUILD_APP_BUNDLE=".build/Build/Products/Release/$APP_NAME.app"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"

# 2. Prepare Dist folder, copying the entire bundle
echo "📂 Preparing App Bundle in dist/..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -R "$BUILD_APP_BUNDLE" "$APP_BUNDLE"

# 3. Rename executable and update Info.plist if needed
# (Already done by xcodebuild for the original APP_NAME, 
#  but we need to make sure the renamed bundle is consistent)
echo "📝 Finalizing Info.plist..."
plutil -replace CFBundleName -string "$DISPLAY_NAME" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$APP_BUNDLE/Contents/Info.plist"

# Sync secret and URL from Config.xcconfig manually to ensure they are compiled in
if [ -f "Sidey/Config.xcconfig" ]; then
    echo "🔑 Injecting configuration from Config.xcconfig..."
    # Get all project settings including those from xcconfig
    ALL_SETTINGS=$(xcodebuild -showBuildSettings -project "$PROJ_FILE" -scheme "$APP_NAME" -configuration Release -xcconfig "Sidey/Config.xcconfig" 2>/dev/null)
    
    SECRET=$(echo "$ALL_SETTINGS" | grep -w "SERVICE_SECRET" | head -n 1 | cut -d'=' -f2 | xargs)
    URL_VAL=$(echo "$ALL_SETTINGS" | grep -w "PUBLIC_SERVICE_URL" | head -n 1 | cut -d'=' -f2 | xargs)
    
    if [ -n "$SECRET" ]; then
        plutil -replace ServiceSecret -string "$SECRET" "$APP_BUNDLE/Contents/Info.plist"
        echo "   - ServiceSecret: OK"
    fi
    if [ -n "$URL_VAL" ]; then
        plutil -replace PublicServiceURL -string "$URL_VAL" "$APP_BUNDLE/Contents/Info.plist"
        echo "   - PublicServiceURL: $URL_VAL"
    fi
fi

echo "🛑 Quitting existing $APP_NAME process..."
pkill -x "$APP_NAME" || true
pkill -x "$DISPLAY_NAME" || true
sleep 1

echo "📦 Installing to /Applications..."
rm -rf "/Applications/$DISPLAY_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/"

echo "✅ Done! You can find the app in the '$DIST_DIR' folder and it has been installed to /Applications."
open "/Applications/$DISPLAY_NAME.app"
