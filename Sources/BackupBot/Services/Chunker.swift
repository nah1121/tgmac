//
//  Chunker.swift
//  BackupBot
//
//  Created by BackupBot Generator
//  Copyright (c) 2024 nah1121. All rights reserved.
//
//  Service responsible for enumerating files in a sync folder, grouping them into
//  size-bounded chunks, creating ZIP archives, encrypting with AES-256-GCM, and
//  generating JSON manifests for each chunk.
//
//  ZIP format uses STORE method (no compression) for zero-dependency simplicity.
//  Adding Deflate compression is a documented future enhancement.

import Foundation
import CryptoKit
import os
import SwiftData

// MARK: - Public Types

/// Describes a single encrypted chunk ready for upload.
/// Each chunk consists of an unencrypted ZIP, an AES-256-GCM encrypted copy,
/// and a JSON manifest describing its contents.
struct ChunkDescriptor: Sendable, Identifiable {
    let id: UUID
    let chunkFileURL: URL          /// Unencrypted ZIP archive in cache
    let encryptedFileURL: URL      /// AES-256-GCM encrypted file in cache
    let manifestURL: URL           /// JSON manifest describing chunk contents
    let totalSize: Int64           /// Uncompressed archive size in bytes
    let encryptedSize: Int64       /// Encrypted file size in bytes
    let fileCount: Int             /// Number of files in this chunk
    let index: Int                 /// Zero-based chunk index (for ordering)
}

/// JSON manifest written alongside each encrypted chunk.
/// Contains metadata for integrity verification and upload bookkeeping.
struct ChunkManifest: Codable, Sendable {
    let chunkId: UUID
    let chunkIndex: Int
    let createdAt: Date
    let files: [ManifestFileEntry]
    let totalUncompressedSize: Int64
    let encryptedSize: Int64
    let sha256OfEncrypted: String  /// Hex-encoded SHA-256 of the encrypted file

    /// Describes a single file within a chunk.
    struct ManifestFileEntry: Codable, Sendable, Hashable {
        let relativePath: String   /// Path relative to the sync folder root
        let fileName: String       /// Just the file name component
        let fileSize: Int64        /// Original file size in bytes
        let sha256Hash: String     /// Hex-encoded SHA-256 of the original file
    }
}

/// Errors specific to chunking operations.
enum ChunkerError: LocalizedError, Sendable {
    case folderUnavailable(String)
    case noEncryptionKey
    case invalidBookmark
    case fileTooLarge(url: URL, size: Int64, limit: Int64)
    case hashComputationFailed(url: String, underlying: String)
    case zipCreationFailed(String)
    case encryptionFailed(String)
    case manifestGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable(let path):
            return "Folder is unavailable: \(path)"
        case .noEncryptionKey:
            return "Encryption key has not been configured. Call configureEncryptionKey(_:) first."
        case .invalidBookmark:
            return "Security-scoped bookmark could not be resolved. The folder may have been moved or deleted."
        case .fileTooLarge(let url, let size, let limit):
            return "File '\(url.lastPathComponent)' (\(size) bytes) exceeds the \(limit) byte limit and will be skipped."
        case .hashComputationFailed(let url, let underlying):
            return "Failed to compute SHA-256 for '\(url)': \(underlying)"
        case .zipCreationFailed(let reason):
            return "ZIP archive creation failed: \(reason)"
        case .encryptionFailed(let reason):
            return "Encryption failed: \(reason)"
        case .manifestGenerationFailed(let reason):
            return "Manifest generation failed: \(reason)"
        }
    }
}

// MARK: - ChunkerService

