#!/usr/bin/env bash
# Build Laminat (Release, so performance is representative), install it to /Applications (replacing any release copy) and register the Quick Look extension.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }

./scripts/fetch-duckdb.sh

xcodegen generate --quiet

xcodebuild \
  -project Laminat.xcodeproj \
  -scheme Laminat \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY=- \
  -quiet build

APP_SRC="build/Build/Products/Release/Laminat.app"
APP_DST="/Applications/Laminat.app"


rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# Register the app (and its UTI) with Launch Services, and the extension with PluginKit.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# xcodebuild registers every build product (Debug and Release); drop them all so Quick Look
# only ever uses the installed copy.
for built in build/Build/Products/*/Laminat.app; do
  [[ -d "$built" ]] || continue
  for appex in "$built"/Contents/PlugIns/*.appex; do pluginkit -r "$appex" 2>/dev/null || true; done
  "$LSREGISTER" -u "$built" 2>/dev/null || true
done
"$LSREGISTER" -f "$APP_DST"
for appex in "$APP_DST"/Contents/PlugIns/*.appex; do pluginkit -a "$appex" || true; done
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

echo "Installed: $APP_DST"
echo
echo "Signature:"
codesign -dv "$APP_DST" 2>&1 | grep -E "Identifier|Signature" || true
echo
echo "Quick Look extension registration:"
for point in com.apple.quicklook.preview com.apple.quicklook.thumbnail com.apple.spotlight.import; do
  pluginkit -mAvvv -p "$point" 2>/dev/null | grep -i -A1 "laminat" | grep -E "laminat|Path" || echo "  $point: (not listed yet)"
done
echo
echo "Content type of the sample file:"
mdls -name kMDItemContentType samples/sample.parquet || true
echo
echo "Preview test:  qlmanage -p samples/sample.parquet"
