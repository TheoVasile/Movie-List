//
//  TrailerView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-20.
//

import Foundation
import SwiftUI
import WebKit

/// Trailers, fetched once per film and kept for the rest of the session, including "this film has none"
final class TrailerStore {
    static let shared = TrailerStore()
    private var cache: [Int64: Trailer] = [:]

    /// Calls back on the main thread, straight away if cached; nothing happens when the lookup fails
    func load(tmdbID: Int64, completion: @escaping (Trailer) -> Void) {
        guard tmdbID > 0 else { return }
        if let cached = cache[tmdbID] {
            completion(cached)
            return
        }
        APIService.shared.fetchTrailer(tmdbID: tmdbID) { result in
            guard case .success(let trailer) = result else { return }
            self.cache[tmdbID] = trailer
            completion(trailer)
        }
    }
}

/// "▶︎ Trailer", which plays the film's trailer in a sheet. Shows nothing until a trailer is found, and nothing at
/// all for films without one. onPoster styles it for the dark gradient on Discover cards
struct TrailerButton: View {
    let tmdbID: Int64
    let title: String
    var onPoster = false

    @State private var trailer: Trailer? = nil
    @State private var playing = false

    var body: some View {
        Group {
            if let trailer, trailer.key != nil {
                Button {
                    Haptics.tap()
                    playing = true
                } label: {
                    Label("Trailer", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(onPoster ? Theme.posterText : Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background {
                            if onPoster {
                                Capsule().fill(.ultraThinMaterial)
                            } else {
                                Capsule().fill(Theme.surface)
                                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                            }
                        }
                }
                .buttonStyle(PressableButtonStyle(scale: 0.94))
                .accessibilityLabel("Play Trailer")
                .transition(.opacity)
                .sheet(isPresented: $playing) {
                    TrailerSheet(trailer: trailer, title: title)
                }
            } else {
                // Gives onAppear something to fire on while there's nothing to show
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onAppear {
            TrailerStore.shared.load(tmdbID: tmdbID) { loaded in
                withAnimation(Theme.spring) { trailer = loaded }
            }
        }
    }
}

/// The trailer playing in YouTube's embedded player, with a way out to the YouTube app
struct TrailerSheet: View {
    let trailer: Trailer
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let key = trailer.key {
                    YouTubePlayer(videoKey: key)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Theme.shadow.opacity(0.5), radius: 18, y: 8)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title3.weight(.bold))
                            .foregroundColor(Theme.textPrimary)
                        if let name = trailer.name {
                            Text(name)
                                .font(.subheadline)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                        Link(destination: url) {
                            Label("Open in YouTube", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accentGradient)
                        }
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Trailer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// YouTube's embedded player in a web view. The page is given an https origin because YouTube refuses to play
/// embeds that don't say where they're embedded
struct YouTubePlayer: UIViewRepresentable {
    let videoKey: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedKey != videoKey else { return }
        context.coordinator.loadedKey = videoKey
        let origin = "https://theodor-vasile.cinelist.app"
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube.com/embed/\(videoKey)?playsinline=1&autoplay=1&rel=0&modestbranding=1&origin=\(origin)"
          referrerpolicy="strict-origin-when-cross-origin"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: origin))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedKey: String? = nil
    }
}
