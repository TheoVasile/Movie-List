//
//  TermsOfServiceView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-23.
//

import Foundation
import SwiftUI

// MARK: - Rendering the terms

/// Draws the terms' Markdown: #, ## and ### headings, paragraphs and "- " bullets, with bold, italics and
/// links inside them. The server's document uses nothing else
struct TermsText: View {
    let markdown: String
    // The screens around it already say "Terms of Service", so the document's own title can be left out
    var skipsTitle = false

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
    }

    /// Splits the document into blocks. Lines next to each other make one paragraph, as in Markdown
    private var blocks: [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                endParagraph()
            } else if let level = ["### ", "## ", "# "].firstIndex(where: { line.hasPrefix($0) }) {
                endParagraph()
                blocks.append(.heading(level: 3 - level, text: String(line.dropFirst(4 - level))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                endParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        endParagraph()
        if skipsTitle, case .heading(level: 1, _)? = blocks.first { blocks.removeFirst() }
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text))
                        .font(level == 1 ? .title2.weight(.heavy) : level == 2 ? .title3.weight(.bold) : .headline)
                        .foregroundColor(Theme.textPrimary)
                        .padding(.top, level == 3 ? 4 : 10)
                case .paragraph(let text):
                    Text(inline(text))
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(Theme.accentGradient)
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Text(inline(text))
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
        .textSelection(.enabled)
    }

    /// Bold, italics and links within a line; the line as typed if it isn't valid Markdown
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Shown in place of the terms while they load, or when they couldn't be
private struct TermsStatusView: View {
    let failed: Bool
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if failed {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                Text("Couldn't load the Terms of Service")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Text("Check your connection and try again.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                Button("Try Again", action: retry)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 200)
                    .padding(.top, 4)
            } else {
                ProgressView()
                    .tint(Theme.accent)
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

// MARK: - Reading the terms

/// The Terms of Service, read-only. Pushed from Settings, or shown as a sheet (with its own Done button)
/// from sign-up
struct TermsOfServiceView: View {
    var isSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var terms: TermsDocument? = nil
    @State private var loadFailed = false

    var body: some View {
        if isSheet {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                                .bold()
                        }
                    }
            }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            if let terms {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Last updated \(terms.updated)")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Theme.textTertiary)
                    TermsText(markdown: terms.markdown, skipsTitle: true)
                }
                .padding(20)
            } else {
                TermsStatusView(failed: loadFailed, retry: load)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Terms of Service")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if terms == nil { load() } }
    }

    private func load() {
        loadFailed = false
        APIService.shared.fetchTerms { result in
            switch result {
            case .success(let loaded): terms = loaded
            case .failure: loadFailed = true
            }
        }
    }
}

/// "By continuing, you agree to CineList's Terms of Service." under the sign-in and sign-up buttons, where
/// "Terms of Service" opens them in a sheet
struct TermsNotice: View {
    var action = "continuing"
    @State private var showTerms = false

    var body: some View {
        Text(notice)
            .font(.caption)
            .foregroundColor(Theme.textTertiary)
            .tint(Theme.accent)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            // The link only opens the sheet
            .environment(\.openURL, OpenURLAction { _ in
                showTerms = true
                return .handled
            })
            .sheet(isPresented: $showTerms) {
                TermsOfServiceView(isSheet: true)
            }
    }

    private var notice: AttributedString {
        var notice = AttributedString("By \(action), you agree to CineList's ")
        var link = AttributedString("Terms of Service")
        link.link = URL(string: "cinelist://terms")
        link.font = .caption.weight(.semibold)
        notice.append(link)
        notice.append(AttributedString("."))
        return notice
    }
}

// MARK: - Agreeing to the terms

/// Covers the app until the user agrees to the current Terms of Service: when they first sign in, and again
/// whenever the terms change. It can't be swiped away; declining signs them out
struct TermsAcceptanceView: View {
    let onDecline: () -> Void
    @ObservedObject private var social = SocialStore.shared
    @State private var terms: TermsDocument? = nil
    @State private var loadFailed = false
    @State private var isAccepting = false
    @State private var confirmDecline = false
    @State private var errorMessage: String? = nil

    // They agreed to an earlier version, so this is a change rather than their first time
    private var isUpdate: Bool { social.profile?.terms_version != nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isUpdate {
                        Label("We've updated our Terms of Service", systemImage: "doc.badge.clock")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.accent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Terms of Service")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .foregroundColor(Theme.textPrimary)
                        Text(terms.map { "Last updated \($0.updated)" }
                             ?? (isUpdate ? "Please review the changes to keep using CineList." : "Please review them to start using CineList."))
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                    }
                    if let terms {
                        TermsText(markdown: terms.markdown, skipsTitle: true)
                    } else {
                        TermsStatusView(failed: loadFailed, retry: load)
                    }
                }
                .padding(24)
            }

            // Agree or decline, always in reach below the terms
            VStack(spacing: 10) {
                Button(action: accept) {
                    if isAccepting {
                        ProgressView().tint(Theme.onAccent)
                    } else {
                        Text("I Agree")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(terms == nil || isAccepting)
                .opacity(terms == nil ? 0.5 : 1)
                Button("Decline") {
                    Haptics.tap()
                    confirmDecline = true
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
                .disabled(isAccepting)
                .padding(.vertical, 6)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background(Theme.surface.ignoresSafeArea(edges: .bottom))
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .top)
        }
        .background(Theme.background.ignoresSafeArea())
        .interactiveDismissDisabled()
        .onAppear { if terms == nil { load() } }
        .confirmationDialog("Decline the Terms of Service?", isPresented: $confirmDecline, titleVisibility: .visible) {
            Button("Decline and Sign Out", role: .destructive, action: onDecline)
        } message: {
            Text("You can't use CineList without agreeing to them, so you'll be signed out.")
        }
        .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() {
        loadFailed = false
        APIService.shared.fetchTerms { result in
            switch result {
            case .success(let loaded): terms = loaded
            case .failure: loadFailed = true
            }
        }
    }

    /// Agrees to the version on screen, then reloads the profile, which closes this screen
    private func accept() {
        guard let version = terms?.version else { return }
        Haptics.tap()
        isAccepting = true
        APIService.shared.acceptTerms(version: version) { result in
            switch result {
            case .success:
                Haptics.success()
                social.reloadProfile { isAccepting = false }
            case .failure(let error):
                isAccepting = false
                if (error as NSError).code == 400 {
                    // The terms changed while they were reading, so show the newest ones to agree to
                    errorMessage = "The Terms of Service were just updated. Please review the latest version."
                    terms = nil
                    load()
                    social.reloadProfile()
                } else {
                    errorMessage = "Check your connection and try again."
                }
            }
        }
    }
}

struct TermsOfServiceView_Previews: PreviewProvider {
    static var previews: some View {
        TermsAcceptanceView(onDecline: {})
    }
}
