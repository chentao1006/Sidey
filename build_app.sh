#!/bin/bash

# Configuration
APP_NAME="Sidey"
BUNDLE_ID="com.ct106.sidey"
BUILD_DIR=".build/apple/Products/Release"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

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
ICONSET_DIR="/tmp/Sidey.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Mapping files from Assets.xcassets to standard iconset names
SRC_ICON_DIR="Sources/Sidey/Resources/Assets.xcassets/AppIcon.appiconset"
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

# 4. Create Info.plist
echo "📝 Generating Info.plist..."
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

# 5. Copy binary and resources
echo "🚀 Copying binary and artifacts..."
cp ".build/apple/Products/Release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# SPM generates a resource bundle file, e.g., Sidey_Sidey.bundle
# It should be placed in Contents/Resources/ for the app bundle
find ".build/apple/Products/Release" -name "${APP_NAME}_${APP_NAME}.bundle" -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;

echo "🛑 Quitting existing $APP_NAME process..."
pkill -x "$APP_NAME" || true
sleep 1

echo "📦 Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/"

echo "✅ Done! You can find the app in the '$DIST_DIR' folder and it has been installed to /Applications."
open "/Applications/$APP_NAME.app"
