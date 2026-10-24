//
//  CineListWidget.swift
//  CineListWidget
//
//  Created by Theo Vasile on 2026-10-19.
//

import Foundation
import SwiftUI
import WidgetKit

@main
struct CineListWidgets: WidgetBundle {
    var body: some Widget {
        TopFilmsWidget()
        TonightWidget()
    }
}

// MARK: - Timeline

struct FilmsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let posters: [Int64: UIImage]

    static let placeholder = FilmsEntry(date: Date(), snapshot: nil, posters: [:])
}

/// Reads the snapshot the app saved and downloads the posters it needs. The app asks for a reload
/// after each sync; otherwise it refreshes at midnight, when Tonight's pick changes
struct FilmsProvider: TimelineProvider {
    func placeholder(in context: Context) -> FilmsEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (FilmsEntry) -> Void) {
        makeEntry(completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FilmsEntry>) -> Void) {
        makeEntry { entry in
            let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(24 * 60 * 60))
            completion(Timeline(entries: [entry], policy: .after(midnight)))
        }
    }

    private func makeEntry(completion: @escaping (FilmsEntry) -> Void) {
        let snapshot = WidgetSnapshot.load()
        var films = snapshot?.top ?? []
        if let pick = snapshot?.tonightPick() {
            films.append(pick)
        }
        downloadPosters(films) { posters in
            completion(FilmsEntry(date: Date(), snapshot: snapshot, posters: posters))
        }
    }

    private func downloadPosters(_ films: [WidgetSnapshot.Film], completion: @escaping ([Int64: UIImage]) -> Void) {
        var posters: [Int64: UIImage] = [:]
        let group = DispatchGroup()
        let lock = NSLock()
        for film in films {
            guard let url = WidgetSnapshot.posterURL(film.posterPath) else { continue }
            group.enter()
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            URLSession.shared.dataTask(with: request) { data, _, _ in
                // Kept small: widgets have a tight memory limit
                if let data, let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 240, height: 360)) {
                    lock.lock()
                    posters[film.tmdbID] = image
                    lock.unlock()
                }
                group.leave()
            }.resume()
        }
        group.notify(queue: .main) { completion(posters) }
    }
}

// MARK: - Widgets

struct TopFilmsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TopFilms", provider: FilmsProvider()) { entry in
            TopFilmsView(entry: entry)
        }
        .configurationDisplayName("Your Top Films")
        .description("Your #1 film, or your top 3, from your biggest list.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TonightWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Tonight", provider: FilmsProvider()) { entry in
            TonightView(entry: entry)
        }
        .configurationDisplayName("Tonight?")
        .description("A different unwatched film from your watchlist every day.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Views

private enum WidgetColors {
    static let background = LinearGradient(colors: [Color(red: 0.08, green: 0.08, blue: 0.12), Color(red: 0.03, green: 0.03, blue: 0.05)],
                                           startPoint: .top, endPoint: .bottom)
    static let accent = LinearGradient(colors: [Color(red: 1.0, green: 0.78, blue: 0.25), Color(red: 0.96, green: 0.36, blue: 0.32)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct TopFilmsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FilmsEntry

    var body: some View {
        if let snapshot = entry.snapshot, let first = snapshot.top.first {
            if family == .systemMedium {
                medium(snapshot)
                    .widgetBackground()
            } else {
                PosterLabel(film: first, label: "#1 IN \(snapshot.listName.uppercased())")
                    .widgetURL(WidgetSnapshot.link(for: first))
                    .widgetBackground(poster: entry.posters[first.tmdbID])
            }
        } else {
            EmptyWidgetView(message: "Open Marquee to rank your films.")
                .widgetBackground()
        }
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.listName.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(WidgetColors.accent)
                .lineLimit(1)
            HStack(spacing: 10) {
                ForEach(snapshot.top.prefix(3), id: \.tmdbID) { film in
                    Link(destination: WidgetSnapshot.link(for: film) ?? URL(string: "cinelist://")!) {
                        VStack(alignment: .leading, spacing: 4) {
                            PosterImageView(image: entry.posters[film.tmdbID])
                                .overlay(alignment: .topLeading) {
                                    Text("\(film.rank)")
                                        .font(.caption2.weight(.heavy))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(WidgetColors.accent, in: Capsule())
                                        .padding(4)
                                }
                            Text(film.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

struct TonightView: View {
    let entry: FilmsEntry

    var body: some View {
        if let pick = entry.snapshot?.tonightPick(on: entry.date) {
            PosterLabel(film: pick, label: "TONIGHT?")
                .widgetURL(WidgetSnapshot.link(for: pick))
                .widgetBackground(poster: entry.posters[pick.tmdbID])
        } else {
            EmptyWidgetView(message: "Add unwatched films to a watchlist for a pick each day.")
                .widgetBackground()
        }
    }
}

/// The label and title shown over a full-widget poster, which is drawn as the widget's background
struct PosterLabel: View {
    let film: WidgetSnapshot.Film
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(WidgetColors.accent)
                .lineLimit(1)
            Text(film.title)
                .font(.footnote.weight(.bold))
                .foregroundColor(.white)
                .lineLimit(2)
            if !film.year.isEmpty {
                Text(film.year)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

struct PosterImageView: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(2/3, contentMode: .fill)
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
                    .aspectRatio(2/3, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct EmptyWidgetView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "film.stack")
                .font(.title3)
                .foregroundStyle(WidgetColors.accent)
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private extension View {
    /// iOS 17 needs the background declared this way so it can remove it where widgets have none;
    /// iOS 16 just draws it
    @ViewBuilder
    func widgetBackground(poster: UIImage? = nil) -> some View {
        let background = ZStack {
            WidgetColors.background
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                // Keeps the title readable over any poster
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            }
        }
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { background }
        } else {
            padding(12).background(background)
        }
    }
}
