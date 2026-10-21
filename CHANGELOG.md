# Changelog

The section for a version is shown in the in-app update window (scripts/make-appcast.sh), so keep the
entries short and user-facing.

## 0.1.6

- Queries get their own tabs: File → New Query (⌘N); every open file is a table there, no more switching
  between a file's tabs and views
- File tabs show Data and Stats (⌘1 / ⌘2)
- Press Space on a table in the query sidebar to preview it, like Quick Look

## 0.1.5

- SQL across files: a Tables sidebar in the SQL tab lists the window's tables and their columns; add more
  .parquet files with ＋ or by dropping them on the list or the editor, then join them by name or t2, t3…
- Double-click a table or column in the sidebar to insert its name; completion knows all tables

## 0.1.4

- Current macOS 26 design (Liquid Glass): release builds now use the macOS 26 SDK

## 0.1.3

- Export: File → Export To → CSV, Parquet or JSON Lines (the current view with sort and filters, or a query result)
- Standard macOS menus: Undo, Cut, Copy, Paste and Find (⌘F, ⌘G) in the SQL editor, Help menu with search
- Data / SQL / Stats switch moved to the left of the title, like Finder's back and forward buttons
- SQL templates use a cleaner layout
- Finder shows .parquet files as "Parquet file"
- Downloads are now a disk image: drag Laminat to Applications

## 0.1.2

- Automatic updates: Laminat checks for new versions daily (Laminat → Check for Updates…)
- Files open as tabs of one window; ⌘T opens a file in a new tab
- Query templates moved to ⌘⇧T

## 0.1.1

- Fixed multi-second freezes when scrolling large files sideways
- Faster rendering while scrolling

## 0.1.0

- First release: Quick Look preview, Finder thumbnails, viewer with sorting and filters, SQL, statistics
