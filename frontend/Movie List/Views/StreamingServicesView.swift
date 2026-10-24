//
//  StreamingServicesView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-20.
//

import Foundation
import SwiftUI

/// Picks the streaming services the user has, so Marquee can say when a watchlist film arrives on one of them.
/// Saved to the server as soon as one is tapped
struct StreamingServicesView: View {
    // Called with how many services are picked, after each save
    var onSaved: (Int) -> Void = { _ in }

    @State private var services: [StreamingService] = []
    @State private var chosen: Set<Int> = []
    @State private var isLoading = true
    @State private var failed = false

    private var country: String {
        let code = Locale.current.region?.identifier ?? "US"
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }

    var body: some View {
        Form {
            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                ForEach(services) { service in
                    Button {
                        toggle(service)
                    } label: {
                        HStack(spacing: 12) {
                            ProviderLogo(provider: WatchProvider(id: service.id, name: service.name, logo_path: service.logo_path), size: 32)
                            Text(service.name)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: chosen.contains(service.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(service.id) ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                        }
                    }
                    .accessibilityAddTraits(chosen.contains(service.id) ? .isSelected : [])
                }
            } footer: {
                Text("Pick the ones you subscribe to. When a film on your watchlist starts streaming on one of them in \(country), you'll get a notification, at most once a day.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("My Streaming Services")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't save", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
        .onAppear(perform: load)
    }

    private func load() {
        APIService.shared.fetchStreamingServices { result in
            if case .success(let loaded) = result { services = loaded }
            APIService.shared.fetchStreamingPreferences { result in
                isLoading = false
                if case .success(let saved) = result { chosen = Set(saved.services) }
            }
        }
    }

    private func toggle(_ service: StreamingService) {
        Haptics.tap()
        let before = chosen
        if chosen.contains(service.id) { chosen.remove(service.id) } else { chosen.insert(service.id) }
        APIService.shared.saveStreamingPreferences(services: Array(chosen)) { result in
            switch result {
            case .success(let saved):
                chosen = Set(saved.services)
                onSaved(saved.services.count)
                // Lists showing what's on the user's services check again with the new ones
                StreamingNowStore.shared.servicesChanged()
            case .failure:
                chosen = before
                failed = true
            }
        }
    }
}
