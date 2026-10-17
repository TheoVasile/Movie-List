//
//  MovieDetailView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import Foundation
import SwiftUI

struct MovieDetailView: View {
    @ObservedObject var movie: CDMovie
    var listName: String? = nil
    var onCompare: (() -> Void)? = nil
    var onSetRank: (() -> Void)? = nil
    var onToggleWatched: (() -> Void)? = nil

    @State private var revealed = false
    @State private var imdbID: String? = nil

    private static let imdbCacheKey = "imdbIDs"

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    details
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                revealed = true
            }
            loadIMDbID()
        }
    }

    // The film's IMDb page once its id is known, otherwise an IMDb search for its title and year
    private var imdbURL: URL? {
        if let imdbID {
            return URL(string: "https://www.imdb.com/title/\(imdbID)/")
        }
        var components = URLComponents(string: "https://www.imdb.com/find/")
        let year = Theme.year(from: movie.release_date)
        components?.queryItems = [
            URLQueryItem(name: "q", value: [movie.title ?? "", year].filter { !$0.isEmpty }.joined(separator: " ")),
            URLQueryItem(name: "s", value: "tt"),
        ]
        return components?.url
    }

    // IMDb ids never change, so each one is looked up once and kept on this device
    private func loadIMDbID() {
        let key = String(movie.tmdb_id)
        let cache = UserDefaults.standard.dictionary(forKey: Self.imdbCacheKey) as? [String: String] ?? [:]
        if let cached = cache[key] {
            imdbID = cached
            return
        }
        guard movie.tmdb_id > 0 else { return }
        APIService.shared.fetchIMDbID(tmdbID: Int64(movie.tmdb_id)) { result in
            guard case .success(let id?) = result else { return }
            imdbID = id
            var cache = UserDefaults.standard.dictionary(forKey: Self.imdbCacheKey) as? [String: String] ?? [:]
            cache[key] = id
            UserDefaults.standard.set(cache, forKey: Self.imdbCacheKey)
        }
    }

    private var imdbLink: some View {
        Link(destination: imdbURL ?? URL(string: "https://www.imdb.com")!) {
            HStack(spacing: 10) {
                Text("IMDb")
                    .font(.system(size: 14, weight: .black))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.96, green: 0.77, blue: 0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(imdbID == nil ? "Search on IMDb" : "View on IMDb")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(14)
            .cardStyle()
        }
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            PosterBackdrop(path: movie.poster_path)
                .frame(height: 460)
            PosterImage(path: movie.poster_path, cornerRadius: 18, size: .xlarge)
                .frame(width: 200, height: 300)
                .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
                .scaleEffect(revealed ? 1 : 0.85)
                .opacity(revealed ? 1 : 0)
                .rotation3DEffect(.degrees(revealed ? 0 : 12), axis: (x: 1, y: 0, z: 0))
                .padding(.bottom, 10)
        }
        .frame(height: 460)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if movie.rank > 0 {
                        Text(listName.map { "#\(movie.rank) IN \($0.uppercased())" } ?? "#\(movie.rank)")
                            .font(.caption.weight(.heavy))
                            .tracking(1.5)
                            .foregroundStyle(Theme.accentGradient)
                    }
                    if movie.watched {
                        WatchedTag()
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                Text(movie.title ?? "")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .appearAnimation(delay: 0.1)

            HStack(spacing: 8) {
                if let date = movie.release_date {
                    MetaChip(icon: "calendar", text: date.formatted(.dateTime.year().month(.abbreviated).day()))
                }
                if let language = movie.original_language, !language.isEmpty {
                    MetaChip(icon: "globe", text: language.uppercased())
                }
                if movie.popularity > 0 {
                    MetaChip(icon: "flame.fill", text: String(format: "%.0f", movie.popularity))
                }
            }
            .appearAnimation(delay: 0.18)

            if onCompare != nil || onSetRank != nil {
                HStack(spacing: 12) {
                    if let onCompare {
                        Button {
                            Haptics.tap()
                            onCompare()
                        } label: {
                            Label("Compare", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    if let onSetRank {
                        Button {
                            Haptics.tap()
                            onSetRank()
                        } label: {
                            Label("Set Rank", systemImage: "number")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .appearAnimation(delay: 0.26)
            }

            if let onToggleWatched {
                Button {
                    Haptics.tap()
                    onToggleWatched()
                } label: {
                    Label(movie.watched ? "Mark as Unwatched" : "Mark as Watched",
                          systemImage: movie.watched ? "eye.slash" : "eye")
                }
                .buttonStyle(SecondaryButtonStyle())
                .appearAnimation(delay: 0.3)
            }

            imdbLink
                .appearAnimation(delay: 0.32)

            if let overview = movie.overview, !overview.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Overview")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(overview)
                        .font(.body)
                        .foregroundColor(Theme.textSecondary)
                        .lineSpacing(4)
                }
                .appearAnimation(delay: 0.34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MovieDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            MovieDetailView(movie: CDMovie.example, listName: "Christmas Movies", onCompare: {}, onSetRank: {})
        }
        .preferredColorScheme(.dark)
    }
}
