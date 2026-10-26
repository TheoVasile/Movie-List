//
//  SpreadsheetImport.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-24.
//

import Foundation
import CoreXLSX

/// One film read from a spreadsheet row, in the shape the backend's /import/films expects
struct SpreadsheetFilm: Encodable, Hashable {
    let name: String
    let year: Int?
    // "YYYY-MM-DD"
    let watched_on: String?
    // Marked watched without a date, e.g. "Yes" or "x"
    let watched: Bool
    let note: String?
}

/// Which column holds what, as indexes into a row. Only the title is required
struct SpreadsheetColumns: Hashable {
    var title = 0
    var year: Int?
    var rank: Int?
    var rating: Int?
    var watched: Int?
    var notes: Int?
}

/// A sheet of a workbook (or a whole CSV), read and ready to import as one list
struct SpreadsheetSheet: Identifiable, Hashable {
    let id: Int
    // The name a new list gets: the file's when it has one sheet, otherwise the sheet's
    let name: String
    // Column names from the header row, or nil when the sheet has none and the first column is taken as titles
    let headers: [String]?
    let columns: SpreadsheetColumns
    // In list order: by the rank column, else best rated first, else the sheet's own order
    let films: [SpreadsheetFilm]
}

enum SpreadsheetImportError: LocalizedError {
    case legacyExcel
    case unreadable
    case noFilms

    var errorDescription: String? {
        switch self {
        case .legacyExcel:
            return "Older Excel files (.xls) can't be read. Open it in Excel or Numbers and save it as .xlsx or .csv, then try again."
        case .unreadable:
            return "That file couldn't be read. Choose an Excel workbook (.xlsx) or a CSV file."
        case .noFilms:
            return "No films were found. Put one film per row, with the titles in a column called Title (or in the first column)."
        }
    }
}

/// Reads films out of an Excel workbook (.xlsx) or CSV file. Each sheet with films in it becomes a list. Columns are
/// found by their header names (Title, Year, Rank, Rating, Watched, Notes and similar), falling back to titles in the
/// first column when there's no header row
enum SpreadsheetImport {

