//
//  AvatarCropView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-22.
//

import Foundation
import SwiftUI

/// A photo waiting to be cropped, for presenting the crop screen with `fullScreenCover(item:)`
struct CroppablePhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// "Move and Scale", like Photos: the user drags and pinches the photo under a circle, and the square around the
/// circle becomes their profile picture. Double tap zooms in or back out
struct AvatarCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onChoose: (UIImage) -> Void

    // Zoom and offset (in points) once a gesture ends, and while it's under way
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let maxZoom: CGFloat = 6
    // The cropped picture's size in pixels; the upload shrinks it further
    private static let outputSide: CGFloat = 768

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) - 32
            let scale = baseScale(side) * liveZoom
            let shown = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let liveOffset = clamped(CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
                                     shown: shown, side: side)
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(liveOffset)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                mask(side: side, in: proxy.size)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset = clamped(CGSize(width: offset.width + value.translation.width,
                                                height: offset.height + value.translation.height),
                                         shown: shown, side: side)
                    }
                    .simultaneously(with: MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in
                            withAnimation(Theme.spring) {
                                zoom = min(max(zoom * value, 1), Self.maxZoom)
                                offset = clamped(offset, shown: size(side: side, zoom: zoom), side: side)
                            }
                        })
            )
            .onTapGesture(count: 2) {
                Haptics.tap()
                withAnimation(Theme.spring) {
                    zoom = zoom > 1 ? 1 : 2.5
                    offset = clamped(offset, shown: size(side: side, zoom: zoom), side: side)
                }
            }
            .overlay(alignment: .top) {
                Text("Move and Scale")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.top, 16)
            }
            .overlay(alignment: .bottom) {
                HStack {
                    Button("Cancel", action: onCancel)
                    Spacer()
                    Button("Choose") {
                        Haptics.success()
                        onChoose(cropped(side: side))
                    }
                    .bold()
                }
                .font(.body)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
        .statusBarHidden()
    }

    private var liveZoom: CGFloat {
        min(max(zoom * pinch, 1), Self.maxZoom)
    }

    // At zoom 1 the photo's shorter side just fills the circle
    private func baseScale(_ side: CGFloat) -> CGFloat {
        side / max(min(image.size.width, image.size.height), 1)
    }

    private func size(side: CGFloat, zoom: CGFloat) -> CGSize {
        let scale = baseScale(side) * zoom
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    // Keeps the photo covering the whole circle
    private func clamped(_ offset: CGSize, shown: CGSize, side: CGFloat) -> CGSize {
        let maxX = max((shown.width - side) / 2, 0), maxY = max((shown.height - side) / 2, 0)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    // Dims everything outside the circle
    private func mask(side: CGFloat, in size: CGSize) -> some View {
        let circle = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        return ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addEllipse(in: circle)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            Circle()
                .stroke(Color.white.opacity(0.7), lineWidth: 1)
                .frame(width: side, height: side)
        }
        .frame(width: size.width, height: size.height)
    }

    // The square around the circle, from the photo at full resolution
    private func cropped(side: CGFloat) -> UIImage {
        let shown = size(side: side, zoom: zoom)
        let scale = baseScale(side) * zoom
        // The circle's top left corner in the photo's own points
        let origin = CGPoint(x: (shown.width / 2 - offset.width - side / 2) / scale,
                             y: (shown.height / 2 - offset.height - side / 2) / scale)
        let cropSide = side / scale
        let output = min(Self.outputSide, cropSide * image.scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format).image { _ in
            let ratio = output / cropSide
            image.draw(in: CGRect(x: -origin.x * ratio, y: -origin.y * ratio,
                                  width: image.size.width * ratio, height: image.size.height * ratio))
        }
    }
}
