// Checks SpreadsheetImport against the sample fixtures. Run it through check.sh next to this file
import Foundation

var failures = 0
func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected { print("ok   \(label)") } else { failures += 1; print("FAIL \(label): got \(actual), expected \(expected)") }
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])

let xlsx = try SpreadsheetImport.sheets(from: dir.appendingPathComponent("SampleImport.xlsx"))
for sheet in xlsx {
    print("--", sheet.name, sheet.headers ?? ["(no header)"], sheet.columns)
    sheet.films.forEach { print("   ", $0) }
}
expect(xlsx.map(\.name), ["Top Films", "Watchlist"], "sheet names")
let top = xlsx[0]
expect(top.columns, SpreadsheetColumns(title: 1, year: 2, rank: 0, rating: 4, watched: 5, notes: 6), "header columns")
expect(top.films.map(\.name), ["Amélie", "Heat", "Crouching Tiger, Hidden Dragon", "Not A Real Film Xyz"], "rank order, inline + rich text")
expect(top.films.map(\.year), [2001, 1995, 2000, 2010], "years from numbers and dates")
expect(top.films.map(\.watched_on), [nil, "2024-01-01", "2023-03-01", nil], "watched dates from Excel numbers and text")
expect(top.films[1].note, "The diner scene", "notes")
let watchlist = xlsx[1]
expect(watchlist.headers == nil, true, "no header row")
expect(watchlist.columns, SpreadsheetColumns(title: 0, year: 1), "fallback columns")
expect(watchlist.films.map(\.name), ["Paris, Texas", "1917", "Past Lives"], "fallback titles")
expect(watchlist.films.map(\.year), [1984, 2019, 2023], "fallback years")

let csv = try SpreadsheetImport.sheets(from: dir.appendingPathComponent("SampleImport.csv"))
expect(csv.map(\.name), ["SampleImport"], "csv named after file")
expect(csv[0].films.map(\.name), ["Heat", "Crouching Tiger, Hidden Dragon"], "csv rank order")
expect(csv[0].films.map(\.watched_on), ["2024-03-01", nil], "csv short date")
expect(csv[0].films.map(\.watched), [true, true], "csv yes = watched")
expect(csv[0].films[1].note, "Said \"wow\"", "csv quoted note")

expect(SpreadsheetImport.rating(from: "★★★½"), 3.5, "star rating")
expect(SpreadsheetImport.rating(from: "8/10"), 0.8, "fraction rating")

// An old binary .xls, by extension and when renamed to .xlsx
let xls = dir.appendingPathComponent("legacy.xls")
let renamed = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("legacy.xlsx")
try Data([0xD0, 0xCF, 0x11, 0xE0, 0, 0]).write(to: renamed)
do {
    _ = try SpreadsheetImport.sheets(from: renamed)
    expect(false, true, "old .xls renamed to .xlsx is rejected")
} catch {
    expect(error.localizedDescription.contains(".xls"), true, "old .xls renamed to .xlsx is rejected")
}
do {
    _ = try SpreadsheetImport.sheets(from: xls)
    expect(false, true, ".xls rejected")
} catch {
    expect(error.localizedDescription.contains(".xls"), true, ".xls rejected")
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