    static func sheets(from url: URL) throws -> [SpreadsheetSheet] {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension != "xls" else { throw SpreadsheetImportError.legacyExcel }
        let data = try Data(contentsOf: url)
        let fileName = url.deletingPathExtension().lastPathComponent

        let tables: [(name: String, rows: [[String]])]
        if fileExtension == "csv" || fileExtension == "txt" {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
                throw SpreadsheetImportError.unreadable
            }
            tables = [(fileName, LetterboxdExport.parseCSV(text))]
        } else {
            // An .xls saved with the wrong extension isn't a ZIP, so it fails here too
            guard data.starts(with: [0x50, 0x4B]) else {
                throw data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) ? SpreadsheetImportError.legacyExcel : SpreadsheetImportError.unreadable
            }
            tables = try workbookTables(data)
        }

        let sheets = tables.enumerated().compactMap { index, table in
            sheet(id: index, name: tables.count == 1 ? fileName : table.name, rows: table.rows)
        }
        guard !sheets.isEmpty else { throw SpreadsheetImportError.noFilms }
        return sheets
    }

    /// Every worksheet's cells as text, in workbook order. Cells are placed by their column letter, since rows
    /// leave out empty cells
    static func workbookTables(_ data: Data) throws -> [(name: String, rows: [[String]])] {
        guard let file = try? XLSXFile(data: data) else { throw SpreadsheetImportError.unreadable }
        // Workbooks with only numbers have no shared strings
        let sharedStrings = try? file.parseSharedStrings()
        let firstColumn = ColumnReference("A")!

        var tables: [(name: String, rows: [[String]])] = []
        for workbook in try file.parseWorkbooks() {
            for (index, sheet) in try file.parseWorksheetPathsAndNames(workbook: workbook).enumerated() {
                let worksheet = try file.parseWorksheet(at: sheet.path)
                let rows: [[String]] = (worksheet.data?.rows ?? []).compactMap { row in
                    var values: [String] = []
                    for cell in row.cells {
                        let column = firstColumn.distance(to: cell.reference.column)
                        // Sheets can reach column XFD; nothing past a few dozen columns is a film's
                        guard column >= 0, column < 100 else { continue }
                        if values.count <= column {
                            values += Array(repeating: "", count: column - values.count + 1)
                        }
                        values[column] = text(of: cell, sharedStrings: sharedStrings)
                    }
                    return values.contains { !$0.isEmpty } ? values : nil
                }
                tables.append((sheet.name ?? "Sheet \(index + 1)", rows))
            }
        }
        return tables
    }

    private static func text(of cell: Cell, sharedStrings: SharedStrings?) -> String {
        let value: String?
        switch cell.type {
        case .sharedString:
            if let index = cell.value.flatMap(Int.init), let item = sharedStrings?.items[safe: index] {
                // Formatted text comes in runs rather than one string
                value = item.text ?? item.richText.compactMap(\.text).joined()
            } else {
                value = nil
            }
        case .inlineStr:
            value = cell.inlineString?.text
        case .error:
            value = nil
        default:
            value = cell.value
        }
        return (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Columns

    private static let headerNames: [(keyPath: WritableKeyPath<SpreadsheetColumns, Int?>, names: Set<String>)] = [
        (\.year, ["year", "releaseyear", "released", "releasedate", "yr", "yearreleased"]),
        (\.rank, ["rank", "ranking", "position", "pos", "#", "no", "number", "order", "place", "spot"]),
        (\.rating, ["rating", "myrating", "score", "myscore", "stars", "rate", "grade"]),
        (\.watched, ["watched", "watcheddate", "datewatched", "watchedon", "date", "seen", "seenon", "dateseen", "viewed", "viewedon", "watchdate"]),
        (\.notes, ["notes", "note", "comments", "comment", "review", "thoughts", "mynotes"]),
    ]
    private static let titleNames: Set<String> = ["title", "name", "film", "movie", "movietitle", "filmtitle", "filmname", "moviename", "films", "movies"]

    // "Release Date" -> "releasedate"; "#" stays, since it's a common rank header
    private static func headerKey(_ header: String) -> String {
        header.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "#" }
    }

    /// The header row's index and the columns it names, looking a few rows down for sheets with a title row above
    /// the table. Without one, titles are the first column and years whichever column holds mostly years
    static func detectColumns(_ rows: [[String]]) -> (headerRow: Int?, columns: SpreadsheetColumns) {
        for (index, row) in rows.prefix(5).enumerated() {
            let keys = row.map(headerKey)
            guard let title = keys.firstIndex(where: titleNames.contains) else { continue }
            var columns = SpreadsheetColumns(title: title)
            for (keyPath, names) in headerNames {
                columns[keyPath: keyPath] = keys.indices.first { $0 != title && names.contains(keys[$0]) }
            }
            return (index, columns)
        }

        var columns = SpreadsheetColumns()
        let sample = rows.prefix(50)
        let width = sample.map(\.count).max() ?? 0
        columns.year = (1..<max(width, 1)).first { column in
            let values = sample.compactMap { $0[safe: column] }.filter { !$0.isEmpty }
            return !values.isEmpty && values.filter { year(from: $0) != nil }.count * 10 >= values.count * 8
        }
        return (nil, columns)
    }

    // MARK: - Rows

    static func sheet(id: Int, name: String, rows: [[String]]) -> SpreadsheetSheet? {
        let (headerRow, columns) = detectColumns(rows)
        let body = headerRow.map { rows.dropFirst($0 + 1) } ?? rows[...]

        var films: [(film: SpreadsheetFilm, rank: Double?, rating: Double?)] = []
        for row in body {
            guard let title = row[safe: columns.title], !title.isEmpty else { continue }
            let watchedText = columns.watched.flatMap { row[safe: $0] } ?? ""
            let watchedOn = date(from: watchedText)
            let note = columns.notes.flatMap { row[safe: $0] } ?? ""
            let film = SpreadsheetFilm(
                name: title,
                year: columns.year.flatMap { row[safe: $0] }.flatMap(year),
                watched_on: watchedOn,
                watched: watchedOn != nil || isYes(watchedText),
                note: note.isEmpty ? nil : note
            )
            films.append((film, columns.rank.flatMap { row[safe: $0] }.flatMap(number), columns.rating.flatMap { row[safe: $0] }.flatMap(rating)))
        }
        guard !films.isEmpty else { return nil }

        // Stable sorts, with unranked or unrated rows after the rest in the sheet's order
        if columns.rank != nil {
            films = films.enumerated().sorted { a, b in
                switch (a.element.rank, b.element.rank) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
        } else if columns.rating != nil {
            films = films.enumerated().sorted { a, b in
                switch (a.element.rating, b.element.rating) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
        }

        return SpreadsheetSheet(id: id, name: name, headers: headerRow.map { rows[$0] }, columns: columns, films: films.map(\.film))
    }

    private static let yearPattern = try! NSRegularExpression(pattern: "(?<![0-9])(18[7-9][0-9]|19[0-9]{2}|20[0-9]{2})(?![0-9])")

    /// A release year from "1994", "1994-09-23", "(1994)" or an Excel date number
    static func year(from text: String) -> Int? {
        if let serial = Double(text), serial > 2100 {
            return excelDate(serial).flatMap { Int($0.prefix(4)) }
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = yearPattern.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) else { return nil }
        return Int(text[swiftRange])
    }

    private static func number(from text: String) -> Double? {
        Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "#.)").union(.whitespaces)))
    }

    /// A rating as a number for ordering: "4.5", "8/10", "★★★½" or "85%"
    static func rating(from text: String) -> Double? {
        let stars = text.filter { $0 == "★" }.count
        if stars > 0 || text.contains("½") {
            return Double(stars) + (text.contains("½") ? 0.5 : 0)
        }
        let parts = text.split(separator: "/")
        if parts.count == 2, let value = Double(parts[0].trimmingCharacters(in: .whitespaces)),
           let scale = Double(parts[1].trimmingCharacters(in: .whitespaces)), scale > 0 {
            return value / scale
        }
        return Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    private static func isYes(_ text: String) -> Bool {
        ["yes", "y", "x", "true", "1", "✓", "✔", "watched", "seen", "done"].contains(text.lowercased())
    }

    private static let dateFormats = ["yyyy-MM-dd", "yyyy/MM/dd", "M/d/yyyy", "M/d/yy", "d.M.yyyy", "MMM d, yyyy", "MMMM d, yyyy", "d MMM yyyy", "d MMMM yyyy"]
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        return formatter
    }()

    /// A watched date as "YYYY-MM-DD", from an Excel date number or a written date. Slashed dates are read
    /// month first, as Excel writes them in the US
    static func date(from text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if let serial = Double(text) {
            return serial > 2100 ? excelDate(serial) : nil
        }
        // "2024-03-01T20:15:00" from date cells and ISO exports
        let candidate = text.count > 10 && text.dropFirst(10).first == "T" ? String(text.prefix(10)) : text
        for format in dateFormats {
            dateFormatter.dateFormat = format
            // A four-digit year pattern reads "3/1/24" as the year 24, so those fall through to the two-digit one
            if let date = dateFormatter.date(from: candidate), Calendar(identifier: .gregorian).component(.year, from: date) >= 1870 {
                dateFormatter.dateFormat = "yyyy-MM-dd"
                return dateFormatter.string(from: date)
            }
        }
        return nil
    }

    /// Excel stores dates as days since 30 December 1899
    private static func excelDate(_ serial: Double) -> String? {
        guard serial < 100_000 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let epoch = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30)),
              let date = calendar.date(byAdding: .day, value: Int(serial), to: epoch) else { return nil }
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.string(from: date)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
