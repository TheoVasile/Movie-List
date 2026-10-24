#!/usr/bin/env python3
"""Writes SampleImport.xlsx, a tiny workbook for checking the Excel import, from raw XML parts (no openpyxl needed).

Sheet "Top Films" has a header row (#, Film, Released, My Rating, Date Watched, Notes) with ranks out of order, a
skipped column, shared, inline and formatted (rich text) strings, and dates stored as Excel numbers. Sheet
"Watchlist" has no header: titles in column A, years in column B.

    python3 make_sample_xlsx.py [output path]
"""
import sys
import zipfile
from xml.sax.saxutils import escape

shared = []


def s(text):
    """A shared-string cell value"""
    if text not in shared:
        shared.append(text)
    return ("s", shared.index(text))


def cell(ref, value):
    if value is None:
        return ""
    if isinstance(value, tuple) and value[0] == "s":
        return f'<c r="{ref}" t="s"><v>{value[1]}</v></c>'
    if isinstance(value, tuple) and value[0] == "inline":
        return f'<c r="{ref}" t="inlineStr"><is><t>{escape(value[1])}</t></is></c>'
    return f'<c r="{ref}"><v>{value}</v></c>'


def sheet_xml(rows):
    body = []
    for r, row in enumerate(rows, start=1):
        cells = "".join(cell(f"{col}{r}", value) for col, value in row.items())
        body.append(f'<row r="{r}">{cells}</row>')
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            f'<sheetData>{"".join(body)}</sheetData></worksheet>')


# Columns: A rank, B title, C year, D left empty, E rating, F watched (Excel date number), G notes
top = [
    {"A": s("#"), "B": s("Film"), "C": s("Released"), "E": s("My Rating"), "F": s("Date Watched"), "G": s("Notes")},
    {"A": 2, "B": s("Heat"), "C": 1995, "E": 4.5, "F": 45292, "G": s("The diner scene")},
    {"A": 1, "B": ("inline", "Amélie"), "C": 2001, "E": 5},
    {"A": 3, "B": s("RICH:Crouching Tiger, Hidden Dragon"), "C": s("2000-07-06"), "F": s("2023-03-01")},
    {"B": s("Not A Real Film Xyz"), "C": 2010},
]
watchlist = [
    {"A": s("Paris, Texas"), "B": 1984},
    {"A": s("1917"), "B": 2019},
    {"A": s("Past Lives"), "B": 2023},
]
sheets = [("Top Films", sheet_xml(top)), ("Watchlist", sheet_xml(watchlist))]


def shared_xml():
    items = []
    for text in shared:
        if text.startswith("RICH:"):
            # Formatted text is stored as runs, with no plain <t> for the whole string
            first, rest = text[5:].split(",", 1)
            items.append(f'<si><r><rPr><b/></rPr><t>{escape(first)},</t></r><r><t xml:space="preserve">{escape(rest)}</t></r></si>')
        else:
            items.append(f"<si><t>{escape(text)}</t></si>")
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            f'<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{len(shared)}" '
            f'uniqueCount="{len(shared)}">{"".join(items)}</sst>')


content_types = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                 '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                 '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                 '<Default Extension="xml" ContentType="application/xml"/>'
                 '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
                 + "".join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
                           for i in range(1, len(sheets) + 1))
                 + '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
                 '</Types>')
root_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
             '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
             '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
             '</Relationships>')
workbook = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
            + "".join(f'<sheet name="{escape(name)}" sheetId="{i}" r:id="rId{i}"/>' for i, (name, _) in enumerate(sheets, start=1))
            + '</sheets></workbook>')
workbook_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                 '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                 + "".join(f'<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>'
                           for i in range(1, len(sheets) + 1))
                 + f'<Relationship Id="rId{len(sheets) + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
                 '</Relationships>')

output = sys.argv[1] if len(sys.argv) > 1 else "SampleImport.xlsx"
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("[Content_Types].xml", content_types)
    archive.writestr("_rels/.rels", root_rels)
    archive.writestr("xl/workbook.xml", workbook)
    archive.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
    for i, (_, xml) in enumerate(sheets, start=1):
        archive.writestr(f"xl/worksheets/sheet{i}.xml", xml)
    archive.writestr("xl/sharedStrings.xml", shared_xml())
print(f"Wrote {output}")
