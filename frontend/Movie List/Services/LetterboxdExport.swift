//
//  LetterboxdExport.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import Foundation
import ZIPFoundation

struct LetterboxdFilm: Encodable, Hashable {
    let name: String
    let year: Int?
}

struct LetterboxdList: Encodable, Identifiable, Hashable {
    var id: String { fileName }
    let fileName: String
    let name: String
    let overview: String
    let films: [LetterboxdFilm]

    // fileName only identifies the list on device; the backend doesn't need it
    enum CodingKeys: String, CodingKey {
        case name, overview, films
    }
}

enum LetterboxdExportError: LocalizedError {
    case noLists

    var errorDescription: String? {
        switch self {
        case .noLists:
            return "No lists were found. Choose the ZIP from Letterboxd's data export, or CSV files from its lists folder."
        }
    }
}

/// Reads lists out of Letterboxd's data export (Settings → Data → Export Your Data).
/// Accepts the export ZIP itself, or individual list CSVs from its `lists/` folder.
enum LetterboxdExport {

    static func lists(from urls: [URL]) throws -> [LetterboxdList] {
        var lists: [LetterboxdList] = []
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            if url.pathExtension.lowercased() == "zip" {
                lists += try listsInZip(at: url)
            } else if let list = parseList(try Data(contentsOf: url), fileName: url.lastPathComponent) {
                lists.append(list)
            }
        }
        guard !lists.isEmpty else { throw LetterboxdExportError.noLists }
        return lists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func listsInZip(at url: URL) throws -> [LetterboxdList] {
        let archive = try Archive(url: url, accessMode: .read)
        var lists: [LetterboxdList] = []
        for entry in archive where entry.type == .file {
            // Lists live in lists/*.csv; deleted/lists/ holds lists the user has since removed
            let components = entry.path.split(separator: "/")
            guard entry.path.lowercased().hasSuffix(".csv"),
                  components.dropLast().last == "lists",
                  !components.contains("deleted") else { continue }

            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            if let list = parseList(data, fileName: String(components.last ?? "")) {
                lists.append(list)
            }
        }
        return lists
    }

    /// A list CSV holds a metadata block (Date,Name,Tags,URL,Description) followed by the films
    /// (Position,Name,Year,URL,Description). Files without the metadata block are named after the file.
    static func parseList(_ data: Data, fileName: String) -> LetterboxdList? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let rows = parseCSV(text)

        guard let filmHeaderIndex = rows.firstIndex(where: { $0.contains("Name") && $0.contains("Year") }) else { return nil }
        let filmHeader = rows[filmHeaderIndex]
        let nameColumn = filmHeader.firstIndex(of: "Name")!
        let yearColumn = filmHeader.firstIndex(of: "Year")!

        let films: [LetterboxdFilm] = rows[(filmHeaderIndex + 1)...].compactMap { row in
            guard row.count > nameColumn, !row[nameColumn].isEmpty else { return nil }
            let year = row.count > yearColumn ? Int(row[yearColumn]) : nil
            return LetterboxdFilm(name: row[nameColumn], year: year)
        }

        var name = fileName
            .replacingOccurrences(of: ".csv", with: "", options: [.caseInsensitive, .backwards])
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
        var overview = ""
        if let metaHeaderIndex = rows[..<filmHeaderIndex].firstIndex(where: { $0.first == "Date" && $0.contains("Name") }),
           metaHeaderIndex + 1 < filmHeaderIndex {
            let metaHeader = rows[metaHeaderIndex]
            let meta = rows[metaHeaderIndex + 1]
            if let column = metaHeader.firstIndex(of: "Name"), column < meta.count, !meta[column].isEmpty {
                name = meta[column]
            }
            if let column = metaHeader.firstIndex(of: "Description"), column < meta.count {
                overview = meta[column]
            }
        }

        return LetterboxdList(fileName: fileName, name: name, overview: overview, films: films)
    }

    /// RFC 4180 CSV: quoted fields may contain commas, newlines and doubled quotes. Blank lines are dropped.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var characters = text.drop(while: { $0 == "\u{FEFF}" }).makeIterator()
        var pending = characters.next()

        func endRow() {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
            field = ""
        }

        while let character = pending {
            pending = characters.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = characters.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character.isNewline {
                endRow()
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
