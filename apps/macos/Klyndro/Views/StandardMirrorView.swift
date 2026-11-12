import AVFoundation
import KlyndroKit
import SwiftUI

struct StandardMirrorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.standardMirrorReceiver?.statusText ?? model.standardMirrorStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") {
                    Task { await model.stopStandardMirroring(reason: "user_stopped") }
                }
                .disabled(!model.isStandardMirroring)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if let receiver = model.standardMirrorReceiver {
                DisplayLayerRepresentable(
                    layer: receiver.displayLayer,
                    videoSize: receiver.videoSize,
                    onGesture: { gesture in
                        Task { await model.sendStandardGesture(gesture) }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

                Divider()

                HStack(spacing: 12) {
                    Button {
                        Task { await model.sendStandardAction(.back) }
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    Button {
                        Task { await model.sendStandardAction(.home) }
                    } label: {
                        Label("Home", systemImage: "circle")
                    }
                    Button {
                        Task { await model.sendStandardAction(.recents) }
                    } label: {
                        Label("Recents", systemImage: "square.stack")
                    }
                    Button {
                        Task { await model.sendStandardAction(.notifications) }
                    } label: {
                        Label("Shade", systemImage: "bell.badge")
                    }
                    Button {
                        Task { await model.sendStandardAction(.lockScreen) }
                    } label: {
                        Label("Lock", systemImage: "lock")
                    }
                }
                .labelStyle(.iconOnly)
                .controlSize(.regular)
                .padding(.vertical, 8)
                .help("Requires Klyndro Remote Control enabled in Android Accessibility Settings")
            } else {
                ContentUnavailableView(
                    "Standard Mirroring Stopped",
                    systemImage: "iphone.slash",
                    description: Text("Start Standard Mirroring from the main Klyndro window.")
                )
            }
        }
        .frame(minWidth: 380, minHeight: 680)
        .onDisappear {
            if model.isStandardMirroring {
                Task { await model.stopStandardMirroring(reason: "window_closed") }
            }
        }
    }
}

private struct DisplayLayerRepresentable: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let videoSize: CGSize?
    let onGesture: (InputGestureBody) -> Void

    func makeNSView(context: Context) -> LayerHostView {
        LayerHostView(displayLayer: layer, videoSize: videoSize, onGesture: onGesture)
    }

    func updateNSView(_ nsView: LayerHostView, context: Context) {
        nsView.videoSize = videoSize
        nsView.onGesture = onGesture
    }

    final class LayerHostView: NSView {
        private let displayLayer: AVSampleBufferDisplayLayer
        var videoSize: CGSize?
        var onGesture: (InputGestureBody) -> Void

        private var mouseDownPoint: CGPoint?
        private var mouseDownTime: TimeInterval = 0

        init(
            displayLayer: AVSampleBufferDisplayLayer,
            videoSize: CGSize?,
            onGesture: @escaping (InputGestureBody) -> Void
        ) {
            self.displayLayer = displayLayer
            self.videoSize = videoSize
            self.onGesture = onGesture
            super.init(frame: .zero)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(displayLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { true }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            mouseDownPoint = normalizedPoint(point)
            mouseDownTime = event.timestamp
        }

        override func mouseUp(with event: NSEvent) {
            guard let start = mouseDownPoint else { return }
            mouseDownPoint = nil
            let endPoint = convert(event.locationInWindow, from: nil)
            guard let end = normalizedPoint(endPoint) else { return }

            let dx = (end.x - start.x) * bounds.width
            let dy = (end.y - start.y) * bounds.height
            let distance = hypot(dx, dy)
            let elapsedMs = Int(((event.timestamp - mouseDownTime) * 1000.0).rounded())

            if distance < 6.0 {
                if elapsedMs >= 380 {
                    onGesture(InputGestureBody(
                        kind: .longPress,
                        x: start.x,
                        y: start.y,
                        durationMs: min(max(elapsedMs, 400), 2000)
                    ))
                } else {
                    onGesture(InputGestureBody(kind: .tap, x: start.x, y: start.y))
                }
            } else {
                onGesture(InputGestureBody(
                    kind: .swipe,
                    x: start.x,
                    y: start.y,
                    endX: end.x,
                    endY: end.y,
                    durationMs: min(max(elapsedMs, 120), 1500)
                ))
            }
        }

        override func scrollWheel(with event: NSEvent) {
            guard abs(event.scrollingDeltaY) > 2 || abs(event.scrollingDeltaX) > 2 else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard let start = normalizedPoint(point) else { return }

            let dy = max(min(event.scrollingDeltaY / max(bounds.height, 1) * 2.0, 0.35), -0.35)
            let dx = max(min(event.scrollingDeltaX / max(bounds.width, 1) * 2.0, 0.35), -0.35)
            let endX = min(max(start.x + dx, 0.0), 1.0)
            let endY = min(max(start.y + dy, 0.0), 1.0)
            onGesture(InputGestureBody(
                kind: .swipe,
                x: start.x,
                y: start.y,
                endX: endX,
                endY: endY,
                durationMs: 140
            ))
        }

        private func normalizedPoint(_ viewPoint: CGPoint) -> CGPoint? {
            let rect = videoRect()
            guard rect.width > 0, rect.height > 0, rect.contains(viewPoint) else { return nil }
            let nx = (viewPoint.x - rect.minX) / rect.width
            // AppKit origin is bottom-left; Android screen origin is top-left.
            let ny = 1.0 - ((viewPoint.y - rect.minY) / rect.height)
            return CGPoint(
                x: min(max(nx, 0.0), 1.0),
                y: min(max(ny, 0.0), 1.0)
            )
        }

        private func videoRect() -> CGRect {
            guard let videoSize, videoSize.width > 0, videoSize.height > 0,
                  bounds.width > 0, bounds.height > 0 else {
                return bounds
            }
            let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
            let w = videoSize.width * scale
            let h = videoSize.height * scale
            let x = (bounds.width - w) / 2.0
            let y = (bounds.height - h) / 2.0
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }
}
