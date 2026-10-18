//
//  ListSharing.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-18.
//

import Foundation
import SwiftUI
import UIKit
import ZIPFoundation

// MARK: - Export

/// Writes lists to a ZIP laid out like Letterboxd's own data export: one `lists/<name>.csv` per list in
/// Letterboxd's list format, plus `watched.csv`. Letterboxd, and this app's importer, can read it back
enum ListExport {

    /// Builds the ZIP in the temporary folder and returns its location
    static func makeZip(lists: [CDMovieList]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("movie-list-export-\(timestamp())-utc.zip")
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)

        var usedNames = Set<String>()
        for list in lists.sorted(by: { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }) {
            let base = slug(list.name ?? "list")
            var name = base
            var suffix = 2
            while usedNames.contains(name) {
                name = "\(base)-\(suffix)"
                suffix += 1
            }
            usedNames.insert(name)
            try add(listCSV(list), as: "lists/\(name).csv", to: archive)
        }

        // A film in several lists is listed once
        var seen = Set<Int32>()
        let watched = lists
            .flatMap { $0.movies }
            .filter { $0.watched && seen.insert($0.tmdb_id).inserted }
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
        try add(watchedCSV(watched), as: "watched.csv", to: archive)

        return url
    }

    /// Letterboxd's list format: a version line, the list's details, a blank line, then the films in order
    static func listCSV(_ list: CDMovieList) -> String {
        var lines = [
            "Letterboxd list export v7",
            "Date,Name,Tags,URL,Description",
            row([day(list.creation_date ?? Date()), list.name ?? "", "", "", list.overview ?? ""]),
            "",
            "Position,Name,Year,URL,Description",
        ]
        for movie in list.movies.sorted(by: { $0.rank < $1.rank }) {
            lines.append(row(["\(movie.rank)", movie.title ?? "", Theme.year(from: movie.release_date), "", ""]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Letterboxd's watched format. The app doesn't record when a film was watched, so Date is the export date
    static func watchedCSV(_ movies: [CDMovie]) -> String {
        let today = day(Date())
        let lines = ["Date,Name,Year,Letterboxd URI"]
            + movies.map { row([today, $0.title ?? "", Theme.year(from: $0.release_date), ""]) }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers

    private static func add(_ text: String, as path: String, to archive: Archive) throws {
        let data = Data(text.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }

    /// One CSV row; fields with commas, quotes or line breaks are quoted
    private static func row(_ fields: [String]) -> String {
        fields.map { field in
            guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",")
    }

    /// "Best of 2026!" -> "best-of-2026", like Letterboxd's list URLs
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let words = folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "list" : String(slug.prefix(80))
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm"
        return formatter.string(from: Date())
    }
}

// MARK: - Share image

enum ListShareImage {
    static let maxFilms = 10

    /// Renders a list's top films as an image. Posters are downloaded first, since the renderer draws in
    /// one pass and can't wait for images to load
    @MainActor
    static func render(_ list: CDMovieList, colorScheme: ColorScheme) async -> UIImage? {
        let movies = list.movies.sorted { $0.rank < $1.rank }.prefix(maxFilms)
        var entries: [ListShareCard.Entry] = []
        for movie in movies {
            var poster: UIImage? = nil
            if let url = Theme.posterURL(movie.poster_path, size: .small) {
                poster = await PosterLoader.shared.image(for: url)
            }
            entries.append(.init(rank: Int(movie.rank), title: movie.title ?? "", year: Theme.year(from: movie.release_date), poster: poster))
        }

        let card = ListShareCard(listName: list.name ?? "My List", entries: entries, totalCount: list.movies.count)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.uiImage
    }
}

/// What the share image shows: the list's name and its top films with posters
struct ListShareCard: View {
    struct Entry {
        let rank: Int
        let title: String
        let year: String
        let poster: UIImage?
    }

    let listName: String
    let entries: [Entry]
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entries.count < totalCount ? "MY TOP \(entries.count)" : "MY RANKING")
                    .font(.caption.weight(.heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.accentGradient)
                Text(listName)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
            }
            VStack(spacing: 10) {
                ForEach(entries, id: \.rank) { entry in
                    HStack(spacing: 14) {
                        Text("\(entry.rank)")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(entry.rank <= 3 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                            .frame(width: 36)
                        poster(entry.poster)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                                .font(.headline)
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(2)
                            if !entry.year.isEmpty {
                                Text(entry.year)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            HStack {
                if totalCount > entries.count {
                    Text("+ \(totalCount - entries.count) more ranked")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Label("Movie List", systemImage: "film.stack")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(28)
        .frame(width: 390)
        .background(Theme.background)
    }

    private func poster(_ image: UIImage?) -> some View {
        ZStack {
            Theme.surfaceRaised
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .frame(width: 44, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Share sheet

/// Something to hand to the system share sheet: an image or a file
struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// The system share sheet (AirDrop, Messages, Save to Files, ...)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
