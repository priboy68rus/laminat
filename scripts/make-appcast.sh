#!/usr/bin/env bash
# Sign a release zip with the Sparkle EdDSA key and write dist/appcast.xml for it.
# Usage: scripts/make-appcast.sh <zip> <download-url>
# The private key comes from $SPARKLE_PRIVATE_KEY (CI secret) or, if unset, from the login keychain
# (account "laminat", created with Sparkle's generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="$1"
URL="$2"
APP="build/Build/Products/Release/Laminat.app"
SIGN_UPDATE="build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"

[[ -x "$SIGN_UPDATE" ]] || { echo "sign_update not found: build the app first (scripts/package.sh)"; exit 1; }

PLIST="$APP/Contents/Info.plist"
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")

# Prints: sparkle:edSignature="…" length="…"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  SIGNATURE=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")
else
  SIGNATURE=$("$SIGN_UPDATE" --account laminat "$ZIP")
fi

# Release notes for the update window: this version's section of CHANGELOG.md as an HTML list.
NOTES=$(awk -v v="## ${SHORT_VERSION}" '$0 == v {f=1; next} /^## / {f=0} f && /^- / {sub(/^- /, ""); print}' CHANGELOG.md \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|^|<li>|' -e 's|$|</li>|')
[[ -n "$NOTES" ]] || NOTES="<li>See the release page for details.</li>"
RELEASE_PAGE="https://github.com/priboy68rus/laminat/releases/tag/v${SHORT_VERSION}"

mkdir -p dist
cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Laminat</title>
    <item>
      <title>Laminat ${SHORT_VERSION}</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h3>What's new in ${SHORT_VERSION}</h3>
        <ul>${NOTES}</ul>
        <p><a href="${RELEASE_PAGE}">Release page</a></p>
      ]]></description>
      <enclosure url="${URL}" type="application/octet-stream" ${SIGNATURE} />
    </item>
  </channel>
</rss>
EOF
echo "Wrote dist/appcast.xml for ${SHORT_VERSION} (${BUILD})"
