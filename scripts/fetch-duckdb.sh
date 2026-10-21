#!/usr/bin/env bash
# Download the prebuilt DuckDB C library (universal macOS dylib + duckdb.h) and the official extensions
# the app bundles (excel, per architecture) into Vendor/duckdb. Versions and checksums are pinned; the
# script is a no-op when everything is already there.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.5.6"
SHA256="e0bc007d9b0094c0970ac1847a8601d10aad07cbd2910ce586ec810f77b638d6"
URL="https://github.com/duckdb/duckdb/releases/download/v$VERSION/libduckdb-osx-universal.zip"
DEST="Vendor/duckdb"

# Official, DuckDB-signed extensions loaded from the app bundle (no network at runtime).
# The file must be named <extension>.duckdb_extension: DuckDB derives the entry point from it.
EXTENSIONS=(
  "excel osx_arm64 327c04c3b0c850592c50637f46e4d91e280978a393bc3b889f6d555aba08240d"
  "excel osx_amd64 551bb3c1a8b8c579e9e308a74f9a70b18669461dc1789d0123931ad890172d12"
)

library_ok() {
  [[ -f "$DEST/VERSION" && "$(cat "$DEST/VERSION")" == "$VERSION" && -f "$DEST/libduckdb.dylib" && -f "$DEST/duckdb.h" ]]
}

extensions_ok() {
  for entry in "${EXTENSIONS[@]}"; do
    read -r name arch _ <<< "$entry"
    [[ -f "$DEST/extensions/$arch/$name.duckdb_extension" ]] || return 1
  done
}

if library_ok && extensions_ok; then
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! library_ok; then
  echo "Fetching DuckDB ${VERSION}..."
  curl -fsSL -o "$TMP/libduckdb.zip" "$URL"
  echo "$SHA256  $TMP/libduckdb.zip" | shasum -a 256 -c --quiet
  mkdir -p "$TMP/out"
  unzip -q "$TMP/libduckdb.zip" -d "$TMP/out"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp "$TMP/out/libduckdb.dylib" "$TMP/out/duckdb.h" "$DEST/"
  echo "$VERSION" > "$DEST/VERSION"
fi

for entry in "${EXTENSIONS[@]}"; do
  read -r name arch sha <<< "$entry"
  target="$DEST/extensions/$arch/$name.duckdb_extension"
  [[ -f "$target" ]] && continue
  echo "Fetching DuckDB extension ${name} (${arch})..."
  curl -fsSL -o "$TMP/$name-$arch.gz" "https://extensions.duckdb.org/v$VERSION/$arch/$name.duckdb_extension.gz"
  echo "$sha  $TMP/$name-$arch.gz" | shasum -a 256 -c --quiet
  mkdir -p "$(dirname "$target")"
  gunzip -c "$TMP/$name-$arch.gz" > "$target"
done
