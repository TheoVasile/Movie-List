//
//  SharedListViews.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-20.
//

import Foundation
import SwiftUI

/// Everyone on a shared list as a row of overlapping faces, at the very top of the list. Tapping it shows the
/// contributors, where the owner adds and removes people. Shows nothing on a list only the user is on
struct ContributorAvatars: View {
    let listID: Int64
    let action: () -> Void
    @ObservedObject private var sharing = ListSharing.shared

    // Faces shown before the rest fold into a "+N"
    private static let maxShown = 5
    private static let size: CGFloat = 30

    private var members: [ListMember] { sharing.members(of: listID) }

    // "Sam", "Sam and Ana", "Sam, Ana and Lee"
    static func names(_ all: [String]) -> String {
        guard all.count > 1 else { return all.first ?? "" }
        return all.dropLast().joined(separator: ", ") + " and " + (all.last ?? "")
    }

    var body: some View {
        if sharing.isShared(listID) && members.count > 1 {
            Button {
                Haptics.tap()
                action()
            } label: {
                HStack(spacing: -8) {
                    ForEach(members.prefix(Self.maxShown)) { person in
                        Avatar(name: person.display_name, size: Self.size, handle: person.is_me ? nil : person.handle, version: person.avatar_version)
                            .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                    }
                    if members.count > Self.maxShown {
                        Text("+\(members.count - Self.maxShown)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(Theme.textPrimary)
                            .frame(width: Self.size, height: Self.size)
                            .background(Theme.surfaceRaised, in: Circle())
                            .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.96))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Contributors: \(Self.names(members.map { $0.is_me ? "you" : "@\($0.handle)" }))")
            .accessibilityHint("Shows who can edit this list")
        }
    }
}

/// A list's actions, the same three everywhere: the ••• by the list's name, the ••• on its card on Home and a long
/// press on that card. Deleting and leaving the list are in Edit List, and exporting is in the Share menu
struct ListMenuItems: View {
    let listID: Int64
    // Reordering needs at least two films
    var canReorder = true
    let onEdit: () -> Void
    let onAddContributor: () -> Void
    let onReorder: () -> Void
    @ObservedObject private var sharing = ListSharing.shared
    @ObservedObject private var sync = SyncStatus.shared

    var body: some View {
        // Who owns the list isn't known until the lists first load
        let loading = sync.isFirstSync
        let isOwner = sharing.isOwner(listID)
        Button {
            onEdit()
        } label: {
            Label("Edit List", systemImage: "pencil")
        }
        .disabled(loading)
        // Shown to everyone so the menu is always the same three items, but only the owner can invite people
        Button {
            onAddContributor()
        } label: {
            Label("Add Contributor", systemImage: "person.badge.plus")
            if !isOwner {
                Text("Only the owner can add people")
            }
        }
        .disabled(loading || !isOwner)
        Button {
            onReorder()
        } label: {
            Label("Reorder", systemImage: "arrow.up.arrow.down")
            if !canReorder {
                Text("Needs at least two films")
            }
        }
        .disabled(!canReorder)
    }
}

/// A list's contributors: who can edit it. The owner can invite people they follow and take people off; anyone else can leave
struct ShareListSheet: View {
    let listID: Int64
    let listName: String
    // Called after the user leaves the list, so the list screen can close
    var onLeft: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sharing = ListSharing.shared
    @ObservedObject private var social = SocialStore.shared
    // Handles being added or removed, which show a spinner in place of their button
    @State private var busy: Set<String> = []
    @State private var errorMessage: String? = nil
    @State private var confirmingLeave = false

    private var isOwner: Bool { sharing.isOwner(listID) }

    private var invitable: [UserSummary] {
        let onList = Set(sharing.members(of: listID).map(\.handle))
        return social.following.filter { !onList.contains($0.handle) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !sharing.members(of: listID).isEmpty {
                    Section {
                        ForEach(sharing.members(of: listID)) { person in
                            memberRow(person)
                        }
                    } header: {
                        Text("Contributors")
                    } footer: {
                        Text("Everyone here can add, rank and remove films. Only the owner can rename or delete the list.")
                    }
                    .listRowBackground(Theme.surface)
                }

                if isOwner {
                    Section {
                        if invitable.isEmpty {
                            Text(social.following.isEmpty ? "Follow some friends to share lists with them." : "Everyone you follow is already on this list.")
                                .font(.subheadline)
                                .foregroundColor(Theme.textSecondary)
                        }
                        ForEach(invitable) { person in
                            HStack(spacing: 12) {
                                Avatar(name: person.display_name, size: 34, handle: person.handle, version: person.avatar_version)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("@\(person.handle)")
                                        .foregroundColor(Theme.textPrimary)
                                    Text(person.display_name)
                                        .font(.caption)
                                        .foregroundColor(Theme.textSecondary)
                                }
                                Spacer()
                                if busy.contains(person.handle) {
                                    ProgressView()
                                } else {
                                    Button("Add") { invite(person) }
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(Theme.accentGradient)
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    } header: {
                        Text("Add Contributors You Follow")
                    } footer: {
                        Text("They'll get a notification, and the list shows up with their own lists.")
                    }
                    .listRowBackground(Theme.surface)
                } else {
                    Section {
                        Button("Leave List", role: .destructive) { confirmingLeave = true }
                    } footer: {
                        Text("You'll stop seeing this list. The films you added stay in it.")
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(listName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .bold()
                }
            }
            .alert("Couldn't do that", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Leave \(listName)?", isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button("Leave List", role: .destructive, action: leave)
            }
            .onAppear { social.load() }
        }
    }

    private func memberRow(_ person: ListMember) -> some View {
        HStack(spacing: 12) {
            Avatar(name: person.display_name, size: 34, handle: person.is_me ? nil : person.handle, version: person.avatar_version)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.is_me ? "@\(person.handle) (you)" : "@\(person.handle)")
                    .foregroundColor(Theme.textPrimary)
                Text(person.is_owner ? "Owner · \(person.display_name)" : person.display_name)
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            if busy.contains(person.handle) {
                ProgressView()
            } else if isOwner && !person.is_owner {
                Button("Remove", role: .destructive) { remove(person) }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func invite(_ person: UserSummary) {
        Haptics.tap()
        busy.insert(person.handle)
        APIService.shared.addListEditor(listID: listID, handle: person.handle) { message in
            if let message {
                busy.remove(person.handle)
                errorMessage = message
                return
            }
            Haptics.success()
            sharing.refresh { busy.remove(person.handle) }
        }
    }

    private func remove(_ person: ListMember) {
        busy.insert(person.handle)
        APIService.shared.removeListEditor(listID: listID, handle: person.handle) { ok in
            if !ok {
                busy.remove(person.handle)
                errorMessage = "Couldn't remove @\(person.handle). Check your connection and try again."
                return
            }
            sharing.refresh { busy.remove(person.handle) }
        }
    }

    private func leave() {
        APIService.shared.removeListEditor(listID: listID) { ok in
            guard ok else {
                errorMessage = "Couldn't leave the list. Check your connection and try again."
                return
            }
            Haptics.success()
            dismiss()
            onLeft()
            sharing.refresh()
        }
    }
}
