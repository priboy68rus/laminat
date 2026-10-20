#!/usr/bin/env bash
# Generate large Parquet files for performance testing into testdata/ (not committed).
#   testdata/big_30m.parquet      30M rows, 10 columns of mixed types incl. nested, ~1.7 GB
#   testdata/wide_501cols.parquet 200k rows, 501 columns, ~475 MB
set -euo pipefail
cd "$(dirname "$0")/.."

CLI=build/Build/Products/Debug/laminat-cli
if [[ ! -x "$CLI" ]]; then
  ./scripts/fetch-duckdb.sh
  xcodegen generate --quiet
  xcodebuild -project Laminat.xcodeproj -scheme LaminatCLI -configuration Debug -derivedDataPath build -quiet build
fi

mkdir -p testdata

if [[ ! -f testdata/big_30m.parquet ]]; then
  echo "Generating testdata/big_30m.parquet (takes ~30 s)..."
  "$CLI" exec "COPY (
    SELECT i AS id,
           CASE WHEN i % 7 = 0 THEN NULL ELSE 'user_' || (i % 100000) END AS name,
           (random() * 1000)::DECIMAL(10,2) AS amount,
           random() AS score,
           TIMESTAMP '2024-01-01' + INTERVAL (i % 31536000) SECOND AS ts,
           (i % 3 = 0) AS flag,
           {'city': 'city_' || (i % 500), 'zip': i % 99999} AS address,
           [i % 10, i % 11, i % 12] AS tags,
           md5(i::VARCHAR) || md5((i + 1)::VARCHAR) || md5((i + 2)::VARCHAR) AS payload,
           encode(md5(i::VARCHAR)) AS raw
    FROM range(30000000) t(i)
  ) TO 'testdata/big_30m.parquet' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 1000000)"
fi

if [[ ! -f testdata/wide_501cols.parquet ]]; then
  echo "Generating testdata/wide_501cols.parquet..."
  COLS=$(for c in $(seq 1 500); do printf "i*%d AS col_%d, " "$c" "$c"; done)
  "$CLI" exec "COPY (SELECT ${COLS} 'x' AS last FROM range(200000) t(i)) TO 'testdata/wide_501cols.parquet' (FORMAT parquet)"
fi

ls -lh testdata
