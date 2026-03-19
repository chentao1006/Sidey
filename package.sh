#!/bin/bash

# Configuration
PROJECT_NAME="Sidey"
SCHEME="Sidey"
BUNDLE_ID="com.ct106.sidey"
TEAM_ID="U2NEAJ73J2"
APP_NAME="${PROJECT_NAME}.app"
RESULT_DIR="./dist"
APP_BUNDLE="${RESULT_DIR}/${APP_NAME}"
DMG_NAME="${PROJECT_NAME}.dmg"
DMG_PATH="${RESULT_DIR}/${DMG_NAME}"

# --- Check for Notarization Credentials ---
# You can set these environment variables globally or replace them here
APPLE_ID="${APPLE_ID}"
APPLE_PASSWORD="${APPLE_PASSWORD}"

set -e

echo "🚀 Starting packaging process for ${PROJECT_NAME}..."

# 1. Clean and Create result directory
rm -rf "${RESULT_DIR}"
mkdir -p "${RESULT_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# 2. Build in Release mode (using SPM)
echo "🏗️ Building ${PROJECT_NAME} in release mode..."
swift build -c release --arch arm64 --arch x86_64

# 3. Assemble App Bundle
echo "📂 Assembling App Bundle..."

# Handle Icons
ICONSET_DIR="/tmp/${PROJECT_NAME}.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
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

# Handle Info.plist
cp "Info.plist" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "$PROJECT_NAME" "$APP_BUNDLE/Contents/Info.plist"
# Important for localization: ensure CFBundleName and CFBundleDisplayName are present
plutil -replace CFBundleName -string "$PROJECT_NAME" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$PROJECT_NAME" "$APP_BUNDLE/Contents/Info.plist"

# Copy binary and resources
cp ".build/apple/Products/Release/$PROJECT_NAME" "$APP_BUNDLE/Contents/MacOS/"
# SPM generates a resource bundle file
find ".build/apple/Products/Release" -name "${PROJECT_NAME}_${PROJECT_NAME}.bundle" -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;
# Copy .lproj folders to top-level Resources (correct path for SPM-generated bundle)
cp -R "$APP_BUNDLE/Contents/Resources/${PROJECT_NAME}_${PROJECT_NAME}.bundle/Contents/Resources"/*.lproj "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true


# 4. Code Signing (if developer ID set, else ad-hoc)
echo "🖋️ Code signing..."
CODESIGN_IDENTITY="Developer ID Application"
ENTITLEMENTS="Sources/Sidey/Sidey.entitlements"
TMP_ENTITLEMENTS="/tmp/Sidey.tmp.entitlements"

# Prepare entitlements with Team ID
if [ -f "$ENTITLEMENTS" ]; then
    sed "s/\$(TeamIdentifierPrefix)/${TEAM_ID}./g" "$ENTITLEMENTS" > "$TMP_ENTITLEMENTS"
    ENT_OPT="--entitlements $TMP_ENTITLEMENTS"
else
    echo "⚠️  Entitlements file not found at $ENTITLEMENTS"
    ENT_OPT=""
fi

if security find-identity -v -p codesigning | grep -q "$CODESIGN_IDENTITY"; then
    echo "Found $CODESIGN_IDENTITY, signing..."
    # Sign nested components first (frameworks, apps)
    find "$APP_BUNDLE/Contents" -maxdepth 2 -name "*.framework" -o -name "*.bundle" | while read component; do
        codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$component"
    done
    # Finally sign the main app bundle
    codesign --force --options runtime --deep $ENT_OPT --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "⚠️  $CODESIGN_IDENTITY not found. Using ad-hoc signing (some features may not work)."
    codesign --force --options runtime --deep --sign - "$APP_BUNDLE"
fi
rm -f "$TMP_ENTITLEMENTS"

# 5. Create DMG
echo "💿 Creating DMG..."
TMP_DMG_DIR="${RESULT_DIR}/dmg_tmp"
mkdir -p "${TMP_DMG_DIR}"
cp -R "${APP_BUNDLE}" "${TMP_DMG_DIR}/"
ln -s /Applications "${TMP_DMG_DIR}/Applications"
hdiutil create -volname "${PROJECT_NAME}" -srcfolder "${TMP_DMG_DIR}" -ov -format UDZO "${DMG_PATH}"
rm -rf "${TMP_DMG_DIR}"

# 6. Notarize (if credentials provided)
if [ -n "$APPLE_ID" ] && [ -n "$APPLE_PASSWORD" ]; then
    echo "🔐 Submitting for notarization..."
    xcrun notarytool submit "${DMG_PATH}" \
        --apple-id "${APPLE_ID}" \
        --password "${APPLE_PASSWORD}" \
        --team-id "${TEAM_ID}" \
        --wait

    echo "🖋️ Stapling notarization ticket..."
    xcrun stapler staple "${DMG_PATH}"
    echo "✅ Notarization and stapling complete!"
else
    echo "⚠️  Notarization skipped (APPLE_ID/APPLE_PASSWORD not set)."
fi


echo "🎉 All done! DMG is at ${DMG_PATH}"
