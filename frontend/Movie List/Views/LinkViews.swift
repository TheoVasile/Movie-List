//
//  LinkViews.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-28.
//

import Foundation
import SwiftUI
import UIKit

// MARK: - A group's invite link

/// A movie night group's invite link: share it, copy it, or turn it off and make a new one. Anyone holding the link
/// can join the group until it expires (30 days) or is turned off
struct GroupInviteLinkSheet: View {
    let group: MovieGroup
    @Environment(\.dismiss) private var dismiss
    @State private var invite: GroupInvite? = nil
    @State private var isLoading = false
    @State private var failed = false
    @State private var working = false
    @State private var copied = false
    @State private var shareItem: ShareItem? = nil
    @State private var confirmRevoke = false

    private var url: URL? { invite.flatMap { URL(string: $0.url) } }
    private var message: String { "Join \(group.name), my movie night group on Marquee" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "person.2.badge.plus")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Theme.accentGradient)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    Text("Anyone with this link can join \(group.name). It works for 30 days, and anyone in the group can turn it off.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    if isLoading {
                        ProgressView("Making a link…")
                            .tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if failed || url == nil {
                        VStack(spacing: 10) {
                            Text("Couldn't make an invite link.")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Theme.textPrimary)
                            Button("Try Again", action: load)
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else if let url {
                        Text(url.absoluteString)
                            .font(.footnote.monospaced())
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle(cornerRadius: 12)
                            .textSelection(.enabled)

                        Button {
                            Haptics.tap()
                            shareItem = ShareItem(items: [message, url], kind: .groupInvite)
                        } label: {
                            Label("Share Invite Link", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .foregroundColor(Theme.onAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.97))

                        Button {
                            Haptics.tap()
                            UIPasteboard.general.url = url
                            AppAnalytics.log(.inviteSent("group_copy"))
                            withAnimation(Theme.spring) { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false } }
                        } label: {
                            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.headline)
                                .foregroundColor(Theme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .cardStyle(cornerRadius: 14)
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.97))

                        Button(role: .destructive) {
                            confirmRevoke = true
                        } label: {
                            Label("Reset Link", systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .disabled(working)
                        Text("Resetting turns this link off, so nobody new can join with it, and makes a new one.")
                            .font(.caption)
                            .foregroundColor(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Invite to Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if working {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background.opacity(0.5))
                }
            }
            .disabled(working)
            .confirmationDialog("Reset the invite link?", isPresented: $confirmRevoke, titleVisibility: .visible) {
                Button("Turn Off and Make a New Link", role: .destructive, action: reset)
            } message: {
                Text("The current link will stop working for anyone who hasn't joined yet.")
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(item: item)
                    .presentationDetents([.medium, .large])
            }
        }
        .onAppear { if invite == nil { load() } }
    }

    private func load() {
        isLoading = true
        failed = false
        APIService.shared.groupInviteLink(groupID: group.id) { result in
            isLoading = false
            switch result {
            case .success(let made): invite = made
            case .failure: failed = true
            }
        }
    }

    private func reset() {
        guard let invite else { return }
        working = true
        APIService.shared.revokeGroupInvite(groupID: group.id, token: invite.token) { revoked in
            guard revoked else {
                working = false
                failed = true
                return
            }
            APIService.shared.groupInviteLink(groupID: group.id) { result in
                working = false
                switch result {
                case .success(let made): self.invite = made
                case .failure:
                    self.invite = nil
                    failed = true
                }
            }
        }
    }
}

// MARK: - Joining from a link

