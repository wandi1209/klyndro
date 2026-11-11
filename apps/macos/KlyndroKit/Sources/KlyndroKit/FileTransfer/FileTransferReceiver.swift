import CryptoKit
import Foundation

/// State of an active inbound file transfer.
public actor FileTransferReceiver {
    public static let shared = FileTransferReceiver()

    private var activeOffer: FileOfferBody?
    private var tempFileURL: URL?
    private var fileHandle: FileHandle?
    private var hasher = SHA256()
    private var bytesReceived: Int64 = 0

    private init() {}

    public func handleOffer(_ offer: FileOfferBody) -> Bool {
        // Only accept if no transfer is currently in progress
        guard activeOffer == nil else { return false }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("klyndro-transfer-\(offer.transferId)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: tempURL) else { return false }

        self.activeOffer = offer
        self.tempFileURL = tempURL
        self.fileHandle = handle
        self.hasher = SHA256()
        self.bytesReceived = 0
        return true
    }

    public func handleChunk(_ chunk: FileChunkBody) -> Bool {
        guard let offer = activeOffer, offer.transferId == chunk.transferId,
              let handle = fileHandle,
              let data = Data(base64Encoded: chunk.dataB64) else { return false }

        do {
            try handle.seek(toOffset: UInt64(chunk.offset))
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            bytesReceived += Int64(data.count)
            return true
        } catch {
            return false
        }
    }

    public func handleComplete(_ complete: FileCompleteBody) -> URL? {
        guard let offer = activeOffer, offer.transferId == complete.transferId,
              let handle = fileHandle,
              let tempURL = tempFileURL else {
            cleanup()
            return nil
        }

        try? handle.close()
        fileHandle = nil

        let computedHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard computedHash.lowercased() == offer.sha256.lowercased() else {
            NSLog("[Klyndro] File transfer hash mismatch: expected %@, got %@", offer.sha256, computedHash)
            cleanup()
            return nil
        }

        // Move to ~/Downloads with conflict resolution
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var destURL = downloads.appendingPathComponent(offer.filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: destURL.path) {
            let ext = destURL.pathExtension
            let name = destURL.deletingPathExtension().lastPathComponent
            let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            destURL = downloads.appendingPathComponent(newName)
            counter += 1
        }

        do {
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            NSLog("[Klyndro] File received and saved to: %@", destURL.path)
            cleanup()
            return destURL
        } catch {
            NSLog("[Klyndro] Failed to move received file: %@", error.localizedDescription)
            cleanup()
            return nil
        }
    }

    public func cancel() {
        cleanup()
    }

    private func cleanup() {
        try? fileHandle?.close()
        fileHandle = nil
        if let temp = tempFileURL {
            try? FileManager.default.removeItem(at: temp)
        }
        tempFileURL = nil
        activeOffer = nil
        bytesReceived = 0
    }
}
