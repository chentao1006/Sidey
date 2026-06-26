#!/bin/bash

# Configuration
PLIST_PATH="Info.plist"
APPSTORE_PLIST_PATH="Sidey-Appstore-Info.plist"
PBXPROJ_PATH="Sidey.xcodeproj/project.pbxproj"
RESULT_DIR="./dist"

# Helper function to get current version

get_current_version() {
    # Try to get from pbxproj first as it's the source of truth if variables are used
    VERSION=$(grep "MARKETING_VERSION =" "$PBXPROJ_PATH" | head -n 1 | sed -E 's/.*MARKETING_VERSION = (.*);/\1/')
    if [ -z "$VERSION" ]; then
        # Fallback to Info.plist
        VERSION=$(grep -A 1 "CFBundleShortVersionString" "$PLIST_PATH" | grep "<string>" | sed -E 's/.*<string>(.*)<\/string>.*/\1/')
    fi
    echo "$VERSION"
}

# Helper function to get current build
get_current_build() {
    # Try to get from pbxproj first
    BUILD=$(grep "CURRENT_PROJECT_VERSION =" "$PBXPROJ_PATH" | head -n 1 | sed -E 's/.*CURRENT_PROJECT_VERSION = (.*);/\1/')
    if [ -z "$BUILD" ]; then
        # Fallback to Info.plist
        BUILD=$(grep -A 1 "CFBundleVersion" "$PLIST_PATH" | grep "<string>" | sed -E 's/.*<string>(.*)<\/string>.*/\1/')
    fi
    echo "$BUILD"
}

CURRENT_VERSION=$(get_current_version)
CURRENT_BUILD=$(get_current_build)

echo "----------------------------------------"
echo "Current Version: $CURRENT_VERSION"
echo "Current Build  : $CURRENT_BUILD"
echo "----------------------------------------"

if [ -z "$1" ]; then
    read -p "Enter NEW Version (leave empty to keep current $CURRENT_VERSION): " NEW_VERSION
else
    NEW_VERSION=$1
fi

if [ -z "$NEW_VERSION" ]; then
    NEW_VERSION=$CURRENT_VERSION
    echo "Keeping current version: $NEW_VERSION"
fi

# Determine NEW_BUILD (Always increment to ensure Sparkle compatibility)
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "🚀 Preparing local release $NEW_VERSION (Build $NEW_BUILD)..."

# 1. Update Version Files
sed -i '' -E "/<key>CFBundleShortVersionString<\/key>/{n;s/<string>.*<\/string>/<string>$NEW_VERSION<\/string>/;}" "$PLIST_PATH"
sed -i '' -E "/<key>CFBundleVersion<\/key>/{n;s/<string>.*<\/string>/<string>$NEW_BUILD<\/string>/;}" "$PLIST_PATH"
sed -i '' -E "/<key>CFBundleShortVersionString<\/key>/{n;s/<string>.*<\/string>/<string>$NEW_VERSION<\/string>/;}" "$APPSTORE_PLIST_PATH"
sed -i '' -E "/<key>CFBundleVersion<\/key>/{n;s/<string>.*<\/string>/<string>$NEW_BUILD<\/string>/;}" "$APPSTORE_PLIST_PATH"
sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $NEW_VERSION;/" "$PBXPROJ_PATH"
sed -i '' "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/" "$PBXPROJ_PATH"

echo "✅ Local configuration updated."


# 2. Run Local Build (Uses your working local keychain)
chmod +x package.sh
./package.sh "$NEW_VERSION"

if [ ! -f "${RESULT_DIR}/Sidey.dmg" ]; then
    echo "❌ Local Build Failed: Sidey.dmg not found in ${RESULT_DIR}"
    exit 1
fi

# 3. Git Operations
git add .
git commit -m "chore: release version $NEW_VERSION (build $NEW_BUILD)"
git tag -a "v$NEW_VERSION" -m "Release v$NEW_VERSION"

echo "📦 Code committed and tagged locally."

# 4. Push and Upload to GitHub
BRANCH=$(git symbolic-ref --short HEAD)
git push origin "$BRANCH"
git push origin "v$NEW_VERSION"

# Use GitHub CLI to create release and upload assets
if command -v gh >/dev/null 2>&1; then
    echo "📡 Creating GitHub Release and uploading assets..."
    # DMG is the primary asset
    ASSETS=("${RESULT_DIR}/Sidey.dmg")
    
    # If re-releasing the same version, we need to delete the old one first
    echo "🧹 Removing existing release and tag if they exist..."
    gh release delete "v$NEW_VERSION" --yes 2>/dev/null || true
    git push origin --delete "v$NEW_VERSION" 2>/dev/null || true
    git tag -d "v$NEW_VERSION" 2>/dev/null || true

    gh release create "v$NEW_VERSION" \
        "${ASSETS[@]}" \
        --title "Release v$NEW_VERSION" \
        --notes "Automatic local release of version $NEW_VERSION (Build $NEW_BUILD)"
    
    if [ $? -eq 0 ]; then
        echo "🎉 Release completed successfully!"
        if [ "${SKIP_HOMEBREW_RELEASE:-0}" = "1" ]; then
            echo "⏭️  Skipping Homebrew release because SKIP_HOMEBREW_RELEASE=1."
        else
            echo "🍺 Updating Homebrew tap..."
            chmod +x release-to-brew.sh
            if ./release-to-brew.sh "${RESULT_DIR}/Sidey.dmg" "$NEW_VERSION"; then
                echo "🍺 Homebrew tap updated successfully!"
            else
                echo "❌ Error: Homebrew tap update failed. GitHub Release was created, but the cask may need to be updated manually."
                exit 1
            fi
        fi
    else
        echo "❌ Error: GitHub Release failed to create. Please check the error above."
    fi
else
    echo "⚠️  Note: GitHub CLI (gh) not found or not authenticated. Please upload ${RESULT_DIR}/Sidey.dmg and appcast.xml manually to the GitHub release page."
fi
