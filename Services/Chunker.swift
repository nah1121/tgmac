import Foundation
import CryptoKit
import OSLog

struct ChunkDescriptor: Codable {
    let index: Int
    let sizeBytes: Int64
    let encryptedURL: URL?
    let manifest: [String]
}

struct ChunkManifest: Codable {
    let folderId: UUID
    let generatedAt: Date
    let keyVersion: Int
    let chunks: [ChunkDescriptor]
}

enum ChunkerError: Error {
    case noFiles
    case encryptionFailed
}

final class Chunker {
    private let logger = Logger(subsystem: "com.backupbot.app", category: "Chunker")
    private let keyManager: KeyManager
    
    init(keyManager: KeyManager = .shared) {
        self.keyManager = keyManager
    }
    
    func buildChunks(
        for folder: SyncFolder,
        files: [FileRecord],
        passphrase: String,
        chunkSizeMB: Int,
        dryRun: Bool
    ) throws -> ChunkManifest {
        guard !files.isEmpty else { throw ChunkerError.noFiles }
        
        var chunks: [ChunkDescriptor] = []
        var currentBatch: [FileRecord] = []
        var currentSize: Int64 = 0
        let limit = Int64(chunkSizeMB) * 1024 * 1024
        
        func flush(index: Int) throws {
            guard !currentBatch.isEmpty else { return }
            let manifestList = currentBatch.map { $0.relativePath }
            let encryptedURL = try encryptManifest(
                folderId: folder.id,
                chunkIndex: index,
                manifest: manifestList,
                passphrase: passphrase,
                dryRun: dryRun
            )
            let descriptor = ChunkDescriptor(
                index: index,
                sizeBytes: currentSize,
                encryptedURL: encryptedURL,
                manifest: manifestList
            )
            chunks.append(descriptor)
            currentBatch.removeAll()
            currentSize = 0
        }
        
        var chunkIndex = 0
        for file in files {
            if currentSize + file.sizeBytes > limit && !currentBatch.isEmpty {
                try flush(index: chunkIndex)
                chunkIndex += 1
            }
            currentBatch.append(file)
            currentSize += file.sizeBytes
        }
        try flush(index: chunkIndex)
        
        let manifest = ChunkManifest(
            folderId: folder.id,
            generatedAt: Date(),
            keyVersion: keyManager.currentKeyVersion(),
            chunks: chunks
        )
        logger.info("Built \(chunks.count) chunks for folder \(folder.displayName, privacy: .public)")
        return manifest
    }
    
    private func encryptManifest(
        folderId: UUID,
        chunkIndex: Int,
        manifest: [String],
        passphrase: String,
        dryRun: Bool
    ) throws -> URL? {
        guard !dryRun else { return nil }
        
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-\(folderId.uuidString)-\(chunkIndex).json.enc")
        let json = try JSONEncoder().encode(manifest)
        let key = keyManager.deriveKey(from: passphrase)
        let sealed = try AES.GCM.seal(json, using: key)
        guard let combined = sealed.combined else { throw ChunkerError.encryptionFailed }
        try combined.write(to: url, options: .atomic)
        return url
    }
}
