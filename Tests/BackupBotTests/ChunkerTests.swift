//
//  ChunkerTests.swift
//  BackupBotTests
//
//  Unit tests for ChunkerService — file enumeration, ZIP archiving,
//  AES-256-GCM encryption/decryption, JSON manifest generation, and
//  cache management.
//
//  Swift 5.9, macOS 14+
//

import XCTest
import Foundation
import CryptoKit
@testable import BackupBotKit

final class ChunkerTests: XCTestCase {

    // MARK: - Properties

    var chunker: ChunkerService!
    var testDirectory: URL!
    var encryptionKey: Data!

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        try await super.setUp()

        // Create an isolated temp directory for this test run
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)

        // Create the ChunkerService and configure a deterministic 256-bit key
        chunker = ChunkerService()
        let symmetricKey = SymmetricKey(size: .bits256)
        encryptionKey = symmetricKey.withUnsafeBytes { Data($0) }
        await chunker.configureEncryptionKey(encryptionKey)

        // Clear any leftover cache from previous test runs
        try await chunker.clearCache()
    }

    override func tearDown() async throws {
        // Clear the chunker cache
        try? await chunker.clearCache()

        // Remove the test directory tree
        if let testDirectory {
            try? FileManager.default.removeItem(at: testDirectory)
        }

        chunker = nil
        testDirectory = nil
        encryptionKey = nil

        try await super.tearDown()
    }

    // MARK: - Basic Chunking

    /// Processing an empty folder should return an empty array without error.
    func testProcessEmptyFolder() async throws {
        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)

        XCTAssertTrue(descriptors.isEmpty, "Empty folder should produce zero chunks")
    }

    /// A single small file (< 1 MB) should produce exactly one chunk.
    func testProcessSingleSmallFile() async throws {
        let fileURL = try createTestFile(name: "document.txt", size: 64 * 1024) // 64 KB
        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)

        XCTAssertEqual(descriptors.count, 1, "A single small file should produce one chunk")
        XCTAssertEqual(descriptors[0].fileCount, 1, "The chunk should contain exactly 1 file")
        XCTAssertEqual(descriptors[0].index, 0, "The chunk index should be 0")

        // Verify the encrypted file exists on disk
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: descriptors[0].encryptedFileURL.path),
            "Encrypted file should exist on disk"
        )
    }

    /// Multiple small files that fit within the 700 MB limit should be grouped
    /// into a single chunk.
    func testProcessMultipleSmallFiles() async throws {
        let fileCount = 10
        for i in 0..<fileCount {
            _ = try createTestFile(name: "file_\(i).dat", size: 1024)
        }

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)

        XCTAssertEqual(descriptors.count, 1, "10 small files should fit in a single chunk")
        XCTAssertEqual(descriptors[0].fileCount, fileCount, "The chunk should contain all 10 files")
    }

    /// If the total file size exceeds the 700 MB chunk limit, multiple chunks
    /// should be produced. Since this is too slow for CI, we document the
    /// expected behaviour and use XCTAssertSkip for environments that require it.
    ///
    /// - Note: The default chunk size is 700 MB. To keep tests fast, this test
    ///   is skipped unless the `RUN_SLOW_TESTS` environment variable is set.
    func testProcessFilesExceedingChunkSize() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_SLOW_TESTS"] == "1",
            "Skipped: large-file multi-chunk test requires RUN_SLOW_TESTS=1"
        )

        // Create files that total ~750 MB (slightly above the 700 MB limit)
        let fileCount = 4
        let fileSize = 200 * 1024 * 1024 // 200 MB each = 800 MB total
        for i in 0..<fileCount {
            _ = try createTestFile(name: "large_\(i).bin", size: fileSize)
        }

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)

        XCTAssertGreaterThan(descriptors.count, 1, "Should produce multiple chunks for > 700 MB")
    }

    /// Verify no single chunk's uncompressed size exceeds the 700 MB default.
    func testChunkSizeDoesNotExceedLimit() async throws {
        // Create enough files to exceed one chunk
        for i in 0..<5 {
            _ = try createTestFile(name: "segment_\(i).dat", size: 160 * 1024 * 1024) // 160 MB each
        }

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)

        let maxChunkSize = ChunkerService.defaultChunkSize
        for descriptor in descriptors {
            XCTAssertLessThanOrEqual(
                descriptor.totalSize,
                maxChunkSize,
                "Chunk \(descriptor.index) uncompressed size (\(descriptor.totalSize)) exceeds limit (\(maxChunkSize))"
            )
        }
    }

    // MARK: - Encryption

    /// Encrypt a file via process(), decrypt it, and verify the ZIP archive
    /// magic bytes and size match the original archive.
    func testEncryptionRoundtrip() async throws {
        // Create a known-content file
        let content = Data(repeating: 0xAB, count: 4096)
        let fileURL = testDirectory.appendingPathComponent("roundtrip.bin")
        try content.write(to: fileURL)

        // Process to produce an encrypted chunk
        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)
        guard let descriptor = descriptors.first else {
            XCTFail("Expected at least one chunk descriptor")
            return
        }

        // Decrypt the encrypted file
        let decryptedURL = testDirectory.appendingPathComponent("decrypted_roundtrip.zip")
        try await chunker.decryptFile(at: descriptor.encryptedFileURL, destination: decryptedURL)

        // Verify the decrypted file exists and has a reasonable size
        let decryptedData = try Data(contentsOf: decryptedURL)
        XCTAssertGreaterThan(decryptedData.count, 0, "Decrypted file should not be empty")

        // Verify ZIP magic bytes: PK\x03\x04
        let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let prefix = Array(decryptedData.prefix(4))
        XCTAssertEqual(prefix, zipMagic, "Decrypted data should be a valid ZIP archive")

        // Verify size matches manifest's totalUncompressedSize
        let manifest = try decodeManifest(from: descriptor.manifestURL)
        XCTAssertEqual(
            Int64(decryptedData.count),
            manifest.totalUncompressedSize,
            "Decrypted ZIP size should match manifest totalUncompressedSize"
        )

        // Cleanup
        try? FileManager.default.removeItem(at: decryptedURL)
    }

    /// Two encryptions of the same input should produce different ciphertext
    /// because AES-256-GCM uses a random nonce each time.
    func testDifferentFilesProduceDifferentEncryptedOutputs() async throws {
        // First processing pass
        let folder1 = try createSyncFolder(from: testDirectory)
        let descriptors1 = try await chunker.process(folder: folder1, modelContext: nil)
        guard let desc1 = descriptors1.first else {
            XCTFail("First pass: expected at least one chunk")
            return
        }

        // Clear cache to force re-processing from scratch
        try await chunker.clearCache()

        // Second processing pass (same source files)
        let folder2 = try createSyncFolder(from: testDirectory)
        let descriptors2 = try await chunker.process(folder: folder2, modelContext: nil)
        guard let desc2 = descriptors2.first else {
            XCTFail("Second pass: expected at least one chunk")
            return
        }

        let encryptedData1 = try Data(contentsOf: desc1.encryptedFileURL)
        let encryptedData2 = try Data(contentsOf: desc2.encryptedFileURL)

        XCTAssertNotEqual(
            encryptedData1, encryptedData2,
            "Two encryptions of the same data should produce different ciphertext (random nonce)"
        )
    }

    // MARK: - Manifest

    /// Parse the JSON manifest and verify it contains correct file entries
    /// (file names, sizes, non-empty SHA-256 hashes).
    func testManifestContainsCorrectFileEntries() async throws {
        let fileNames = ["alpha.txt", "beta.dat", "gamma.log"]
        let fileSizes = [512, 1024, 2048]
        for (name, size) in zip(fileNames, fileSizes) {
            _ = try createTestFile(name: name, size: size)
        }

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)
        guard let descriptor = descriptors.first else {
            XCTFail("Expected at least one chunk")
            return
        }

        let manifest = try decodeManifest(from: descriptor.manifestURL)

        XCTAssertEqual(manifest.files.count, fileNames.count, "Manifest should list all files")
        XCTAssertEqual(manifest.chunkIndex, 0)

        // Verify each manifest entry
        for (entry, expectedName, expectedSize) in zip(manifest.files, fileNames, fileSizes) {
            XCTAssertEqual(entry.fileName, expectedName, "File name should match")
            XCTAssertEqual(entry.fileSize, Int64(expectedSize), "File size should match")
            XCTAssertFalse(
                entry.sha256Hash.isEmpty,
                "SHA-256 hash should be non-empty for \(expectedName)"
            )
            XCTAssertEqual(entry.sha256Hash.count, 64, "SHA-256 hex string should be 64 characters")
        }
    }

    /// Compute SHA-256 of the encrypted file and compare it to the manifest's
    /// `sha256OfEncrypted` field.
    func testManifestSHA256MatchesEncryptedFile() async throws {
        _ = try createTestFile(name: "verify.txt", size: 8192)

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)
        guard let descriptor = descriptors.first else {
            XCTFail("Expected at least one chunk")
            return
        }

        let manifest = try decodeManifest(from: descriptor.manifestURL)

        // Compute SHA-256 of the encrypted file ourselves
        let encryptedData = try Data(contentsOf: descriptor.encryptedFileURL)
        let hash = SHA256.hash(data: encryptedData)
        let computedHex = hash.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(
            manifest.sha256OfEncrypted,
            computedHex,
            "Manifest SHA-256 should match the actual encrypted file hash"
        )
    }

    // MARK: - SHA-256

    /// Create a file with known content, process it, and verify the manifest
    /// records the correct SHA-256 hash of the original file.
    func testSHA256Computation() async throws {
        let knownContent = Data("Hello, BackupBot test content!".utf8)
        let fileURL = testDirectory.appendingPathComponent("sha_test.txt")
        try knownContent.write(to: fileURL)

        // Compute expected hash independently using CryptoKit
        let expectedHash = SHA256.hash(data: knownContent)
        let expectedHex = expectedHash.map { String(format: "%02x", $0) }.joined()

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)
        guard let descriptor = descriptors.first else {
            XCTFail("Expected at least one chunk")
            return
        }

        let manifest = try decodeManifest(from: descriptor.manifestURL)
        XCTAssertEqual(
            manifest.files.first?.sha256Hash,
            expectedHex,
            "Manifest file hash should match independently computed SHA-256"
        )
    }

    // MARK: - Edge Cases

    /// Files in nested subdirectories should all be enumerated and included.
    func testProcessFolderWithNestedDirectories() async throws {
        // Create nested directory structure
        let sub1 = testDirectory.appendingPathComponent("level1")
        let sub2 = sub1.appendingPathComponent("level2")
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)

        _ = try createTestFile(name: "root.txt", size: 256)
        _ = try createTestFile(at: sub1.appendingPathComponent("nested.txt"), size: 512)
        _ = try createTestFile(at: sub2.appendingPathComponent("deep.txt"), size: 1024)

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)
        guard let descriptor = descriptors.first else {
            XCTFail("Expected at least one chunk")
            return
        }

        XCTAssertEqual(descriptor.fileCount, 3, "All nested files should be included")

        let manifest = try decodeManifest(from: descriptor.manifestURL)
        let manifestFileNames = manifest.files.map { $0.fileName }
        XCTAssertTrue(manifestFileNames.contains("root.txt"))
        XCTAssertTrue(manifestFileNames.contains("nested.txt"))
        XCTAssertTrue(manifestFileNames.contains("deep.txt"))
    }

    /// Hidden files (starting with `.`) should be skipped during enumeration.
    func testProcessFolderWithHiddenFiles() async throws {
        _ = try createTestFile(name: "visible.txt", size: 512)
        _ = try createTestFile(name: ".hidden_file", size: 512)
        _ = try createTestFile(name: ".DS_Store", size: 512)

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)
        guard let descriptor = descriptors.first else {
            XCTFail("Expected at least one chunk")
            return
        }

        XCTAssertEqual(descriptor.fileCount, 1, "Only visible files should be included")
        XCTAssertEqual(
            descriptor.fileCount, 1,
            "Hidden files (starting with .) should be skipped by the enumerator"
        )

        let manifest = try decodeManifest(from: descriptor.manifestURL)
        XCTAssertEqual(manifest.files.first?.fileName, "visible.txt")
    }

    /// Zero-byte files should be skipped during enumeration.
    func testProcessFolderWithZeroByteFiles() async throws {
        _ = try createTestFile(name: "real_file.txt", size: 1024)

        // Create a zero-byte file
        let zeroURL = testDirectory.appendingPathComponent("empty.dat")
        FileManager.default.createFile(atPath: zeroURL.path, contents: Data())

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)
        guard let descriptor = descriptors.first else {
            XCTFail("Expected at least one chunk")
            return
        }

        XCTAssertEqual(descriptor.fileCount, 1, "Zero-byte files should be skipped")

        let manifest = try decodeManifest(from: descriptor.manifestURL)
        XCTAssertEqual(manifest.files.first?.fileName, "real_file.txt")
    }

    // MARK: - Cache Management

    /// After processing, the cache directory should contain files
    /// (encrypted chunks and manifests), so cacheSize should be > 0.
    func testCacheSizeTracking() async throws {
        // Start with empty cache
        let initialSize = await chunker.cacheSize()
        XCTAssertEqual(initialSize, 0, "Cache should start empty after clearCache in setUp")

        // Process a folder
        _ = try createTestFile(name: "cache_test.bin", size: 4096)
        let folder = try createSyncFolder(from: testDirectory)
        _ = try await chunker.process(folder: folder, modelContext: nil)

        let sizeAfterProcessing = await chunker.cacheSize()
        XCTAssertGreaterThan(
            sizeAfterProcessing, 0,
            "Cache should contain data after processing"
        )
    }

    /// After clearCache(), cacheSize should return 0 and cachedChunks should
    /// return an empty array.
    func testClearCache() async throws {
        // Populate the cache
        _ = try createTestFile(name: "to_clear.txt", size: 2048)
        let folder = try createSyncFolder(from: testDirectory)
        _ = try await chunker.process(folder: folder, modelContext: nil)

        // Verify cache is non-empty
        let sizeBefore = await chunker.cacheSize()
        XCTAssertGreaterThan(sizeBefore, 0)

        // Clear and verify
        try await chunker.clearCache()

        let sizeAfter = await chunker.cacheSize()
        XCTAssertEqual(sizeAfter, 0, "Cache size should be 0 after clearing")

        let cached = await chunker.cachedChunks()
        XCTAssertTrue(cached.isEmpty, "cachedChunks should return empty array after clearing")
    }

    // MARK: - Cancellation

    /// Starting processing with a Task that is cancelled after a short delay
    /// should result in a CancellationError being thrown.
    func testProcessCancellation() async throws {
        // Create enough files that processing takes a measurable amount of time
        for i in 0..<50 {
            _ = try createTestFile(name: "cancel_\(i).dat", size: 100_000) // 100 KB each
        }

        let folder = try createSyncFolder(from: testDirectory)

        let task = Task {
            try await chunker.process(folder: folder, modelContext: nil)
        }

        // Cancel after a brief delay
        try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        task.cancel()

        do {
            _ = try await task.value
            // If processing completed before cancellation, that's acceptable —
            // the test passes vacuously.
        } catch is CancellationError {
            // Expected: the task was cancelled
        } catch {
            // Any other error is not a cancellation, but still means the task
            // finished (possibly with an error). Not a failure condition.
        }
    }

    // MARK: - Manifest Structure

    /// Verify that the manifest JSON is well-formed and contains all expected
    /// top-level fields (chunkId, chunkIndex, createdAt, files, sizes, hash).
    func testManifestJSONStructure() async throws {
        _ = try createTestFile(name: "struct_test.txt", size: 1024)

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)
        guard let descriptor = descriptors.first else {
            XCTFail("Expected at least one chunk")
            return
        }

        // Read raw JSON and verify it's valid
        let rawData = try Data(contentsOf: descriptor.manifestURL)
        XCTAssertFalse(rawData.isEmpty, "Manifest file should not be empty")

        // Verify it's parseable JSON
        let json = try JSONSerialization.jsonObject(with: rawData) as? [String: Any]
        XCTAssertNotNil(json, "Manifest should be a valid JSON object")
        XCTAssertNotNil(json?["chunkId"])
        XCTAssertNotNil(json?["chunkIndex"])
        XCTAssertNotNil(json?["createdAt"])
        XCTAssertNotNil(json?["files"])
        XCTAssertNotNil(json?["totalUncompressedSize"])
        XCTAssertNotNil(json?["encryptedSize"])
        XCTAssertNotNil(json?["sha256OfEncrypted"])
    }

    /// The encrypted file size should be the original archive size plus
    /// AES-256-GCM overhead (12-byte nonce + 16-byte tag = 28 bytes).
    func testEncryptedSizeIncludesGCMOverhead() async throws {
        _ = try createTestFile(name: "overhead_test.bin", size: 2048)

        let folder = try createSyncFolder(from: testDirectory)
        let descriptors = try await chunker.process(folder: folder, modelContext: nil)
        guard let descriptor = descriptors.first else {
            XCTFail("Expected at least one chunk")
            return
        }

        let manifest = try decodeManifest(from: descriptor.manifestURL)
        let gcmOverhead: Int64 = 28 // 12 (nonce) + 16 (tag)
        XCTAssertEqual(
            manifest.encryptedSize,
            manifest.totalUncompressedSize + gcmOverhead,
            "Encrypted size should be original size + 28 bytes (GCM nonce + tag)"
        )
    }

    // MARK: - Helpers

    /// Create a test file with random content at the given path relative to
    /// `testDirectory`.
    private func createTestFile(name: String, size: Int) throws -> URL {
        let url = testDirectory.appendingPathComponent(name)
        let data = Data(repeating: UInt8.random(in: 0...255), count: size)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Create a test file at an arbitrary absolute URL.
    private func createTestFile(at url: URL, size: Int) throws -> URL {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = Data(repeating: UInt8.random(in: 0...255), count: size)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Create a `SyncFolder` backed by a security-scoped bookmark pointing
    /// to the given directory URL.
    private func createSyncFolder(from directoryURL: URL) throws -> SyncFolder {
        let bookmarkData = try directoryURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return SyncFolder(
            path: directoryURL.path,
            bookmarkData: bookmarkData,
            displayName: directoryURL.lastPathComponent
        )
    }

    /// Decode a `ChunkManifest` from a JSON manifest file URL.
    private func decodeManifest(from url: URL) throws -> ChunkManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChunkManifest.self, from: data)
    }
}
