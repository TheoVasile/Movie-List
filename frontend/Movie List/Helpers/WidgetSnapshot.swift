//
//  WidgetSnapshot.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-19.
//

import Foundation

/// What the Home Screen widgets show. The app writes it to the shared App Group container after each
/// sync, and the widget reads it, since a widget can't open the app's database or sign in. Built into
/// both the app and the widget extension
struct WidgetSnapshot: Codable {
    struct Film: Codable {
        let tmdbID: Int64
        let title: String
        let year: String
        let posterPath: String?
        let rank: Int
    }

    // The user's biggest list and its top films
    let listName: String
    let top: [Film]
    // Unwatched films to suggest for tonight, from the watchlist if there is one
    let tonight: [Film]
    let updated: Date

    static let appGroup = "group.Theodor-Vasile.Movie-List"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func remove() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The unwatched film for today, the same all day and different the next
    func tonightPick(on date: Date = Date()) -> Film? {
        guard !tonight.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        return tonight[day % tonight.count]
    }

    static func posterURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(path)")
    }

    /// Opens the film's info screen in the app
    static func link(for film: Film) -> URL? {
        URL(string: "cinelist://film/\(film.tmdbID)")
    }
}
