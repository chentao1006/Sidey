#!/bin/bash

# Configuration
PLIST_PATH="Info.plist"
RESULT_DIR="./dist"
PROJECT_NAME="Sidey"

# Helper functions
get_current_version() {
    grep -A 1 "CFBundleShortVersionString" "$PLIST_PATH" | grep "<string>" | sed -E 's/.*<string>(.*)<\/string>.*/\1/'
}

get_current_build() {
    grep -A 1 "CFBundleVersion" "$PLIST_PATH" | grep "<string>" | sed -E 's/.*<string>(.*)<\/string>.*/\1/'
}

CURRENT_VERSION=$(get_current_version)
CURRENT_BUILD=$(get_current_build)

echo "----------------------------------------"
echo "Current Version: $CURRENT_VERSION"
echo "Current Build  : $CURRENT_BUILD"
echo "----------------------------------------"

if [ -z "$1" ]; then
    read -p "Enter NEW Version (e.g. 1.1.1): " NEW_VERSION
else
    NEW_VERSION=$1
fi

if [ -z "$NEW_VERSION" ]; then
    echo "❌ Error: New version cannot be empty."
    exit 1
fi

# Determine NEW_BUILD
if [[ "$NEW_VERSION" != "$CURRENT_VERSION" ]]; then
    NEW_BUILD=1
else
    NEW_BUILD=$((CURRENT_BUILD + 1))
fi

echo "🚀 Preparing local release $NEW_VERSION (Build $NEW_BUILD)..."

# 1. Update Info.plist
sed -i '' -E "/<key>CFBundleShortVersionString<\/key>/{n;s/<string>.*<\/string>/<string>$NEW_VERSION<\/string>/;}" "$PLIST_PATH"
sed -i '' -E "/<key>CFBundleVersion<\/key>/{n;s/<string>.*<\/string>/<string>$NEW_BUILD<\/string>/;}" "$PLIST_PATH"

echo "✅ Configuration updated."

# 2. Run Packaging (uses working local keychain)
chmod +x package.sh
./package.sh

if [ ! -f "${RESULT_DIR}/${PROJECT_NAME}.dmg" ]; then
    echo "❌ Packaging Failed: ${PROJECT_NAME}.dmg not found in ${RESULT_DIR}"
    exit 1
fi

# 3. Git Operations
git add .
git commit -m "chore: release version $NEW_VERSION (build $NEW_BUILD)"
git tag "v$NEW_VERSION"

echo "📦 Code committed and tagged locally."

# 4. Push and Upload to GitHub
BRANCH=$(git symbolic-ref --short HEAD)
git push origin "$BRANCH"
git push origin "v$NEW_VERSION"

# Use GitHub CLI to create release and upload assets
if command -v gh >/dev/null 2>&1; then
    echo "📡 Creating GitHub Release and uploading assets..."
    gh release create "v$NEW_VERSION" \
        "${RESULT_DIR}/${PROJECT_NAME}.dmg" \
        --title "Release v$NEW_VERSION" \
        --notes "Automatic local release of version $NEW_VERSION"
    
    if [ $? -eq 0 ]; then
        echo "🎉 Release completed successfully!"
    else
        echo "❌ GitHub CLI failed to create release. Check the error above."
    fi
else
    echo "⚠️  GitHub CLI (gh) not found or not authenticated. Please upload ${RESULT_DIR}/${PROJECT_NAME}.dmg and appcast.xml manually to the GitHub release page."
fi

echo "🎉 Release process complete!"
