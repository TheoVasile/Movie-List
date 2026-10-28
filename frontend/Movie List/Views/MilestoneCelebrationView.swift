//
//  MilestoneCelebrationView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-28.
//

import SwiftUI
import UIKit

/// Shows a milestone's celebration over everything, sheets included, in a window of its own that goes away once
/// it's dismissed. It plays for a few seconds and doesn't stop anything underneath from carrying on
enum MilestoneCelebration {
    private static var window: UIWindow?

    static func present(_ milestone: Milestone) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }
        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear
        // Same appearance as the app (light, dark or the pink palette)
        overlay.overrideUserInterfaceStyle = scene.windows.first(where: \.isKeyWindow)?.overrideUserInterfaceStyle ?? .unspecified
        let host = UIHostingController(rootView: MilestoneCelebrationView(milestone: milestone, onDismiss: dismiss))
        host.view.backgroundColor = .clear
        overlay.rootViewController = host
        overlay.isHidden = false
        window = overlay
        Haptics.success()
        // VoiceOver reads it out as it appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIAccessibility.post(notification: .announcement, argument: "Milestone reached. \(milestone.line)")
        }
    }

    static func dismiss() {
        window?.isHidden = true
        window = nil
    }
}

struct MilestoneCelebrationView: View {
    let milestone: Milestone
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var shown = false
    @State private var started = Date()
    @State private var shareItem: ShareItem? = nil
    // Stays up while the share sheet is open, then closes on its own a moment later
    @State private var autoDismiss: DispatchWorkItem? = nil

    private static let visibleFor: TimeInterval = 3.5

