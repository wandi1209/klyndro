import AVFoundation
import KlyndroKit
import SwiftUI

struct StandardMirrorView: View {
    @Environment(AppModel.self) private var model
    @State private var typedText = ""
    @State private var showingApps = false
    @State private var showingTypeBar = false
    @State private var appSearch = ""

    private var filteredApps: [StandardAppEntry] {
        let q = appSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.standardApps }
        return model.standardApps.filter {
            $0.label.localizedCaseInsensitiveContains(q) ||
                $0.package.value.localizedCaseInsensitiveContains(q)
        }
    }

    private var videoAspectRatio: CGFloat {
        guard let size = model.standardMirrorReceiver?.videoSize,
              size.width > 0, size.height > 0 else {
            return 9.0 / 20.0
        }
        return size.width / size.height
    }

    private var displayWidth: CGFloat { 340 }
    private var displayHeight: CGFloat {
        (displayWidth / videoAspectRatio).rounded()
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if let receiver = model.standardMirrorReceiver {
                DisplayLayerRepresentable(
                    layer: receiver.displayLayer,
                    videoSize: receiver.videoSize,
                    onGesture: { gesture in
                        Task { await model.sendStandardGesture(gesture) }
                    },
                    onKeyText: { text, mode in
                        Task { await model.sendStandardText(text, mode: mode) }
                    },
                    onAction: { action in
                        Task { await model.sendStandardAction(action) }
                    }
                )
                .frame(width: displayWidth, height: displayHeight)

                bottomDock
            } else {
                ContentUnavailableView(
                    "Standard Mirroring Stopped",
                    systemImage: "iphone.slash",
                    description: Text("Start Standard Mirroring from the main Klyndro window.")
                )
                .frame(width: displayWidth, height: 640)
            }
        }
        .frame(width: displayWidth)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
        .preferredColorScheme(.dark)
        .onDisappear {
            if model.isStandardMirroring {
                Task { await model.stopStandardMirroring(reason: "window_closed") }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.standardMirrorReceiver?.isStreaming == true ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text("Standard Mode")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showingApps.toggle()
                if showingApps && model.standardApps.isEmpty {
                    Task { await model.requestStandardAppList() }
                }
            } label: {
                Label("Apps", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.isConnected)
            .popover(isPresented: $showingApps, arrowEdge: .bottom) {
                appsPopover
            }

            Button(role: .destructive) {
                Task { await model.stopStandardMirroring(reason: "user_stopped") }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.isStandardMirroring)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bottomDock: some View {
        VStack(spacing: 8) {
            if showingTypeBar {
                HStack(spacing: 6) {
                    TextField("Type into focused phone field…", text: $typedText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { submitTypedText() }
                    Button("Send") { submitTypedText() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(typedText.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }

            HStack(spacing: 18) {
                dockButton("Back", systemImage: "chevron.backward") {
                    Task { await model.sendStandardAction(.back) }
                }
                dockButton("Home", systemImage: "circle") {
                    Task { await model.sendStandardAction(.home) }
                }
                dockButton("Recents", systemImage: "square.stack") {
                    Task { await model.sendStandardAction(.recents) }
                }
                dockButton("Notifications", systemImage: "bell.badge") {
                    Task { await model.sendStandardAction(.notifications) }
                }
                dockButton("Lock", systemImage: "lock") {
                    Task { await model.sendStandardAction(.lockScreen) }
                }
                Divider()
                    .frame(height: 14)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showingTypeBar.toggle()
                    }
                } label: {
                    Image(systemName: "keyboard")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showingTypeBar ? Color.accentColor : Color.secondary)
                .help("Toggle text input bar (or click screen and type directly)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func dockButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("\(title) (requires Klyndro Remote Control in Accessibility Settings)")
    }

    private func submitTypedText() {
        let text = typedText
        guard !text.isEmpty else { return }
        typedText = ""
        Task { await model.sendStandardText(text, mode: .append) }
    }

    private var appsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Launch app (No ADB)")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.requestStandardAppList() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isLoadingStandardApps)
            }

            TextField("Search apps…", text: $appSearch)
                .textFieldStyle(.roundedBorder)

            if model.isLoadingStandardApps {
                ProgressView("Loading apps…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if filteredApps.isEmpty {
                Text("No apps loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                List(filteredApps, id: \.package.value) { app in
                    Button {
                        showingApps = false
                        Task { await model.launchStandardApp(app.package) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.label)
                                .font(.body)
                            Text(app.package.value)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 280)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct DisplayLayerRepresentable: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let videoSize: CGSize?
    let onGesture: (InputGestureBody) -> Void
    let onKeyText: (String, InputTextMode) -> Void
    let onAction: (InputActionKind) -> Void

    func makeNSView(context: Context) -> LayerHostView {
        LayerHostView(
            displayLayer: layer,
            videoSize: videoSize,
            onGesture: onGesture,
            onKeyText: onKeyText,
            onAction: onAction
        )
    }

    func updateNSView(_ nsView: LayerHostView, context: Context) {
        nsView.videoSize = videoSize
        nsView.onGesture = onGesture
        nsView.onKeyText = onKeyText
        nsView.onAction = onAction
    }

    final class LayerHostView: NSView {
        private let displayLayer: AVSampleBufferDisplayLayer
        var videoSize: CGSize?
        var onGesture: (InputGestureBody) -> Void
        var onKeyText: (String, InputTextMode) -> Void
        var onAction: (InputActionKind) -> Void

        private var mouseDownPoint: CGPoint?
        private var mouseDownTime: TimeInterval = 0

        init(
            displayLayer: AVSampleBufferDisplayLayer,
            videoSize: CGSize?,
            onGesture: @escaping (InputGestureBody) -> Void,
            onKeyText: @escaping (String, InputTextMode) -> Void,
            onAction: @escaping (InputActionKind) -> Void
        ) {
            self.displayLayer = displayLayer
            self.videoSize = videoSize
            self.onGesture = onGesture
            self.onKeyText = onKeyText
            self.onAction = onAction
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
            window?.makeFirstResponder(self)
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

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 51 { // Delete / Backspace
                onKeyText("", .backspace)
                return
            }
            if event.keyCode == 53 { // Escape -> Back
                onAction(.back)
                return
            }
            guard !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  let chars = event.characters, !chars.isEmpty else {
                super.keyDown(with: event)
                return
            }
            let filtered = chars.filter { !$0.isNewline && ($0.unicodeScalars.first?.value ?? 0) >= 0x20 }
            if !filtered.isEmpty {
                onKeyText(filtered, .append)
            }
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
