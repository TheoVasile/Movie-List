//
//  ReportSheet.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-24.
//

import Foundation
import SwiftUI

/// Something the user can report: another user, or something of theirs
struct ReportTarget: Identifiable {
    // What's reported; matches the server's content types
    enum Kind: String {
        case user, list, note, recommendation, activity, group
    }

    let handle: String
    var kind: Kind = .user
    // Which list, note, ... it is, when it isn't the person as a whole
    var contentID: String? = nil

    var id: String { "\(kind.rawValue)-\(handle)-\(contentID ?? "")" }

    /// "@sam", "@sam's list", ...
    var subject: String {
        switch kind {
        case .user: return "@\(handle)"
        case .list: return "@\(handle)'s list"
        case .note: return "@\(handle)'s note"
        case .recommendation: return "@\(handle)'s recommendation"
        case .activity: return "@\(handle)'s activity"
        case .group: return "@\(handle) in this group"
        }
    }
}

/// Why something is reported; the raw values are what the server expects
enum ReportReason: String, CaseIterable, Identifiable {
    case spam, harassment, hate, sexual, violence, impersonation, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spam: return "Spam or scam"
        case .harassment: return "Harassment or bullying"
        case .hate: return "Hate speech"
        case .sexual: return "Sexual content"
        case .violence: return "Violence or threats"
        case .impersonation: return "Pretending to be someone else"
        case .other: return "Something else"
        }
    }
}

/// Reports a user, or something of theirs, with a reason and optional details. Once it's sent, offers to block
/// them too. onBlocked runs after they're blocked, e.g. to close their profile
struct ReportSheet: View {
    let target: ReportTarget
    var onBlocked: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var social = SocialStore.shared
    @State private var reason: ReportReason? = nil
    @State private var details = ""
    @State private var sending = false
    @State private var sent = false
    @State private var blocking = false
    @State private var blocked = false
    @State private var failure: String? = nil

    private static let detailsLimit = 500

    var body: some View {
        NavigationStack {
            Group {
                if sent {
                    thanks
                } else {
                    form
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(sent ? "Report Sent" : "Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .bold()
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if sending {
                            ProgressView()
                        } else {
                            Button("Submit", action: submit)
                                .bold()
                                .disabled(reason == nil)
                        }
                    }
                }
            }
        }
    }

    private var form: some View {
        List {
            Section {
                ForEach(ReportReason.allCases) { option in
                    Button {
                        Haptics.select()
                        reason = option
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            if reason == option {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.accentGradient)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(reason == option ? .isSelected : [])
                }
            } header: {
                Text("Why are you reporting \(target.subject)?")
            }
            .listRowBackground(Theme.surface)

            Section {
                TextField("Add details (optional)", text: $details, axis: .vertical)
                    .lineLimit(3...6)
                    .onChange(of: details) { typed in
                        if typed.count > Self.detailsLimit { details = String(typed.prefix(Self.detailsLimit)) }
                    }
            } footer: {
                if let failure {
                    Text(failure).foregroundColor(Theme.accentSecondary)
                } else {
                    Text("@\(target.handle) isn't told who reported them.")
                }
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
    }

    // Sent, with the offer to block them too
    private var thanks: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Theme.accentGradient)
                    .padding(.top, 30)
                Text("Thanks — we review reports within 24 hours")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("If it breaks our Terms of Service, we'll remove the content and may suspend the account.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                if blocked {
                    Label("@\(target.handle) is blocked", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.top, 10)
                } else {
                    VStack(spacing: 8) {
                        Button(action: block) {
                            if blocking {
                                ProgressView()
                            } else {
                                Label("Block @\(target.handle)", systemImage: "hand.raised")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(blocking)
                        Text("They won't be able to find you, see your profile or lists, follow you or send you films, and you'll both stop following each other. They aren't told.")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        if let failure {
                            Text(failure)
                                .font(.caption)
                                .foregroundColor(Theme.accentSecondary)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(24)
        }
    }

    private func submit() {
        guard let reason else { return }
        sending = true
        failure = nil
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        APIService.shared.report(target.handle, contentType: target.kind.rawValue, contentID: target.contentID,
                                 reason: reason.rawValue, details: trimmed.isEmpty ? nil : trimmed) { saved in
            sending = false
            if saved {
                Haptics.success()
                withAnimation(Theme.spring) { sent = true }
            } else {
                failure = "Couldn't send the report. Check your connection and try again."
            }
        }
    }

    private func block() {
        blocking = true
        failure = nil
        APIService.shared.setBlocked(target.handle, true) { saved in
            blocking = false
            if saved {
                Haptics.success()
                social.load()
                withAnimation(Theme.spring) { blocked = true }
                onBlocked?()
            } else {
                failure = "Couldn't block @\(target.handle). Check your connection and try again."
            }
        }
    }
}
