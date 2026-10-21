//
//  SharedListViews.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-20.
//

import Foundation
import SwiftUI

/// "Shared with Edie" / "Owen's list, shared with you" above a shared list's films, with everyone's faces.
/// Tapping it shows who's on the list
struct SharedListBanner: View {
    let listID: Int64
    let action: () -> Void
    @ObservedObject private var sharing = ListSharing.shared

    private var text: String {
        let others = sharing.others(on: listID)
        if !sharing.isOwner(listID), let owner = others.first(where: \.is_owner) {
            let rest = others.filter { !$0.is_owner }.map(\.display_name)
            return rest.isEmpty ? "\(owner.display_name)'s list, shared with you"
                : "\(owner.display_name)'s list, shared with you and \(Self.names(rest))"
        }
        return "Shared with \(Self.names(others.map(\.display_name)))"
    }

    // "Sam", "Sam and Ana", "Sam, Ana and Lee"
    static func names(_ all: [String]) -> String {
        guard all.count > 1 else { return all.first ?? "" }
        return all.dropLast().joined(separator: ", ") + " and " + (all.last ?? "")
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: -10) {
                    ForEach(sharing.others(on: listID).prefix(4)) { person in
                        Avatar(name: person.display_name, size: 28, handle: person.handle, version: person.avatar_version)
                            .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                    }
                }
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(12)
            .cardStyle(cornerRadius: 16)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
        .accessibilityHint("Shows who can edit this list")
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
                                    Text(person.display_name)
                                        .foregroundColor(Theme.textPrimary)
                                    Text("@\(person.handle)")
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
                Text(person.is_me ? "\(person.display_name) (you)" : person.display_name)
                    .foregroundColor(Theme.textPrimary)
                Text(person.is_owner ? "Owner" : "@\(person.handle)")
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
                errorMessage = "Couldn't remove \(person.display_name). Check your connection and try again."
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
