#!/bin/bash
# Runs the app's SpreadsheetImport over SampleImport.xlsx and SampleImport.csv outside Xcode. Builds CoreXLSX and
# its dependencies from the package checkouts of an earlier Xcode build (or the directory given as $1) into a
# temporary folder.
#
#     frontend/Fixtures/SpreadsheetImportCheck/check.sh [SourcePackages/checkouts]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$(dirname "$HERE")"
APP="$(dirname "$FIXTURES")/Movie List"
CHECKOUTS="${1:-$(ls -d ~/Library/Developer/Xcode/DerivedData/Movie_List-*/SourcePackages/checkouts | head -1)}"
OUT="$(mktemp -d)"
cd "$OUT"

find "$CHECKOUTS/XMLCoder/Sources/XMLCoder" -name '*.swift' > xmlcoder.txt
find "$CHECKOUTS/ZIPFoundation/Sources/ZIPFoundation" -name '*.swift' > zip.txt
find "$CHECKOUTS/CoreXLSX/Sources/CoreXLSX" -name '*.swift' > corexlsx.txt
swiftc -suppress-warnings -emit-library -emit-module -module-name XMLCoder @xmlcoder.txt -o libXMLCoder.dylib
swiftc -suppress-warnings -emit-library -emit-module -module-name ZIPFoundation @zip.txt -o libZIPFoundation.dylib
swiftc -suppress-warnings -emit-library -emit-module -module-name CoreXLSX -I . -L . -lXMLCoder -lZIPFoundation @corexlsx.txt -o libCoreXLSX.dylib
swiftc -suppress-warnings -I . -L . -lXMLCoder -lZIPFoundation -lCoreXLSX -Xlinker -rpath -Xlinker "$OUT" \
    "$APP/Services/SpreadsheetImport.swift" "$APP/Services/LetterboxdExport.swift" "$HERE/main.swift" -o check
./check "$FIXTURES"
