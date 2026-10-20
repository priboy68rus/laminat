#!/usr/bin/env bash
# Build Laminat, install it to ~/Applications and register the Quick Look extension.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }

xcodegen generate --quiet

xcodebuild \
  -project Laminat.xcodeproj \
  -scheme Laminat \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY=- \
  -quiet build

APP_SRC="build/Build/Products/Debug/Laminat.app"
APP_DST="$HOME/Applications/Laminat.app"

mkdir -p "$HOME/Applications"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# Register the app (and its UTI) with Launch Services, and the extension with PluginKit.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP_DST"
pluginkit -a "$APP_DST/Contents/PlugIns/LaminatQuickLook.appex" || true
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

echo "Installed: $APP_DST"
echo
echo "Signature:"
codesign -dv "$APP_DST" 2>&1 | grep -E "Identifier|Signature" || true
echo
echo "Quick Look extension registration:"
pluginkit -mAvvv -p com.apple.quicklook.preview 2>/dev/null | grep -i -A3 laminat || echo "  (not listed yet)"
echo
echo "Content type of the sample file:"
mdls -name kMDItemContentType samples/sample.parquet || true
echo
echo "Preview test:  qlmanage -p samples/sample.parquet"
