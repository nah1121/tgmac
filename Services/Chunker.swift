import Foundation
import CryptoKit
import Compression
import OSLog

/// Represents a chunk of encrypted data ready for upload
struct ChunkInfo: Codable, Identifiable {
    let id: UUID
    let index: Int32
    let size: Int64
    let encryptedSize: Int64
    let sha256: String
    let localPath: String
    var uploaded: Bool
    
    init(id: UUID = UUID(), index: Int32, size: Int64, encryptedSize: Int64, sha256: String, localPath: String, uploaded: Bool = false) {
        self.id = id
        self.index = index
        self.size = size
        self.encryptedSize = encryptedSize
        self.sha256 = sha256
        self.localPath = localPath
        self.uploaded = uploaded
    }
}

/// Manifest for tracking chunks belonging to a file or folder
struct ChunkManifest: Codable {
    let id: UUID
    let folderId: UUID
    let folderPath: String
    let createdAt: Date
    var chunks: [ChunkInfo]
    var totalSize: Int64
    var encryptionKeyID: String?
    
    init(folderId: UUID, folderPath: String, totalSize: Int64) {
        self.id = UUID()
        self.folderId = folderId
        self.folderPath = folderPath
        self.createdAt = Date()
        self.chunks = []
        self.totalSize = totalSize
    }
    
    mutating func addChunk(_ chunk: ChunkInfo) {
        chunks.append(chunk)
    }
}

/// Errors that can occur during chunking
enum ChunkerError: LocalizedError {
    case fileNotFound(URL)
    case readError(Error)
    case writeError(Error)
    case encryptionError(Error)
    case hashError
    case manifestError(Error)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .readError(let error):
            return "Failed to read file: \(error.localizedDescription)"
        case .writeError(let error):
            return "Failed to write chunk: \(error.localizedDescription)"
        case .encryptionError(let error):
            return "Encryption failed: \(error.localizedDescription)"
        case .hashError:
            return "Failed to compute hash"
        case .manifestError(let error):
            return "Manifest error: \(error.localizedDescription)"
        }
    }
}

/// Service for creating encrypted chunks from files
class Chunker {
    private let logger = Logger(subsystem: "com.backupbot.app", category: "Chunker")
    private let maxChunkSize: Int64
    private let cacheDirectory: URL
    
    init(maxChunkSize: Int64 = 700 * 1024 * 1024) { // 700 MB default
        self.maxChunkSize = maxChunkSize
        
        // Create dedicated cache directory
        let fm = FileManager.default
        let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cachesDir.appendingPathComponent("BackupBot/Chunks", isDirectory: true)
        
        do {
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create cache directory: \(error.localizedDescription)")
        }
    }
    
    /// Create chunks from all files in a folder
    func createChunks(from folderURL: URL, folderId: UUID, encryptionKey: SymmetricKey) async throws -> ChunkManifest {
        logger.info("Starting chunking for folder: \(folderURL.path)")
        
        var manifest = ChunkManifest(folderId: folderId, folderPath: folderURL.path, totalSize: 0)
        var currentChunkData = Data()
        var currentChunkIndex: Int32 = 0
        var currentFiles: [(path: String, offset: Int64, size: Int64)] = []
        
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw ChunkerError.fileNotFound(folderURL)
        }
        
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                continue
            }
            
            let fileSizeInt64 = Int64(fileSize)
            manifest.totalSize += fileSizeInt64
            
            // Read file data
            guard let fileData = try? Data(contentsOf: fileURL) else {
                logger.warning("Failed to read file: \(fileURL.path)")
                continue
            }
            
            let relativePath = fileURL.path.replacingOccurrences(of: folderURL.path + "/", with: "")
            
            // Process file data in chunks
            var offset: Int64 = 0
            while offset < fileData.count {
                let remaining = fileData.count - offset
                let toRead = min(Int(maxChunkSize) - currentChunkData.count, remaining)
                
                let chunkEnd = offset + toRead
                currentChunkData.append(fileData.subdata(in: offset..<chunkEnd))
                
                currentFiles.append((path: relativePath, offset: offset, size: Int64(toRead)))
                
                offset = chunkEnd
                
                // Write chunk if it's full or we're at the end
                if currentChunkData.count >= Int(maxChunkSize) || (offset >= fileData.count && !currentChunkData.isEmpty) {
                    try await writeChunk(
                        data: currentChunkData,
                        index: currentChunkIndex,
                        manifest: &manifest,
                        encryptionKey: encryptionKey,
                        files: currentFiles
                    )
                    
                    currentChunkData = Data()
                    currentFiles = []
                    currentChunkIndex += 1
                }
            }
        }
        
        // Write any remaining data
        if !currentChunkData.isEmpty {
            try await writeChunk(
                data: currentChunkData,
                index: currentChunkIndex,
                manifest: &manifest,
                encryptionKey: encryptionKey,
                files: currentFiles
            )
        }
        
        logger.info("Created \(manifest.chunks.count) chunks for folder")
        return manifest
    }
    
    private func writeChunk(
        data: Data,
        index: Int32,
        manifest: inout ChunkManifest,
        encryptionKey: SymmetricKey,
        files: [(path: String, offset: Int64, size: Int64)]
    ) async throws {
        let originalSize = Int64(data.count)
        
        // Encrypt the chunk
        let encryptedData = try encrypt(data: data, key: encryptionKey)
        let encryptedSize = Int64(encryptedData.count)
        
        // Compute SHA-256 hash
        let hash = SHA256.hash(data: encryptedData)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        // Write to cache
        let chunkFileName = "chunk_\(index)_\(UUID().uuidString.prefix(8)).enc"
        let chunkURL = cacheDirectory.appendingPathComponent(chunkFileName)
        
        try encryptedData.write(to: chunkURL)
        
        let chunkInfo = ChunkInfo(
            index: index,
            size: originalSize,
            encryptedSize: encryptedSize,
            sha256: hashString,
            localPath: chunkURL.path
        )
        
        manifest.addChunk(chunkInfo)
        
        logger.debug("Wrote chunk \(index): \(originalSize) bytes -> \(encryptedSize) bytes encrypted")
    }
    
    /// Encrypt data using AES-GCM
    private func encrypt(data: Data, key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw ChunkerError.encryptionError(NSError(domain: "Chunker", code: -1, userInfo: [NSLocalizedDescriptionKey: "No combined data"]))
            }
            return combined
        } catch {
            throw ChunkerError.encryptionError(error)
        }
    }
    
    /// Verify a chunk's integrity
    func verifyChunk(at url: URL, expectedHash: String) async throws -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            return false
        }
        
        let hash = SHA256.hash(data: data)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        return hashString == expectedHash
    }
    
    /// Decrypt a chunk
    func decrypt(data: Data, key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw ChunkerError.encryptionError(error)
        }
    }
    
    /// Clean up old chunks from cache
    func cleanupCache(olderThan date: Date) throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.creationDateKey])
        
        for fileURL in contents {
            guard let values = try? fileURL.resourceValues(forKeys: [.creationDateKey]),
                  let creationDate = values.creationDate,
                  creationDate < date else {
                continue
            }
            
            try fm.removeItem(at: fileURL)
            logger.debug("Cleaned up old chunk: \(fileURL.lastPathComponent)")
        }
    }
    
    /// Get cache directory URL
    var cacheURL: URL {
        cacheDirectory
    }
}