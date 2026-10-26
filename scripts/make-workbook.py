#!/usr/bin/env python3
"""Merge single-sheet .xlsx files written by DuckDB (COPY … (FORMAT xlsx)) into one multi-sheet workbook.

Usage: scripts/make-workbook.py out.xlsx "Sheet name=one.xlsx" "Other=two.xlsx" ...

DuckDB writes strings inline (no shared-string table), so worksheets can be copied as they are; only the
workbook, its relationships and the content-type list need to name every sheet. Test-data helper only.
"""
import sys
import zipfile
from xml.sax.saxutils import escape, quoteattr

out, *specs = sys.argv[1:]
sheets = [spec.split("=", 1) for spec in specs]
if not sheets:
    sys.exit(__doc__)

with zipfile.ZipFile(sheets[0][1]) as base:
    styles = base.read("xl/styles.xml")
    shared = base.read("xl/sharedStrings.xml")
    root_rels = base.read("_rels/.rels")

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    rels = [
        '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>',
        '<Relationship Id="rIdStrings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>',
    ]
    entries, overrides = [], []
    for index, (name, path) in enumerate(sheets, start=1):
        with zipfile.ZipFile(path) as source:
            z.writestr(f"xl/worksheets/sheet{index}.xml", source.read("xl/worksheets/sheet1.xml"))
        rels.append(f'<Relationship Id="rId{index}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{index}.xml"/>')
        entries.append(f'<sheet name={quoteattr(name)} sheetId="{index}" r:id="rId{index}"/>')
        overrides.append(f'<Override PartName="/xl/worksheets/sheet{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>')

    z.writestr("xl/workbook.xml",
               '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
               '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
               'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
               f'<sheets>{"".join(entries)}</sheets></workbook>')
    z.writestr("xl/_rels/workbook.xml.rels",
               '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
               '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
               f'{"".join(rels)}</Relationships>')
    z.writestr("[Content_Types].xml",
               '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
               '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
               '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
               '<Default Extension="xml" ContentType="application/xml"/>'
               '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
               '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
               '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
               f'{"".join(overrides)}</Types>')
    z.writestr("xl/styles.xml", styles)
    z.writestr("xl/sharedStrings.xml", shared)
    z.writestr("_rels/.rels", root_rels)

print(f"wrote {out} with {len(sheets)} sheets: {', '.join(name for name, _ in sheets)}")
