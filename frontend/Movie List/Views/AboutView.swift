//
//  AboutView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import SwiftUI

/// The app's name and version, and credits for the services its film data comes from. Pushed from Settings.
/// TMDb's API terms ask for their logo and notice somewhere users can find them, which is here
struct AboutView: View {
    // "1.0 (1)", from the app's Info.plist
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                    .appearAnimation(delay: 0.05)
                VStack(alignment: .leading, spacing: 10) {
                    Text("DATA & CREDITS")
                        .font(.caption2.weight(.heavy))
                        .tracking(1.2)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.leading, 4)
                    tmdbCard
                    creditRow(icon: "play.tv",
                              title: "JustWatch",
                              detail: "Streaming availability data provided by JustWatch.",
                              link: URL(string: "https://www.justwatch.com"))
                    creditRow(icon: "play.rectangle.fill",
                              title: "YouTube",
                              detail: "Trailers are hosted on and play from YouTube.",
                              link: URL(string: "https://www.youtube.com"))
                }
                .appearAnimation(delay: 0.12)

                Text("CineList is an independent app and isn't affiliated with, endorsed by or sponsored by any of these services. Film titles, posters and images belong to their respective owners.")
                    .font(.caption)
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(Theme.onAccent)
                .frame(width: 76, height: 76)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Theme.shadow.opacity(0.4), radius: 14, y: 8)
            Text("CineList")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.textPrimary)
            Text("Rank, track and share the films you love.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Text(version)
                .font(.footnote.weight(.semibold))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    // TMDb's logo and their notice, word for word as their terms ask
    private var tmdbCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("TMDBLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 22)
                .accessibilityLabel("The Movie Database (TMDB)")
            Text("Film and TV information, posters, images and recommendations come from The Movie Database.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.footnote.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Link(destination: URL(string: "https://www.themoviedb.org")!) {
                Label("themoviedb.org", systemImage: "arrow.up.right")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.accent)
            }
            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardStyle()
    }

    private func creditRow(icon: String, title: String, detail: String, link: URL?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            if let link {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Theme.textSecondary)
                }
                .accessibilityLabel("Open \(title)")
                .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
            }
        }
        .padding(14)
        .cardStyle()
    }
}
