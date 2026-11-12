import AppKit
import CoreImage.CIFilterBuiltins
import KlyndroKit
import SwiftUI

/// Shows the pairing code and asks the user to confirm it on both devices.
///
/// The digits are compared by a human; nothing about them is transmitted as a secret.
struct PairingSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            if let prompt = model.pairingPrompt {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)

                Text("Pair with \(prompt.peerName)?")
                    .font(.title3.weight(.semibold))

                Text("This code appears on both devices. They match only if nobody is intercepting the connection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                Text(displayDigits(prompt.code))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .padding(.vertical, 6)
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    Button("Cancel", role: .cancel) {
                        Task { await model.cancelPairing() }
                    }
                    Button("Codes Match") {
                        Task { await model.confirmPairing() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if let failure = model.pairingFailure {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                Text("Pairing failed")
                    .font(.title3.weight(.semibold))
                Text(reason(failure))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Close") {
                    model.dismissPairingSheet()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Text("Scan to pair")
                    .font(.title3.weight(.semibold))

                if let payload = model.pairingQRPayload,
                   let uri = payload.encodeURI(),
                   let qr = qrImage(for: uri) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text("\(payload.host):\(payload.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                ProgressView("Waiting for a device…")
                    .frame(maxWidth: 320)
                Text("Open Klyndro on Android and tap Scan QR code (or pick this Mac under Devices). Window stays open for 60 seconds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel") {
                    Task { await model.cancelPairing() }
                }
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    /// `123456` becomes `123 456`, which is easier to compare aloud without transposing digits.
    private func displayDigits(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let split = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<split]) \(code[split...])"
    }

    private func reason(_ failure: PairingFailure) -> String {
        switch failure {
        case .userRejected: return "The code was rejected on one of the devices."
        case .sasMismatch: return "The two devices computed different codes. Do not trust this connection."
        case .windowClosed: return "The 60-second pairing window closed."
        case .rateLimited: return "Too many attempts. Try again in a minute."
        case .alreadyPaired: return "These devices are already paired."
        case .internalError: return "An internal error stopped pairing. Check Diagnostics."
        }
    }

    private func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