/// Shown when the user opens a group invite link: what the group is, then Join
struct JoinGroupSheet: View {
    let token: String
    /// Called with the group's id once the user is in it
    let onJoined: (Int64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: GroupInvitePreview? = nil
    @State private var isLoading = true
    @State private var invalid = false
    @State private var loadFailed = false
    @State private var joining = false
    @State private var joinError: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                if isLoading {
                    ProgressView("Loading invite…").tint(Theme.accent)
                } else if invalid {
                    EmptyStateView(icon: "link.badge.plus", title: "This invite doesn't work",
                                   message: "It may have expired or been turned off. Ask for a new link.")
                } else if loadFailed {
                    EmptyStateView(icon: "wifi.slash", title: "Couldn't load the invite", message: "Check your connection and try again.",
                                   actionTitle: "Try Again", action: load)
                } else if let preview {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(Theme.accentGradient)
                    Text("MOVIE NIGHT INVITE")
                        .font(.caption.weight(.heavy))
                        .tracking(1.5)
                        .foregroundStyle(Theme.accentGradient)
                    Text(preview.group_name)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("\(preview.inviter_handle.map { "@\($0) invited you" } ?? "You're invited") · \(preview.member_count) \(preview.member_count == 1 ? "person" : "people") in the group")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    if let joinError {
                        Text(joinError)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Theme.accentSecondary)
                            .multilineTextAlignment(.center)
                    }
                    Button(action: join) {
                        Group {
                            if joining {
                                ProgressView().tint(Theme.onAccent)
                            } else {
                                Text("Join Group")
                            }
                        }
                        .font(.headline)
                        .foregroundColor(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.97))
                    .disabled(joining)
                    .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(preview == nil ? "Close" : "Not Now") {
                        LinkRouter.shared.finishInvite()
                        dismiss()
                    }
                    .disabled(joining)
                }
            }
        }
        .interactiveDismissDisabled(joining)
        .onAppear { if preview == nil { load() } }
    }

    private func load() {
        isLoading = true
        loadFailed = false
        APIService.shared.groupInvitePreview(token: token) { result in
            isLoading = false
            switch result {
            case .success(let loaded): preview = loaded
            case .failure(let error):
                if (error as NSError).code == 404 {
                    invalid = true
                    LinkRouter.shared.finishInvite()
                } else {
                    loadFailed = true
                }
            }
        }
    }

    private func join() {
        Haptics.tap()
        joining = true
        joinError = nil
        APIService.shared.acceptGroupInvite(token: token) { result in
            joining = false
            switch result {
            case .success(let accepted):
                LinkRouter.shared.finishInvite()
                if accepted.joined { AppAnalytics.log(.inviteAccepted) }
                Haptics.success()
                dismiss()
                onJoined(accepted.group_id)
            case .failure(let error):
                let code = (error as NSError).code
                if code == 403 || code == 404 || code == 409 { LinkRouter.shared.finishInvite() }
                joinError = error.serverMessage ?? "Couldn't join. Check your connection and try again."
            }
        }
    }
}

// MARK: - Invite friends

/// "Invite Friends": shares the user's personal invite link (/i/<handle>), which opens their profile in the app
struct InviteFriendsButton: View {
    @ObservedObject private var social = SocialStore.shared
    @State private var shareItem: ShareItem? = nil

    var body: some View {
        if let handle = social.profile?.handle {
            Button {
                Haptics.tap()
                shareItem = ShareItem(items: ["Join me on Marquee and see how our film taste compares", ShareLinks.personalInvite(handle: handle)],
                                      kind: .invite)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "envelope.badge.person.crop")
                        .font(.title3)
                        .foregroundStyle(Theme.accentGradient)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invite Friends")
                            .font(.headline)
                            .foregroundColor(Theme.textPrimary)
                        Text("Send your link to friends who aren't on Marquee yet")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(Theme.textTertiary)
                }
                .padding(14)
                .cardStyle(cornerRadius: 16)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.98))
            .sheet(item: $shareItem) { item in
                ShareSheet(item: item)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

// MARK: - Shared pieces

/// A small capsule button, like Recommend on a film's page
struct CapsuleActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.surface).overlay(Capsule().stroke(Theme.stroke, lineWidth: 1)))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.94))
    }
}

/// Covers the screen while a link is being opened, so nothing can be tapped until it's ready
struct LinkLoadingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(Theme.accent)
                Text("Opening link…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            .padding(24)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
