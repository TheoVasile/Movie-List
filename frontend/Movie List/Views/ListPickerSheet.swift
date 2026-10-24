//
//  ListPickerSheet.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-19.
//

import Foundation
import SwiftUI

/// Picks one or more lists to add a film to, with a way to create a new list on the spot. Used by
/// Discover and by a film's "Add to Other Lists" inside a list
struct ListPickerSheet: View {
    let title: String
    let posterPath: String?
    // Lists the film is already in are shown but can't be picked
    var isAlreadyIn: (CDMovieList) -> Bool = { _ in false }
    // A list to leave out entirely, such as the one the film is being added from
    var excluding: CDMovieList? = nil
    // Picks exactly one list, such as the one Discover's Quick Add sends films to
    var singleChoice = false
    let onAdd: ([CDMovieList]) -> Void

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authViewModel: AuthenticationViewModel
    @FetchRequest(fetchRequest: CDMovieList.fetch()) private var movieLists: FetchedResults<CDMovieList>

    @State private var selected: [CDMovieList] = []
    @State private var showNewListField = false
    @State private var newListName = ""
    @State private var isCreatingList = false
    @State private var createListFailed = false
    @FocusState private var newListFocused: Bool

    // The list a film was most recently added to comes first, since it's the likeliest pick again
    private var lists: [CDMovieList] {
        movieLists
            .filter { $0 != excluding }
            .sorted { ($0.date_modified ?? .distantPast) > ($1.date_modified ?? .distantPast) }
    }

    private var trimmedNewListName: String {
        newListName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.surface.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        newListSection
                        ForEach(Array(lists.enumerated()), id: \.element) { index, list in
                            let alreadyIn = isAlreadyIn(list)
                            Button {
                                toggle(list)
                            } label: {
                                row(list, alreadyIn: alreadyIn)
                            }
                            .buttonStyle(PressableButtonStyle(scale: 0.98))
                            .disabled(alreadyIn)
                            .appearAnimation(delay: Double(min(index, 8)) * 0.04)
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 80)
                }
                if !lists.isEmpty {
                    VStack {
                        Spacer()
                        Button {
                            Haptics.success()
                            onAdd(selected)
                            dismiss()
                        } label: {
                            Text(buttonTitle)
                                .lineLimit(1)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(selected.isEmpty)
                        .opacity(selected.isEmpty ? 0.5 : 1)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                }
            }
            .navigationTitle(singleChoice ? "Choose a List" : "Choose Lists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var buttonTitle: String {
        if singleChoice {
            return selected.first.map { "Use \($0.name ?? "List")" } ?? "Choose a List"
        }
        return selected.isEmpty ? "Choose Lists" : selected.count == 1 ? "Add to \(selected[0].name ?? "List")" : "Add to \(selected.count) Lists"
    }

    private var header: some View {
        HStack(spacing: 14) {
            PosterImage(path: posterPath, cornerRadius: 10, size: .small)
                .frame(width: 54, height: 81)
            VStack(alignment: .leading, spacing: 4) {
                Text(singleChoice ? "QUICK ADD TO" : "ADD TO LISTS")
                    .font(.caption.weight(.heavy))
                    .tracking(2)
                    .foregroundStyle(Theme.accentGradient)
                Text(title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
            }
        }
        .padding(.bottom, 8)
    }

    private func toggle(_ list: CDMovieList) {
        Haptics.tap()
        if let index = selected.firstIndex(of: list) {
            selected.remove(at: index)
        } else if singleChoice {
            selected = [list]
        } else {
            selected.append(list)
        }
    }

    private func row(_ list: CDMovieList, alreadyIn: Bool) -> some View {
        let top = list.movies.sorted { $0.rank < $1.rank }.first
        let isSelected = selected.contains(list)
        return HStack(spacing: 14) {
            PosterImage(path: top?.poster_path, cornerRadius: 8, size: .small)
                .frame(width: 40, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name ?? "No Name")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Text(alreadyIn ? "Already in this list" : "\(list.movies.count) \(list.movies.count == 1 ? "film" : "films")")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: alreadyIn ? "checkmark" : isSelected ? "checkmark.circle.fill" : "circle")
                .font(alreadyIn ? .body.weight(.semibold) : .title2)
                .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
        }
        .padding(12)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5)
        )
        .opacity(alreadyIn ? 0.5 : 1)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // A "New List" button that opens into a name field. With no lists to pick, the field shows straight away
    @ViewBuilder
    private var newListSection: some View {
        if showNewListField || lists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "list.star")
                        .foregroundStyle(Theme.accentGradient)
                    TextField("New list name", text: $newListName)
                        .focused($newListFocused)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .onSubmit(createList)
                        .disabled(isCreatingList)
                }
                .padding(14)
                .background(Theme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                if createListFailed {
                    Label("Couldn't create the list. Try again.", systemImage: "exclamationmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Theme.accentSecondary)
                        .transition(.opacity)
                }
                Button(action: createList) {
                    HStack(spacing: 8) {
                        if isCreatingList {
                            ProgressView().tint(Theme.onAccent)
                        }
                        Text(isCreatingList ? "Creating…" : "Create List")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(trimmedNewListName.isEmpty || isCreatingList)
                .opacity(trimmedNewListName.isEmpty ? 0.5 : 1)
            }
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .onAppear { newListFocused = true }
        } else {
            Button {
                Haptics.tap()
                withAnimation(Theme.spring) { showNewListField = true }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.accentGradient)
                        .frame(width: 40, height: 60)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("New List")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                }
                .padding(12)
                .background(Theme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
            }
            .buttonStyle(PressableButtonStyle(scale: 0.98))
        }
    }

    // The list gets its id from the server, so it's created there first, then ticked with any others
    private func createList() {
        let name = trimmedNewListName
        guard !name.isEmpty, !isCreatingList, let userID = authViewModel.user?.uid else { return }
        isCreatingList = true
        withAnimation { createListFailed = false }
        APIService.shared.createList(userID: userID, name: name, overview: "", isRanked: true) { result in
            isCreatingList = false
            switch result {
            case .success(let serverList):
                let list = CDMovieList(id: serverList.id, name: serverList.name, overview: serverList.overview, context: context)
                do {
                    try context.save()
                } catch {
                    print("Error saving new list:", error)
                }
                Haptics.success()
                AppAnalytics.log(.listCreated(ranked: true))
                withAnimation(Theme.spring) {
                    if singleChoice { selected = [list] } else { selected.append(list) }
                    showNewListField = false
                    newListName = ""
                }
            case .failure(let error):
                print("Error creating list:", error.localizedDescription)
                Haptics.tap()
                withAnimation { createListFailed = true }
            }
        }
    }
}
