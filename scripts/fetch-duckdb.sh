#!/usr/bin/env bash
# Download the prebuilt DuckDB C library (universal macOS dylib + duckdb.h) into Vendor/duckdb.
# The version and checksum are pinned; the script is a no-op when the right version is already there.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.5.6"
SHA256="e0bc007d9b0094c0970ac1847a8601d10aad07cbd2910ce586ec810f77b638d6"
URL="https://github.com/duckdb/duckdb/releases/download/v$VERSION/libduckdb-osx-universal.zip"
DEST="Vendor/duckdb"

if [[ -f "$DEST/VERSION" && "$(cat "$DEST/VERSION")" == "$VERSION" && -f "$DEST/libduckdb.dylib" && -f "$DEST/duckdb.h" ]]; then
  exit 0
fi

echo "Fetching DuckDB ${VERSION}..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL -o "$TMP/libduckdb.zip" "$URL"
echo "$SHA256  $TMP/libduckdb.zip" | shasum -a 256 -c --quiet

mkdir -p "$TMP/out"
unzip -q "$TMP/libduckdb.zip" -d "$TMP/out"

rm -rf "$DEST"
mkdir -p "$DEST"
cp "$TMP/out/libduckdb.dylib" "$TMP/out/duckdb.h" "$DEST/"
echo "$VERSION" > "$DEST/VERSION"
