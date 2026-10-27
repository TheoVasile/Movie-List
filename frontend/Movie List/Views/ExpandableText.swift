//
//  ExpandableText.swift
//  Movie List
//

import SwiftUI

/// Body text clamped to a few lines, with a visible More / Less control
/// that only appears when the text is actually cut short. Tapping the text
/// toggles too.
struct ExpandableText: View {
    let text: String
    var lineLimit: Int = 4

    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.body)
                .foregroundColor(Theme.textSecondary)
                .lineSpacing(4)
                .lineLimit(expanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(truncationProbe)
                .contentShape(Rectangle())
                .onTapGesture { if truncated { toggle() } }
                .accessibilityRemoveTraits(.isButton)
            if truncated {
                Button(expanded ? "Show less" : "More", action: toggle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.accent)
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Show less of the description" : "Show full description")
            }
        }
    }

    private func toggle() {
        Haptics.tap()
        withAnimation(Theme.spring) { expanded.toggle() }
    }

    // Renders the clamped and the full text invisibly at the same width;
    // if the full one is taller, the visible text is being cut off
    private var truncationProbe: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                measured(limit: lineLimit, width: proxy.size.width)
                    .background(GeometryReader { limited in
                        Color.clear.preference(key: LimitedHeightKey.self, value: limited.size.height)
                    })
                measured(limit: nil, width: proxy.size.width)
                    .background(GeometryReader { full in
                        Color.clear.preference(key: FullHeightKey.self, value: full.size.height)
                    })
            }
            .hidden()
            .onPreferenceChange(LimitedHeightKey.self) { limitedHeight = $0; update() }
            .onPreferenceChange(FullHeightKey.self) { fullHeight = $0; update() }
        }
        .accessibilityHidden(true)
    }

    @State private var limitedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private func update() {
        let isTruncated = fullHeight > limitedHeight + 1
        if isTruncated != truncated { truncated = isTruncated }
    }

    private func measured(limit: Int?, width: CGFloat) -> some View {
        Text(text)
            .font(.body)
            .lineSpacing(4)
            .lineLimit(limit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
    }
}

private struct LimitedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct FullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
