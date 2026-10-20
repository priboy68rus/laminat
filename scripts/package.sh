#!/usr/bin/env bash
# Build a Release copy of Laminat, ad-hoc sign it and pack it into dist/Laminat-<version>.zip.
# Usage: scripts/package.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-dev}"

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }

xcodegen generate --quiet

xcodebuild \
  -project Laminat.xcodeproj \
  -scheme Laminat \
  -configuration Release \
  -derivedDataPath build \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- \
  -quiet build

APP="build/Build/Products/Release/Laminat.app"

# Re-sign inside-out so the extension and the app have consistent ad-hoc signatures.
codesign --force --sign - --entitlements QuickLook/LaminatQuickLook.entitlements \
  "$APP/Contents/PlugIns/LaminatQuickLook.appex"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p dist
ZIP="dist/Laminat-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Packaged: $ZIP"
lipo -archs "$APP/Contents/MacOS/Laminat"