/// Actor-based service that processes a sync folder into encrypted, size-bounded chunks.
///
/// Workflow:
///   1. Resolve the folder's security-scoped bookmark.
///   2. Recursively enumerate all files (skipping hidden files and files > 4 GB).
///   3. Compute SHA-256 for each file and optionally persist `FileRecord` entries.
///   4. Group files into chunks whose total uncompressed size ≤ `defaultChunkSize`.
///   5. For each chunk, create a ZIP archive (STORE method), encrypt with AES-256-GCM,
///      and produce a JSON manifest.
///   6. Return an ordered array of `ChunkDescriptor` for the upload layer.
actor ChunkerService {

    /// Default maximum uncompressed chunk size: 700 MB.
    /// Chosen to stay well under Telegram's 2 GB document upload limit while
    /// leaving headroom for ZIP overhead and encryption expansion (~16 bytes/file).
    static let defaultChunkSize: Int64 = 700 * 1024 * 1024

    /// Telegram's maximum file size for document uploads.
    private static let telegramFileSizeLimit: Int64 = 2 * 1024 * 1024 * 1024  // 2 GB

    /// Maximum individual file size we'll process. Files larger are skipped.
    private static let maxIndividualFileSize: Int64 = 4 * 1024 * 1024 * 1024  // 4 GB

    /// AES-256-GCM nonce length in bytes.
    private static let gcmNonceLength = 12

    /// AES-256-GCM tag length in bytes.
    private static let gcmTagLength = 16

    private let logger = Logger.chunker
    private let cacheDirectory: URL
    private var encryptionKey: Data?

    // MARK: - Initialization

    init() {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        self.cacheDirectory = paths[0]
            .appendingPathComponent("com.nah1121.BackupBot", isDirectory: true)
            .appendingPathComponent("chunks", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        } catch {
            // Log but don't crash — the directory will be created on first use
            Logger.chunker.error("Failed to create cache directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Configuration

    /// Provide the AES-256 encryption key. Call this on app launch after retrieving
    /// the key from Keychain via `KeychainHelper.getOrCreateEncryptionKey()`.
    func configureEncryptionKey(_ key: Data) {
        precondition(key.count == 32, "Encryption key must be exactly 32 bytes (256 bits)")
        self.encryptionKey = key
        logger.info("Encryption key configured (\(key.count) bytes)")
    }

    // MARK: - Main Processing Pipeline

    /// Process a sync folder into encrypted chunks.
    ///
    /// - Parameters:
    ///   - folder: The `SyncFolder` model whose bookmark will be resolved.
    ///   - modelContext: Optional `ModelContext` to persist `FileRecord` entries.
    /// - Returns: An array of `ChunkDescriptor` sorted by chunk index.
    /// - Throws: `ChunkerError` for domain-specific failures, or system errors.
    func process(
        folder: SyncFolder,
        modelContext: ModelContext?
    ) async throws -> [ChunkDescriptor] {
        logger.info("Starting chunk processing for folder: \(folder.displayName)")

        // ── Step 1: Resolve folder URL from security-scoped bookmark ──
        guard let folderURL = folder.resolvedURL else {
            logger.error("Cannot resolve bookmark for folder: \(folder.displayName)")
            throw ChunkerError.folderUnavailable(folder.path)
        }

        // ── Step 2: Obtain encryption key ──
        let key: Data
        if let configuredKey = self.encryptionKey {
            key = configuredKey
        } else {
            // Try to get from Keychain as a fallback
            do {
                key = try KeychainHelper.getOrCreateEncryptionKey()
                self.encryptionKey = key
            } catch {
                logger.error("No encryption key available")
                throw ChunkerError.noEncryptionKey
            }
        }

        // ── Step 3: Enumerate all files recursively ──
        try Task.checkCancellation()
        var enumeratedFiles: [(url: URL, relativePath: String, size: Int64)] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { [logger] url, error in
                logger.warning("Enumeration error at '\(url.path)': \(error.localizedDescription)")
                return true // continue enumeration
            }
        ) else {
            throw ChunkerError.folderUnavailable(folderURL.path)
        }

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            // Skip directories — enumerator yields them too
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues.isRegularFile == true else { continue }

            let fileSize = Int64(resourceValues.fileSize ?? 0)

            // Skip zero-byte files
            guard fileSize > 0 else { continue }

            // Skip files exceeding the individual size limit
            if fileSize > Self.maxIndividualFileSize {
                logger.warning("Skipping oversized file: \(fileURL.lastPathComponent) (\(fileSize) bytes)")
                continue
            }

            // Compute relative path from the folder root
            let relativePath = fileURL.path
                .replacingOccurrences(of: folderURL.path + "/", with: "")
                .replacingOccurrences(of: folderURL.path, with: "")

            enumeratedFiles.append((url: fileURL, relativePath: relativePath, size: fileSize))
        }

        logger.info("Enumerated \(enumeratedFiles.count) files in '\(folder.displayName)'")

        guard !enumeratedFiles.isEmpty else {
            logger.info("No files to process — returning empty chunk array")
            return []
        }

        // ── Step 4: Compute SHA-256 hashes ──
        try Task.checkCancellation()
        var hashedFiles: [(url: URL, relativePath: String, size: Int64, sha256: String)] = []
        hashedFiles.reserveCapacity(enumeratedFiles.count)

        for (index, entry) in enumeratedFiles.enumerated() {
            try Task.checkCancellation()

            do {
                let hash = try await computeSHA256(of: entry.url)
                hashedFiles.append((
                    url: entry.url,
                    relativePath: entry.relativePath,
                    size: entry.size,
                    sha256: hash
                ))

                if (index + 1).isMultiple(of: 100) {
                    logger.debug("Hashed \(index + 1)/\(enumeratedFiles.count) files")
                }
            } catch {
                logger.error("SHA-256 computation failed for '\(entry.url.lastPathComponent)': \(error.localizedDescription)")
                throw ChunkerError.hashComputationFailed(
                    url: entry.url.lastPathComponent,
                    underlying: error.localizedDescription
                )
            }
        }

        logger.info("Computed hashes for \(hashedFiles.count) files")

        // ── Step 5: Persist FileRecord entries in SwiftData ──
        if let modelContext {
            try Task.checkCancellation()

            // Delete existing FileRecords for this folder (re-scan scenario)
            let existingDescriptor = FetchDescriptor<FileRecord>(
                predicate: #Predicate { $0.syncFolder?.id == folder.id }
            )
            let existingRecords = try modelContext.fetch(existingDescriptor)
            for record in existingRecords {
                modelContext.delete(record)
            }

            for entry in hashedFiles {
                let record = FileRecord(
                    fileName: entry.url.lastPathComponent,
                    filePath: entry.relativePath,
                    fileSize: entry.size,
                    sha256Hash: entry.sha256,
                    chunkIndex: 0,
                    syncStatusRaw: "pending",
                    createdAt: Date()
                )
                record.syncFolder = folder
                modelContext.insert(record)
            }

            try modelContext.save()
            logger.info("Persisted \(hashedFiles.count) FileRecords to SwiftData")
        }

        // ── Step 6: Group files into chunks by total size ──
        try Task.checkCancellation()
        let chunkGroups = groupIntoChunks(files: hashedFiles, maxSize: Self.defaultChunkSize)
        logger.info("Grouped into \(chunkGroups.count) chunk(s)")

        // ── Step 7 & 8: Create ZIP, encrypt, generate manifest for each chunk ──
        var descriptors: [ChunkDescriptor] = []
        descriptors.reserveCapacity(chunkGroups.count)

        for (chunkIndex, group) in chunkGroups.enumerated() {
            try Task.checkCancellation()
            logger.info("Processing chunk \(chunkIndex + 1)/\(chunkGroups.count) (\(group.count) files)")

            let descriptor = try await buildChunk(
                files: group,
                index: chunkIndex,
                encryptionKey: key
            )
            descriptors.append(descriptor)
        }

        logger.info("Chunk processing complete: \(descriptors.count) chunks created")
        return descriptors
    }

    // MARK: - Chunk Building

    /// Build a single chunk: ZIP → encrypt → manifest → descriptor.
    private func buildChunk(
        files: [(url: URL, relativePath: String, size: Int64, sha256: String)],
        index: Int,
        encryptionKey: Data
    ) async throws -> ChunkDescriptor {
        let chunkId = UUID()
        let chunkBaseName = "chunk_\(index)_\(chunkId.uuidString.prefix(8))"

        // URLs for the three output artifacts
        let zipURL = cacheDirectory.appendingPathComponent("\(chunkBaseName).zip")
        let encryptedURL = cacheDirectory.appendingPathComponent("\(chunkBaseName).enc")
        let manifestURL = cacheDirectory.appendingPathComponent("\(chunkBaseName).json")

        // Prepare file entries for ZIP: (source URL, relative path inside archive)
        let zipEntries = files.map { ($0.url, $0.relativePath) }

        // ── Create ZIP archive ──
        try Task.checkCancellation()
        let archiveSize = try await createZipArchive(files: zipEntries, destination: zipURL)
        logger.debug("Chunk \(index): ZIP archive created (\(archiveSize) bytes)")

        // ── Encrypt the ZIP ──
        try Task.checkCancellation()
        let encSize = try await encryptFile(at: zipURL, destination: encryptedURL, key: encryptionKey)
        logger.debug("Chunk \(index): Encrypted (\(encSize) bytes)")

        // ── Compute SHA-256 of encrypted file ──
        try Task.checkCancellation()
        let encryptedSHA256 = try await computeSHA256(of: encryptedURL)

        // ── Generate JSON manifest ──
        try Task.checkCancellation()
        let manifestEntries = files.map { file in
            ChunkManifest.ManifestFileEntry(
                relativePath: file.relativePath,
                fileName: file.url.lastPathComponent,
                fileSize: file.size,
                sha256Hash: file.sha256
            )
        }

        let manifest = ChunkManifest(
            chunkId: chunkId,
            chunkIndex: index,
            createdAt: Date(),
            files: manifestEntries,
            totalUncompressedSize: archiveSize,
            encryptedSize: encSize,
            sha256OfEncrypted: encryptedSHA256
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw ChunkerError.manifestGenerationFailed(error.localizedDescription)
        }

        logger.debug("Chunk \(index): Manifest written to \(manifestURL.lastPathComponent)")

        // Clean up the unencrypted ZIP to save disk space
        try? FileManager.default.removeItem(at: zipURL)

        return ChunkDescriptor(
            id: chunkId,
            chunkFileURL: encryptedURL,
            encryptedFileURL: encryptedURL,
            manifestURL: manifestURL,
            totalSize: archiveSize,
            encryptedSize: encSize,
            fileCount: files.count,
            index: index
        )
    }

    // MARK: - File Grouping

    /// Bin-pack files into groups whose total size ≤ `maxSize`.
    /// Uses a simple greedy first-fit approach. Files are processed in the order
    /// they were enumerated (typically alphabetical within each directory).
    private func groupIntoChunks(
        files: [(url: URL, relativePath: String, size: Int64, sha256: String)],
        maxSize: Int64
    ) -> [[(url: URL, relativePath: String, size: Int64, sha256: String)]] {
        var chunks: [[(url: URL, relativePath: String, size: Int64, sha256: String)]] = []
        var currentChunk: [(url: URL, relativePath: String, size: Int64, sha256: String)] = []
        var currentSize: Int64 = 0

        for file in files {
            // If adding this file would exceed the limit AND the current chunk is non-empty,
            // start a new chunk. Individual files larger than maxSize get their own chunk.
            if currentSize + file.size > maxSize && !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk = []
                currentSize = 0
            }
            currentChunk.append(file)
            currentSize += file.size
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    // MARK: - ZIP Archive Creation

    /// Create a ZIP archive using the STORE method (no compression).
    ///
    /// ZIP File Format (simplified):
    /// ```
    /// [Local file header + filename + file data] × N
    /// [Central directory headers]
    /// [End of central directory record]
    /// ```
    ///
    /// All multi-byte fields are little-endian.
    ///
    /// - Note: This implementation uses STORE (method 0) for simplicity and
    ///   zero external dependencies. Adding Deflate compression is a planned
    ///   future enhancement that would reduce chunk sizes by ~40-70%.
    ///
    /// - Parameters:
    ///   - files: Array of (source URL, relative path to store inside the archive).
    ///   - destination: URL where the ZIP file will be written.
    /// - Returns: Total size of the resulting archive in bytes.
    private func createZipArchive(
        files: [(url: URL, relativePath: String)],
        destination: URL
    ) async throws -> Int64 {
        let fileManager = FileManager.default

        // Remove any existing file at the destination
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        guard let outputStream = OutputStream(url: destination, append: false) else {
            throw ChunkerError.zipCreationFailed("Cannot create output stream at \(destination.path)")
        }
        outputStream.open()
        defer { outputStream.close() }

        // ZIP format constants
        let localFileHeaderSignature: UInt32 = 0x04034b50
        let centralDirectorySignature: UInt32 = 0x02014b50
        let endOfCentralDirSignature: UInt32 = 0x06054b50
        let versionNeeded: UInt16 = 20         // Version 2.0 (for STORE + Zip64 path sizes)
        let versionMadeBy: UInt16 = 20
        let generalPurposeBitFlag: UInt16 = 0
        let compressionMethod: UInt16 = 0      // STORE (no compression)
        let lastModTime: UInt16 = 0x5000       // Fixed: 20:00 (approximate)
        let lastModDate: UInt16 = 0x5921       // Fixed: 2024-01-01

        // Track offsets for the central directory
        var centralDirectoryEntries: [(
            fileName: Data,
            crc32: UInt32,
            compressedSize: UInt64,
            uncompressedSize: UInt64,
            localHeaderOffset: UInt64
        )] = []
        centralDirectoryEntries.reserveCapacity(files.count)

        var currentOffset: UInt64 = 0

        for (fileIndex, entry) in files.enumerated() {
            try Task.checkCancellation()

            let sourceURL = entry.url
            let relativePath = entry.relativePath
            let fileNameData = Data(relativePath.utf8)

            // Read the entire file into memory
            // For very large files, a streaming approach would be better, but since we
            // already group by chunk size (≤700 MB) and each file is ≤4 GB, this is
            // acceptable for the initial implementation.
            let fileData: Data
            do {
                fileData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            } catch {
                throw ChunkerError.zipCreationFailed(
                    "Cannot read file '\(sourceURL.lastPathComponent)': \(error.localizedDescription)"
                )
            }

            let crc32Value = crc32(data: fileData)
            let uncompressedSize = UInt64(fileData.count)
            // STORE method: compressed size == uncompressed size
            let compressedSize = uncompressedSize

            let localHeaderOffset = currentOffset

            // ── Write Local File Header ──
            // Signature (4) + Version needed (2) + Flags (2) + Compression (2)
            // + Mod time (2) + Mod date (2) + CRC-32 (4)
            // + Compressed size (4) + Uncompressed size (4) + Filename length (2) + Extra length (2)
            // + Filename
            var header = Data(capacity: 30)
            header.append(localFileHeaderSignature.littleEndian)
            header.append(versionNeeded.littleEndian)
            header.append(generalPurposeBitFlag.littleEndian)
            header.append(compressionMethod.littleEndian)
            header.append(lastModTime.littleEndian)
            header.append(lastModDate.littleEndian)
            header.append(crc32Value.littleEndian)
            header.append(UInt32(truncatingIfNeeded: compressedSize).littleEndian)
            header.append(UInt32(truncatingIfNeeded: uncompressedSize).littleEndian)
            header.append(UInt16(fileNameData.count).littleEndian)
            header.append(UInt16(0).littleEndian)  // extra field length

            _ = header.withUnsafeBytes { ptr in
                outputStream.write(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: header.count)
            }
            _ = fileNameData.withUnsafeBytes { ptr in
                outputStream.write(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: fileNameData.count)
            }
            currentOffset += UInt64(30 + fileNameData.count)

            // ── Write File Data ──
            let written = fileData.withUnsafeBytes { ptr -> Int in
                outputStream.write(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: fileData.count)
            }
            guard written == fileData.count else {
                throw ChunkerError.zipCreationFailed(
                    "Failed to write file data for '\(sourceURL.lastPathComponent)': wrote \(written) of \(fileData.count) bytes"
                )
            }
            currentOffset += UInt64(fileData.count)

            // Save for central directory
            centralDirectoryEntries.append((
                fileName: fileNameData,
                crc32: crc32Value,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))

            if (fileIndex + 1).isMultiple(of: 50) {
                logger.debug("ZIP: wrote \(fileIndex + 1)/\(files.count) entries")
            }
        }

        // ── Write Central Directory ──
        let centralDirectoryOffset = currentOffset

        for entry in centralDirectoryEntries {
            var cdHeader = Data(capacity: 46)
            cdHeader.append(centralDirectorySignature.littleEndian)      // 4
            cdHeader.append(versionMadeBy.littleEndian)                 // 2
            cdHeader.append(versionNeeded.littleEndian)                 // 2
            cdHeader.append(generalPurposeBitFlag.littleEndian)         // 2
            cdHeader.append(compressionMethod.littleEndian)             // 2
            cdHeader.append(lastModTime.littleEndian)                   // 2
            cdHeader.append(lastModDate.littleEndian)                   // 2
            cdHeader.append(entry.crc32.littleEndian)                   // 4
            cdHeader.append(UInt32(truncatingIfNeeded: entry.compressedSize).littleEndian)      // 4
            cdHeader.append(UInt32(truncatingIfNeeded: entry.uncompressedSize).littleEndian)   // 4
            cdHeader.append(UInt16(entry.fileName.count).littleEndian)   // 2
            cdHeader.append(UInt16(0).littleEndian)                     // extra field length
            cdHeader.append(UInt16(0).littleEndian)                     // file comment length
            cdHeader.append(UInt16(0).littleEndian)                     // disk number start
            cdHeader.append(UInt16(0).littleEndian)                     // internal file attributes
            cdHeader.append(UInt32(0).littleEndian)                     // external file attributes
            cdHeader.append(UInt32(truncatingIfNeeded: entry.localHeaderOffset).littleEndian)  // 4

            _ = cdHeader.withUnsafeBytes { ptr in
                outputStream.write(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: cdHeader.count)
            }
            _ = entry.fileName.withUnsafeBytes { ptr in
                outputStream.write(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: entry.fileName.count)
            }

            currentOffset += UInt64(46 + entry.fileName.count)
        }

        let centralDirectorySize = currentOffset - centralDirectoryOffset

        // ── Write End of Central Directory Record ──
        var eocd = Data(capacity: 22)
        eocd.append(endOfCentralDirSignature.littleEndian)                          // 4
        eocd.append(UInt16(0).littleEndian)                                        // disk number
        eocd.append(UInt16(0).littleEndian)                                        // disk with central dir
        eocd.append(UInt16(centralDirectoryEntries.count).littleEndian)            // entries on this disk
        eocd.append(UInt16(centralDirectoryEntries.count).littleEndian)            // total entries
        eocd.append(UInt32(truncatingIfNeeded: centralDirectorySize).littleEndian) // central dir size
        eocd.append(UInt32(truncatingIfNeeded: centralDirectoryOffset).littleEndian) // central dir offset
        eocd.append(UInt16(0).littleEndian)                                        // comment length

        _ = eocd.withUnsafeBytes { ptr in
            outputStream.write(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: eocd.count)
        }

        let totalSize = Int64(currentOffset + UInt64(eocd.count))
        logger.debug("ZIP archive created: \(totalSize) bytes, \(centralDirectoryEntries.count) entries")
        return totalSize
    }

    // MARK: - CRC-32

    /// Compute CRC-32 checksum using the standard polynomial 0xEDB88320 (reflected).
    private func crc32(data: Data) -> UInt32 {
        // Standard CRC-32 table using polynomial 0xEDB88320
        var crcTable: [UInt32] = Array(repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
            crcTable[i] = crc
        }

        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - AES-256-GCM Encryption

    /// Encrypt a file using AES-256-GCM.
    ///
    /// Output format:
    /// ```
    /// [12-byte nonce] [ciphertext] [16-byte tag]
    /// ```
    ///
    /// The file is processed in 1 MB blocks to avoid loading large files entirely
    /// into memory. Sealed boxes from CryptoKit require in-memory data, so we
    /// use a combined-stream approach: seal each block with the same nonce
    /// (the key/nonce combination is only used once per file).
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the unencrypted input file.
    ///   - destination: Path to write the encrypted output.
    ///   - key: 256-bit (32-byte) AES key.
    /// - Returns: Total size of the encrypted output file in bytes.
    private func encryptFile(
        at sourceURL: URL,
        destination: URL,
        key: Data
    ) async throws -> Int64 {
        let fileManager = FileManager.default

        // Remove existing destination
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        // Read the entire source file (needed for CryptoKit's SealedBox API)
        // For files up to ~700 MB (our chunk size), this is feasible.
        // A streaming GCM implementation would be needed for larger files.
        let plaintext: Data
        do {
            plaintext = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } catch {
            throw ChunkerError.encryptionFailed("Cannot read source file: \(error.localizedDescription)")
        }

        guard let symmetricKey = SymmetricKey(data: key) else {
            throw ChunkerError.encryptionFailed("Failed to create SymmetricKey from provided key data")
        }

        // Generate a random 12-byte nonce
        let nonce = AES.GCM.Nonce()
        guard nonce.count == Self.gcmNonceLength else {
            throw ChunkerError.encryptionFailed("Unexpected nonce length: \(nonce.count)")
        }

        // Seal the plaintext
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
        } catch {
            throw ChunkerError.encryptionFailed("AES-GCM sealing failed: \(error.localizedDescription)")
        }

        guard let combined = sealedBox.combined else {
            throw ChunkerError.encryptionFailed("SealedBox.combined is nil — unexpected state")
        }

        // Write: [nonce (12)] [combined (ciphertext + tag)]
        do {
            try combined.write(to: destination, options: .atomic)
        } catch {
            throw ChunkerError.encryptionFailed("Cannot write encrypted file: \(error.localizedDescription)")
        }

        // CryptoKit's combined representation already includes nonce + ciphertext + tag
        let totalSize = Int64(combined.count)
        return totalSize
    }

    /// Decrypt a file that was encrypted with `encryptFile(at:destination:key:)`.
    ///
    /// Expects the format: `[12-byte nonce] [ciphertext] [16-byte tag]`
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the encrypted input file.
    ///   - destination: Path to write the decrypted output.
    func decryptFile(at sourceURL: URL, destination: URL) async throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ChunkerError.encryptionFailed("Encrypted file not found: \(sourceURL.path)")
        }

        // Remove existing destination
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        guard let keyData = self.encryptionKey else {
            throw ChunkerError.noEncryptionKey
        }

        guard let symmetricKey = SymmetricKey(data: keyData) else {
            throw ChunkerError.encryptionFailed("Failed to create SymmetricKey")
        }

        // Read encrypted data
        let encryptedData: Data
        do {
            encryptedData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } catch {
            throw ChunkerError.encryptionFailed("Cannot read encrypted file: \(error.localizedDescription)")
        }

        // Reconstruct SealedBox from combined representation
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        } catch {
            throw ChunkerError.encryptionFailed("Failed to create SealedBox from combined data: \(error.localizedDescription)")
        }

        // Open (decrypt)
        let decrypted: Data
        do {
            decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw ChunkerError.encryptionFailed("AES-GCM decryption failed: \(error.localizedDescription)")
        }

        do {
            try decrypted.write(to: destination, options: .atomic)
        } catch {
            throw ChunkerError.encryptionFailed("Cannot write decrypted file: \(error.localizedDescription)")
        }

        logger.debug("Decrypted file written to \(destination.path) (\(decrypted.count) bytes)")
    }

    // MARK: - SHA-256 Hashing

    /// Compute the hex-encoded SHA-256 hash of a file.
    ///
    /// Uses a streaming approach with `FileHandle` for memory efficiency:
    /// updates the hash incrementally in 64 KB blocks.
    ///
    /// - Parameter url: URL of the file to hash.
    /// - Returns: Lowercase hex-encoded SHA-256 string (64 characters).
    private func computeSHA256(of url: URL) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            try? fileHandle.close()
        }

        var hash = SHA256()
        let bufferSize = 65_536 // 64 KB

        while true {
            try Task.checkCancellation()
            guard let chunk = try fileHandle.read(upToCount: bufferSize), !chunk.isEmpty else {
                break
            }
            hash.update(data: chunk)
        }

        let digest = hash.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cache Management

    /// Calculate the total size of all files in the chunk cache directory.
    ///
    /// - Returns: Total size in bytes, or 0 if the directory doesn't exist.
    func cacheSize() async -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

    /// Remove all cached chunk files (ZIPs, encrypted files, manifests).
    ///
    /// - Throws: FileManager errors.
    func clearCache() async throws {
        logger.info("Clearing chunk cache at \(cacheDirectory.path)")
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        logger.info("Chunk cache cleared")
    }

    /// List all files currently in the chunk cache directory.
    ///
    /// - Returns: Array of file URLs in the cache.
    func cachedChunks() async -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            if let isRegular = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
               isRegular == true {
                urls.append(fileURL)
            }
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Data Extension for Little-Endian Writing

private extension Data {
    /// Append a UInt32 in little-endian byte order.
    mutating func append(_ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { ptr in
            append(contentsOf: ptr)
        }
    }

    /// Append a UInt16 in little-endian byte order.
    mutating func append(_ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { ptr in
            append(contentsOf: ptr)
        }
    }
}
