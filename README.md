# Laminat

Native macOS viewer for Apache Parquet files with Quick Look preview (Space in Finder) and SQL over files.

**Status:** prototype — checks that a Quick Look extension for `.parquet` works with free (ad-hoc) signing.

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
./scripts/build.sh
```

The script downloads the pinned DuckDB library (`scripts/fetch-duckdb.sh`), generates the Xcode project, builds it, installs `Laminat.app` to `/Applications` (replacing a downloaded release) and registers the Quick Look extension.

## Test

```sh
qlmanage -p samples/sample.parquet
```

Or select `samples/sample.parquet` in Finder and press Space.

If the preview doesn't show up, check that the extension is enabled in
System Settings → General → Login Items & Extensions → Quick Look.

## Developer CLI

`laminat-cli` renders and times the Quick Look preview, and runs SQL (handy for generating test files):

```sh
xcodebuild -project Laminat.xcodeproj -scheme LaminatCLI -derivedDataPath build -quiet build
build/Build/Products/Debug/laminat-cli preview samples/types.parquet --runs 3 --html /tmp/preview.html
build/Build/Products/Debug/laminat-cli exec "COPY (SELECT * FROM range(10)) TO '/tmp/t.parquet'"
```

## Release

Push a `v*` tag; GitHub Actions builds a universal, ad-hoc signed app and publishes a pre-release.
