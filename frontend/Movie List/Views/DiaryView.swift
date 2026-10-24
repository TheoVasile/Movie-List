//
//  DiaryView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-19.
//

import Foundation
import SwiftUI
import CoreData

/// Every film the user has watched, newest first and grouped by month, including rewatches. Films
/// marked watched in bulk (a Letterboxd import or a whole list at once) have no real date, so they're
/// counted at the bottom instead of filling up one day
struct DiaryView: View {
    @State private var entries: [DiaryEntry] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var showBulk = false

    private var dated: [DiaryEntry] { entries.filter { !$0.bulk } }
    private var bulk: [DiaryEntry] { entries.filter(\.bulk) }

    private var months: [(title: String, entries: [DiaryEntry])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        var groups: [(title: String, entries: [DiaryEntry])] = []
        for entry in dated {
            let title = entry.date.map(formatter.string(from:)) ?? "Undated"
            if groups.last?.title == title {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((title, [entry]))
            }
        }
        return groups
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if isLoading && entries.isEmpty {
                ProgressView()
                    .tint(Theme.accent)
            } else if loadFailed && entries.isEmpty {
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load your diary",
                               message: "Check your connection and try again.", actionTitle: "Retry", action: load)
            } else if entries.isEmpty {
                EmptyStateView(icon: "book.closed", title: "Your diary is empty",
                               message: "Mark films as watched, or log a watch from a film's info screen, and they'll show up here.")
            } else {
                List {
                    ForEach(months, id: \.title) { month in
                        Section {
                            ForEach(month.entries, id: \.entryID) { entry in
                                DiaryRow(entry: entry)
                                    .swipeActions {
                                        if let id = entry.id {
                                            Button(role: .destructive) {
                                                deleteRewatch(id)
                                            } label: {
                                                Label("Remove", systemImage: "trash")
                                            }
                                        }
                                    }
                            }
                        } header: {
                            Text("\(month.title) · \(month.entries.count) \(month.entries.count == 1 ? "film" : "films")")
                        }
                        .listRowBackground(Theme.surface)
                    }
                    if !bulk.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $showBulk) {
                                ForEach(bulk, id: \.entryID) { entry in
                                    DiaryRow(entry: entry, showsDate: false)
                                }
                            } label: {
                                Text("\(bulk.count) films marked watched in bulk")
                                    .foregroundColor(Theme.textPrimary)
                            }
                        } header: {
                            Text("Imported")
                        } footer: {
                            Text("These were marked watched all at once, by an import or by marking a whole list, so they don't have a real date.")
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await reload() }
            }
        }
        .navigationTitle("Diary")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        isLoading = true
        loadFailed = false
        APIService.shared.fetchDiary { result in
            isLoading = false
            switch result {
            case .success(let loaded): entries = loaded
            case .failure: loadFailed = true
            }
        }
    }

    private func reload() async {
        await withCheckedContinuation { continuation in
            APIService.shared.fetchDiary { result in
                if case .success(let loaded) = result {
                    entries = loaded
                }
                continuation.resume()
            }
        }
    }

    private func deleteRewatch(_ id: Int) {
        let removed = entries.filter { $0.id == id }
        withAnimation { entries.removeAll { $0.id == id } }
        APIService.shared.deleteRewatch(id: id) { result in
            if case .failure = result {
                // Put it back where it was
                entries = (entries + removed).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            }
        }
    }
}

struct DiaryRow: View {
    let entry: DiaryEntry
    var showsDate = true

    var body: some View {
        HStack(spacing: 12) {
            if showsDate, let date = entry.date {
                VStack(spacing: 0) {
                    Text(date.formatted(.dateTime.day()))
                        .font(.title3.weight(.heavy))
                        .foregroundColor(Theme.textPrimary)
                    Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(width: 36)
            }
            PosterImage(path: entry.poster_path, cornerRadius: 6, size: .small)
                .frame(width: 36, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Text(Theme.year(from: entry.release_date))
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            if entry.isRewatch {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accentGradient)
                    .accessibilityLabel("Rewatch")
            }
        }
        .padding(.vertical, 2)
    }
}

/// A film's watch history on its info screen: how many times it's been watched and when, with a button
/// to log another watch on any day
struct WatchHistoryCard: View {
    @ObservedObject var movie: CDMovie
    @State private var entries: [DiaryEntry] = []
    @State private var showLogSheet = false
    @State private var day = Date()
    @State private var isSaving = false
    @State private var saveFailed = false

    private var dated: [DiaryEntry] { entries.filter { !$0.bulk } }

    private var summary: String {
        guard !entries.isEmpty else { return movie.watched ? "Watched" : "Not watched yet" }
        let times = entries.count == 1 ? "Watched once" : "Watched \(entries.count) times"
        guard let last = dated.first?.date else { return times }
        return "\(times) · last \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed.fill")
                .foregroundStyle(Theme.accentGradient)
            Text(summary)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer(minLength: 0)
            Button {
                Haptics.tap()
                day = Date()
                showLogSheet = true
            } label: {
                Label("Log", systemImage: "plus")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accentGradient, in: Capsule())
            }
        }
        .padding(14)
        .cardStyle(cornerRadius: 18)
        .onAppear(perform: load)
        .onChange(of: movie.watched) { _ in load() }
        .sheet(isPresented: $showLogSheet) {
            logSheet
                .presentationDetents([.medium])
        }
    }

    private var logSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker("Watched on", selection: $day, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Theme.accent)
                if saveFailed {
                    Label("Couldn't save. Try again.", systemImage: "exclamationmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Theme.accentSecondary)
                }
            }
            .padding(.horizontal, 16)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(movie.watched ? "Log a Rewatch" : "Log a Watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showLogSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isSaving)
                }
            }
        }
    }

    private func load() {
        APIService.shared.fetchDiary(movieID: movie.id) { result in
            if case .success(let loaded) = result {
                entries = loaded
            }
        }
    }

    private func save() {
        isSaving = true
        saveFailed = false
        APIService.shared.logWatch(movieID: movie.id, on: day) { result in
            isSaving = false
            switch result {
            case .success:
                showLogSheet = false
                AppAnalytics.log(.filmWatched(.diary))
                // The first watch marks the film watched everywhere it appears
                if !movie.watched {
                    movie.watched = true
                    try? movie.managedObjectContext?.save()
                }
                load()
            case .failure:
                saveFailed = true
            }
        }
    }
}
