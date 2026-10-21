Fast native macOS viewer for Apache Parquet files.

- **Quick Look**: press Space on a `.parquet` file in Finder — schema and first rows
- **Finder thumbnails**: file icons show a miniature of the table
- **Viewer**: double-click — lazily loaded grid for millions of rows, sort by header click, filter per column
- **SQL**: DuckDB SQL over the file (`FROM <file name>` or `FROM t1`), templates (⌘⇧T), history, cancel (⎋)
- **Statistics** (⌘3): nulls, unique values, min / max, mean, quartiles, histogram and top values

Requires macOS 15+. Already have Laminat 0.1.2 or later? It updates itself: Laminat → Check for Updates….
(The `.zip` is the same app, used for automatic updates.)

### Install

The app is not notarized, so macOS blocks it on first launch:

1. Download `Laminat-*.dmg`, open it and drag **Laminat** onto **Applications**.
2. Open Laminat — macOS refuses. Click **Done**.
3. **System Settings → Privacy & Security** → scroll down → **Open Anyway** → confirm.
   (Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Laminat.app`)
4. Launch Laminat once — this registers Quick Look and thumbnails.

If Space shows no preview: System Settings → General → Login Items & Extensions → Quick Look →
enable **Laminat Quick Look**, then run `qlmanage -r && killall Finder`.

### Установка

Приложение не нотаризовано, поэтому при первом запуске macOS его блокирует:

1. Скачай `Laminat-*.dmg`, открой и перетащи **Laminat** на **Applications** («Программы»).
2. Открой — macOS откажет. Нажми **Готово**.
3. **Системные настройки → Конфиденциальность и безопасность** → пролистай вниз → **Всё равно открыть** →
   подтверди. (Или в Терминале: `xattr -dr com.apple.quarantine /Applications/Laminat.app`)
4. Запусти Laminat один раз — так регистрируются Quick Look и миниатюры.

Если по пробелу нет превью: Системные настройки → Основные → Объекты входа и расширения → Quick Look →
включи **Laminat Quick Look** и выполни `qlmanage -r && killall Finder`.
