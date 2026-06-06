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

BUILD_DIR=".build/apple/Products/Release"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "🛑 Quitting existing $APP_NAME process..."
pkill -x "$APP_NAME" || true
sleep 1

echo "🏗️ Building $APP_NAME in release mode..."
SIGNING_IDENTITIES=$(security find-identity -v -p codesigning)
USE_AD_HOC_SIGNING=false

echo "🛡️ Resetting system permissions for $BUNDLE_ID..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true

# 1. Build in Release mode
if echo "$SIGNING_IDENTITIES" | grep -q "valid identities found" && ! echo "$SIGNING_IDENTITIES" | grep -q " 0 valid identities found"; then
    # Use xcodebuild to create a normally signed app bundle when a trusted identity is available.
    xcodebuild -project "$PROJ_FILE" -scheme "$APP_NAME" -configuration Release -derivedDataPath ".build" -xcconfig "Sidey/Config.xcconfig" build
else
    echo "⚠️ No trusted code signing identity found. Building unsigned, then using ad-hoc signing for local testing."
    USE_AD_HOC_SIGNING=true
    xcodebuild -project "$PROJ_FILE" -scheme "$APP_NAME" -configuration Release -derivedDataPath ".build" -xcconfig "Sidey/Config.xcconfig" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
fi

if [ $? -ne 0 ]; then
    echo "❌ Error: Build failed. Please check the errors above."
    exit 1
fi

BUILD_APP_BUNDLE=".build/Build/Products/Release/$APP_NAME.app"
# 2. Prepare Dist folder, copying the entire bundle
echo "📂 Preparing App Bundle in dist/..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -R "$BUILD_APP_BUNDLE" "$APP_BUNDLE"

if [ "$USE_AD_HOC_SIGNING" = true ]; then
    echo "🔏 Applying ad-hoc signature for local launch..."
    codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"
fi

echo "📦 Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
rm -rf "/Applications/旁白.app"
cp -R "$APP_BUNDLE" "/Applications/"

echo "✅ Done! You can find the app in the '$DIST_DIR' folder and it has been installed to /Applications."
open "/Applications/$APP_NAME.app"
