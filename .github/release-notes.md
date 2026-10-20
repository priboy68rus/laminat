Prototype build. The app is ad-hoc signed (no Apple Developer ID), so macOS blocks it on first launch.

### Install

1. Download `Laminat-*.zip`, unzip it and move `Laminat.app` to `/Applications`.
2. Open `Laminat.app` — macOS will refuse to open it. Click **Done**.
3. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the Laminat message, then confirm.
   (Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Laminat.app`)
4. Launch Laminat once — this registers the Quick Look extension.
5. Select a `.parquet` file in Finder and press Space.

If the preview doesn't appear, enable **Laminat Quick Look** in
System Settings → General → Login Items & Extensions → Quick Look.
