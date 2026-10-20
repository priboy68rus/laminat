# Laminat

Native macOS viewer for Apache Parquet files with Quick Look preview (Space in Finder) and SQL over files.

**Status:** prototype — checks that a Quick Look extension for `.parquet` works with free (ad-hoc) signing.

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
./scripts/build.sh
```

The script generates the Xcode project, builds it, installs `Laminat.app` to `~/Applications` and registers the Quick Look extension.

## Test

```sh
qlmanage -p samples/sample.parquet
```

Or select `samples/sample.parquet` in Finder and press Space.

If the preview doesn't show up, check that the extension is enabled in
System Settings → General → Login Items & Extensions → Quick Look.
