import AVFoundation
import SwiftUI

struct StandardMirrorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.standardMirrorStatus)
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
                DisplayLayerRepresentable(layer: receiver.displayLayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
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

    func makeNSView(context: Context) -> NSView {
        let view = LayerHostView(displayLayer: layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class LayerHostView: NSView {
        private let displayLayer: AVSampleBufferDisplayLayer

        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(displayLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