    var body: some View {
        ZStack {
            Theme.scrim.opacity(shown ? 0.6 : 0)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            if !reduceMotion {
                Confetti(started: started)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            card
                .scaleEffect(shown || reduceMotion ? 1 : 0.85)
                .opacity(shown ? 1 : 0)
        }
        .contentShape(Rectangle())
        // Tap anywhere to dismiss
        .onTapGesture(perform: close)
        .onAppear {
            started = Date()
            withAnimation(reduceMotion ? .easeOut(duration: 0.25) : Theme.spring) { shown = true }
            scheduleDismiss()
        }
        .sheet(item: $shareItem, onDismiss: scheduleDismiss) { item in
            ShareSheet(item: item)
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            MarqueeLights(animated: !reduceMotion)
            Text("MILESTONE")
                .font(.caption.weight(.heavy))
                .tracking(3)
                .foregroundColor(Theme.textSecondary)
            Text(milestone.number)
                .font(.system(size: 72, weight: .black, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(Theme.accentGradient)
            Text(milestone.count == 1 ? "film in your lists" : "films in your lists")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
            Text(milestone.line)
                .font(.title3.weight(.bold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: share) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundColor(Theme.onAccent)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Theme.accentGradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            MarqueeLights(animated: !reduceMotion, offset: 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 320)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.accent.opacity(0.5), lineWidth: 1.5))
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.surfaceRaised, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .accessibilityLabel("Close")
        }
        .shadow(color: Theme.shadow.opacity(0.5), radius: 30, y: 12)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func scheduleDismiss() {
        autoDismiss?.cancel()
        let work = DispatchWorkItem { close() }
        autoDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
    }

    private func close() {
        autoDismiss?.cancel()
        withAnimation(.easeIn(duration: 0.2)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onDismiss() }
    }

    private func share() {
        Haptics.tap()
        autoDismiss?.cancel()
        AppAnalytics.log(.milestoneShared(milestone.id))
        // Their profile link, or their invite link when their profile is private, as with Stats and Year in Review
        let link = ShareLinks.myLink
        let card = MilestoneShareCard(milestone: milestone, shareURL: link)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        if let image = renderer.uiImage {
            shareItem = ShareItem(items: [image] + (link.map { [$0] } ?? []), kind: .milestone)
        }
    }
}

/// A row of marquee bulbs that light up in turn, or stay lit when motion is reduced
private struct MarqueeLights: View {
    let animated: Bool
    var offset = 0
    private let count = 11

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.18)) { context in
            let step = animated ? Int(context.date.timeIntervalSinceReferenceDate / 0.18) : 0
            HStack(spacing: 9) {
                ForEach(0..<count, id: \.self) { index in
                    let lit = !animated || (index + step + offset) % 3 == 0
                    Circle()
                        .fill(lit ? Theme.accent : Theme.accent.opacity(0.25))
                        .frame(width: 7, height: 7)
                        .shadow(color: lit ? Theme.accent.opacity(0.8) : .clear, radius: 4)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A burst of confetti from the top of the screen that falls away in about two and a half seconds
private struct Confetti: View {
    let started: Date

    private struct Piece {
        let x: CGFloat, drift: CGFloat, delay: Double, speed: CGFloat, spin: Double, size: CGFloat, colour: Int, round: Bool
    }

    private static let duration: Double = 2.6
    private let pieces: [Piece] = (0..<70).map { _ in
        Piece(x: .random(in: 0...1), drift: .random(in: -80...80), delay: .random(in: 0...0.5),
              speed: .random(in: 0.8...1.3), spin: .random(in: -8...8), size: .random(in: 6...11),
              colour: .random(in: 0..<4), round: .random())
    }

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                let elapsed = context.date.timeIntervalSince(started)
                let colours = [Theme.accent, Theme.accentSecondary, Color.white, Theme.accent.opacity(0.7)]
                for piece in pieces {
                    let t = elapsed - piece.delay
                    guard t > 0, t < Self.duration else { continue }
                    let progress = t / Self.duration
                    // Falls faster as it goes, fading out at the end
                    let y = -20 + CGFloat(progress * progress) * (size.height + 40) * piece.speed
                    let x = piece.x * size.width + piece.drift * CGFloat(progress)
                    var context = canvas
                    context.opacity = progress > 0.75 ? (1 - progress) / 0.25 : 1
                    context.translateBy(x: x, y: y)
                    context.rotate(by: .radians(piece.spin * t))
                    let rect = CGRect(x: -piece.size / 2, y: -piece.size / 4, width: piece.size, height: piece.round ? piece.size : piece.size / 2)
                    let path = piece.round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.5)
                    context.fill(path, with: .color(colours[piece.colour]))
                }
            }
        }
    }
}

/// The image shared from a celebration: the number, its line and Marquee's name. When there is a shareURL (the
/// user's link, sent alongside the image), the "@handle · domain" footer is printed at the bottom so people can find them
struct MilestoneShareCard: View {
    let milestone: Milestone
    var shareURL: URL? = nil

    var body: some View {
        VStack(spacing: 16) {
            MarqueeLights(animated: false)
            Spacer(minLength: 0)
            Text("MILESTONE")
                .font(.caption.weight(.heavy))
                .tracking(3)
                .foregroundColor(Theme.textSecondary)
            Text(milestone.number)
                .font(.system(size: 96, weight: .black, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(Theme.accentGradient)
            Text("films in my lists")
                .font(.headline)
                .foregroundColor(Theme.textSecondary)
            Text(milestone.line)
                .font(.title2.weight(.bold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Text("MARQUEE")
                    .font(.footnote.weight(.heavy))
                    .tracking(4)
                    .foregroundStyle(Theme.accentGradient)
                if shareURL != nil {
                    ShareCardFooter()
                }
            }
            MarqueeLights(animated: false)
        }
        .padding(28)
        .frame(width: 390, height: 390)
        .background(Theme.background)
    }
}

struct MilestoneCelebrationView_Previews: PreviewProvider {
    static var previews: some View {
        MilestoneCelebrationView(milestone: .films100, onDismiss: {})
        MilestoneShareCard(milestone: .films1000)
    }
}
