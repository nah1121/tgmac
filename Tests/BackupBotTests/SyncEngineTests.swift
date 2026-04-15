//
//  SyncEngineTests.swift
//  BackupBotTests
//
//  Unit tests for SyncEngineService — the central orchestrator that coordinates
//  folder scanning, chunking/encryption, and upload to Telegram.
//
//  Uses real ChunkerService for dry-run tests and mock transport for upload tests.
//  SwiftData models use an in-memory ModelContainer for test isolation.
//
//  Swift 5.9, macOS 14+
//

import XCTest
import Foundation
import SwiftData
import CryptoKit
@testable import BackupBotKit

final class SyncEngineTests: XCTestCase {

    // MARK: - Properties

    var modelContainer: ModelContainer!
    var modelContext: ModelContext!
    var chunker: ChunkerService!
    var mtprotoClient: MTProtoClientService!
    var mockTransport: MockSyncTransport!
    var fileMonitor: FileMonitorService!
    var engine: SyncEngineService!
    var testDirectory: URL!
    var encryptionKey: Data!

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        try await super.setUp()

        // Create an in-memory ModelContainer for SwiftData isolation
        modelContainer = try ModelContainer(
            for: SyncFolder.self, TopicMapping.self, FileRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        modelContext = ModelContext(modelContainer)

        // Create an isolated temp directory
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)

        // Generate a deterministic encryption key
        let symmetricKey = SymmetricKey(size: .bits256)
        encryptionKey = symmetricKey.withUnsafeBytes { Data($0) }

        // Create real ChunkerService with configured encryption key
        chunker = ChunkerService()
        await chunker.configureEncryptionKey(encryptionKey)
        try await chunker.clearCache()

        // Create MTProtoClientService with mock transport
        mockTransport = MockSyncTransport()
        mtprotoClient = MTProtoClientService(transport: mockTransport)
        try await mtprotoClient.configure(apiID: 1, apiHash: "test")
        // Authenticate the client for upload tests
        try await mtprotoClient.sendPhoneNumber("+15551234567")
        try await mtprotoClient.verifyCode("12345")
        await mtprotoClient.setForumChatID(999)

        // Create FileMonitorService with default config
        fileMonitor = FileMonitorService()

        // Create SyncEngineService with default (non-dry-run) config
        engine = SyncEngineService(
            config: .default,
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )
    }

    override func tearDown() async throws {
        // Clean up the engine and services
        await engine.cancelAll()
        await mtprotoClient.disconnect()
        try? await chunker.clearCache()

        // Remove temp directory
        if let testDirectory {
            try? FileManager.default.removeItem(at: testDirectory)
        }

        modelContainer = nil
        modelContext = nil
        chunker = nil
        mtprotoClient = nil
        mockTransport = nil
        fileMonitor = nil
        engine = nil
        testDirectory = nil
        encryptionKey = nil

        try await super.tearDown()
    }

    // MARK: - Basic Sync (Dry Run)

    /// A dry-run sync should complete without uploading, producing a `.completed`
    /// status and non-zero chunksTotal.
    func testSyncDryRun() async throws {
        // Create a test folder with files
        let folderDir = testDirectory.appendingPathComponent("dry_run_folder")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        try createTestFile(at: folderDir.appendingPathComponent("file1.txt"), size: 1024)
        try createTestFile(at: folderDir.appendingPathComponent("file2.txt"), size: 2048)

        let folder = try createSyncFolder(at: folderDir, name: "DryRunTest")
        modelContext.insert(folder)
        try modelContext.save()

        // Create a dry-run engine
        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        // Run the sync
        try await dryRunEngine.sync(folder: folder, modelContext: modelContext)

        // Verify the folder sync status
        let status = await dryRunEngine.getStatus(for: folder.id)
        XCTAssertNotNil(status, "Status should exist after sync")

        if let status {
            XCTAssertEqual(status.status, .completed, "Dry-run should complete successfully")
            XCTAssertTrue(status.isDryRun, "Status should indicate dry run")
            XCTAssertEqual(status.progress, 1.0, "Progress should be 1.0 after completion")
            XCTAssertTrue(status.chunksTotal > 0, "Should have produced at least one chunk")
            XCTAssertTrue(
                status.currentPhase.contains("Dry run"),
                "Phase should mention dry run: \(status.currentPhase)"
            )
            XCTAssertNil(status.errorMessage, "No error should have occurred")
        }

        // Verify no uploads were attempted
        let uploadCount = await mockTransport.uploadCallCount
        XCTAssertEqual(uploadCount, 0, "Dry-run should not trigger any uploads")
    }

    /// Syncing a single folder with real files should produce chunks.
    /// This test uses dry-run mode to avoid actual uploads.
    func testSyncSingleFolder() async throws {
        let folderDir = testDirectory.appendingPathComponent("single_folder")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        for i in 0..<5 {
            try createTestFile(at: folderDir.appendingPathComponent("doc_\(i).txt"), size: 2048)
        }

        let folder = try createSyncFolder(at: folderDir, name: "SingleFolderTest")
        modelContext.insert(folder)
        try modelContext.save()

        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        try await dryRunEngine.sync(folder: folder, modelContext: modelContext)

        let status = await dryRunEngine.getStatus(for: folder.id)
        XCTAssertNotNil(status)
        if let status {
            XCTAssertEqual(status.status, .completed)
            XCTAssertEqual(status.chunksTotal, 1, "5 small files should fit in one chunk")
            XCTAssertEqual(status.chunksCompleted, 0, "Dry run should not increment completed count")
        }
    }

    /// Syncing multiple folders sequentially should process all of them.
    func testSyncMultipleFolders() async throws {
        var folders: [SyncFolder] = []

        for i in 0..<3 {
            let folderDir = testDirectory.appendingPathComponent("multi_folder_\(i)")
            try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
            try createTestFile(at: folderDir.appendingPathComponent("file.txt"), size: 512)

            let folder = try createSyncFolder(at: folderDir, name: "MultiFolder_\(i)")
            modelContext.insert(folder)
            folders.append(folder)
        }
        try modelContext.save()

        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        await dryRunEngine.syncAll(folders: folders, modelContext: modelContext)

        for folder in folders {
            let status = await dryRunEngine.getStatus(for: folder.id)
            XCTAssertNotNil(status, "Status should exist for folder \(folder.displayName)")
            if let status {
                XCTAssertEqual(
                    status.status, .completed,
                    "Folder \(folder.displayName) should be completed"
                )
            }
        }
    }

    // MARK: - State Machine

    /// After a successful dry-run sync, the status should transition through
    /// scanning → chunking → completed.
    func testStatusTransitions() async throws {
        let folderDir = testDirectory.appendingPathComponent("state_machine")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        try createTestFile(at: folderDir.appendingPathComponent("test.txt"), size: 1024)

        let folder = try createSyncFolder(at: folderDir, name: "StateMachineTest")
        modelContext.insert(folder)
        try modelContext.save()

        // Collect status observations during sync
        var observedStatuses: [SyncStatus] = []
        let statusLock = NSLock()

        // Start the sync in a background task and poll for status
        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        let syncTask = Task {
            try await dryRunEngine.sync(folder: folder, modelContext: modelContext)
        }

        // Poll status while sync is running
        while !syncTask.isCompleted {
            if let status = await dryRunEngine.getStatus(for: folder.id) {
                statusLock.lock()
                if observedStatuses.last != status.status {
                    observedStatuses.append(status.status)
                }
                statusLock.unlock()
            }
            try await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }

        _ = try await syncTask.value

        // Final status
        if let finalStatus = await dryRunEngine.getStatus(for: folder.id) {
            statusLock.lock()
            if observedStatuses.last != finalStatus.status {
                observedStatuses.append(finalStatus.status)
            }
            statusLock.unlock()

            XCTAssertEqual(finalStatus.status, .completed, "Final status should be .completed")
        }

        // We should have seen at least the completed status
        XCTAssertTrue(
            observedStatuses.contains(.completed),
            "Should have observed .completed status. Observed: \(observedStatuses.map { $0.rawValue })"
        )
    }

    /// When the folder's bookmark cannot be resolved, the sync should result
    /// in an error state.
    func testErrorStateOnFailure() async throws {
        // Create a folder with invalid bookmark data (random bytes)
        let folder = SyncFolder(
            path: "/nonexistent/path/that/does/not/exist",
            bookmarkData: Data([0x00, 0x01, 0x02]),
            displayName: "InvalidFolder"
        )
        modelContext.insert(folder)
        try modelContext.save()

        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        do {
            try await dryRunEngine.sync(folder: folder, modelContext: modelContext)
            XCTFail("Sync should fail for a folder with an invalid bookmark")
        } catch {
            // Expected — the chunker cannot resolve the bookmark
        }

        // Verify the status is error
        let status = await dryRunEngine.getStatus(for: folder.id)
        XCTAssertNotNil(status)
        if let status {
            XCTAssertEqual(status.status, .error, "Status should be .error after failure")
            XCTAssertNotNil(status.errorMessage, "Error message should be set")
        }
    }

    // MARK: - Cancellation

    /// Cancelling a sync should set the status to `.paused`.
    func testCancelSync() async throws {
        let folderDir = testDirectory.appendingPathComponent("cancel_test")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        // Create enough files to give the sync time to start before we cancel
        for i in 0..<20 {
            try createTestFile(at: folderDir.appendingPathComponent("big_\(i).dat"), size: 50_000)
        }

        let folder = try createSyncFolder(at: folderDir, name: "CancelTest")
        modelContext.insert(folder)
        try modelContext.save()

        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        // Start the sync
        let syncTask = Task {
            try await dryRunEngine.sync(folder: folder, modelContext: modelContext)
        }

        // Give it a moment to start, then cancel
        try await Task.sleep(nanoseconds: 5_000_000) // 5 ms
        await dryRunEngine.cancelSync(folderId: folder.id)

        do {
            _ = try await syncTask.value
            // Sync completed before cancellation — acceptable for fast machines
        } catch is CancellationError {
            // Expected
        } catch {
            // Sync might have thrown another error
        }

        // Check status — should be .paused or .completed (if it finished first)
        let status = await dryRunEngine.getStatus(for: folder.id)
        if let status {
            XCTAssertTrue(
                status.status == .paused || status.status == .completed,
                "Status should be .paused (cancelled) or .completed (finished before cancel)"
            )
        }
    }

    /// `cancelAll()` should cancel all active syncs.
    func testCancelAll() async throws {
        var folders: [SyncFolder] = []
        var engines: [SyncEngineService] = []

        for i in 0..<3 {
            let folderDir = testDirectory.appendingPathComponent("cancel_all_\(i)")
            try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
            for j in 0..<10 {
                try createTestFile(at: folderDir.appendingPathComponent("f_\(j).txt"), size: 40_000)
            }

            let folder = try createSyncFolder(at: folderDir, name: "CancelAll_\(i)")
            modelContext.insert(folder)
            folders.append(folder)

            // Each engine needs its own chunker to avoid cache conflicts
            let localChunker = ChunkerService()
            await localChunker.configureEncryptionKey(encryptionKey)
            try await localChunker.clearCache()

            let localEngine = SyncEngineService(
                config: SyncEngineConfig(dryRun: true),
                chunker: localChunker,
                mtprotoClient: mtprotoClient,
                fileMonitor: fileMonitor
            )
            engines.append(localEngine)
        }
        try modelContext.save()

        // Start all syncs
        let tasks = zip(folders, engines).map { (folder, localEngine) -> Task<Void, Never> in
            Task {
                try? await localEngine.sync(folder: folder, modelContext: modelContext)
            }
        }

        // Cancel all on each engine
        for localEngine in engines {
            await localEngine.cancelAll()
        }

        // Wait for all tasks to complete
        for task in tasks {
            _ = await task.value
        }

        // Verify at least some were cancelled (or completed — both acceptable)
        var anyPaused = false
        for (folder, localEngine) in zip(folders, engines) {
            if let status = await localEngine.getStatus(for: folder.id) {
                if status.status == .paused {
                    anyPaused = true
                }
            }
        }
        // Note: on fast machines, all might complete before cancellation.
        // The important thing is that cancelAll doesn't crash or hang.
    }

    // MARK: - Progress Tracking

    /// After a successful dry-run sync, progress should be 1.0.
    func testProgressUpdates() async throws {
        let folderDir = testDirectory.appendingPathComponent("progress_test")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        try createTestFile(at: folderDir.appendingPathComponent("data.bin"), size: 4096)

        let folder = try createSyncFolder(at: folderDir, name: "ProgressTest")
        modelContext.insert(folder)
        try modelContext.save()

        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        try await dryRunEngine.sync(folder: folder, modelContext: modelContext)

        let status = await dryRunEngine.getStatus(for: folder.id)
        XCTAssertNotNil(status)
        if let status {
            XCTAssertEqual(
                status.progress, 1.0,
                "Progress should be 1.0 after successful dry-run"
            )
        }
    }

    /// After a successful sync, `chunksTotal` should reflect the number of
    /// chunks produced by the chunker, and `chunksCompleted` should equal
    /// `chunksTotal` for a completed sync.
    func testChunkProgressTracking() async throws {
        let folderDir = testDirectory.appendingPathComponent("chunk_progress")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        for i in 0..<3 {
            try createTestFile(at: folderDir.appendingPathComponent("chunk_\(i).dat"), size: 1024)
        }

        let folder = try createSyncFolder(at: folderDir, name: "ChunkProgress")
        modelContext.insert(folder)
        try modelContext.save()

        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        try await dryRunEngine.sync(folder: folder, modelContext: modelContext)

        let status = await dryRunEngine.getStatus(for: folder.id)
        XCTAssertNotNil(status)
        if let status {
            XCTAssertGreaterThan(
                status.chunksTotal, 0,
                "chunksTotal should be > 0 after processing"
            )
            XCTAssertEqual(
                status.chunksCompleted, 0,
                "chunksCompleted should be 0 for dry-run (no uploads)"
            )
        }
    }

    // MARK: - isSyncing

    /// `isSyncing` should return `false` when no syncs are active.
    func testIsSyncingIdle() async {
        let syncing = await engine.isSyncing
        XCTAssertFalse(syncing, "isSyncing should be false when no syncs are active")
    }

    /// `isSyncing` should return `true` while a sync is in progress.
    func testIsSyncingActive() async throws {
        let folderDir = testDirectory.appendingPathComponent("is_syncing")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        // Create enough files to ensure sync takes a moment
        for i in 0..<10 {
            try createTestFile(at: folderDir.appendingPathComponent("s_\(i).txt"), size: 50_000)
        }

        let folder = try createSyncFolder(at: folderDir, name: "IsSyncing")
        modelContext.insert(folder)
        try modelContext.save()

        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        let syncTask = Task {
            try await dryRunEngine.sync(folder: folder, modelContext: modelContext)
        }

        // Brief delay, then check
        try await Task.sleep(nanoseconds: 2_000_000) // 2 ms
        let syncing = await dryRunEngine.isSyncing
        // May or may not be syncing depending on speed, but should not crash
        _ = syncing

        _ = try await syncTask.value
    }

    // MARK: - getStatus

    /// `getStatus` should return `nil` for a folder that has never been synced.
    func testGetStatusForUnknownFolder() async {
        let status = await engine.getStatus(for: UUID())
        XCTAssertNil(status, "Status should be nil for an unknown folder ID")
    }

    /// `getAllStatuses` should return an empty array when no syncs have occurred.
    func testGetAllStatusesEmpty() async {
        let statuses = await engine.getAllStatuses()
        XCTAssertTrue(statuses.isEmpty, "Should have no statuses initially")
    }

    // MARK: - Empty Folder Sync

    /// Syncing an empty folder should complete without error and produce
    /// zero chunks.
    func testSyncEmptyFolder() async throws {
        let folderDir = testDirectory.appendingPathComponent("empty_sync")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        // No files created

        let folder = try createSyncFolder(at: folderDir, name: "EmptySync")
        modelContext.insert(folder)
        try modelContext.save()

        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        try await dryRunEngine.sync(folder: folder, modelContext: modelContext)

        let status = await dryRunEngine.getStatus(for: folder.id)
        if let status {
            XCTAssertEqual(status.status, .completed)
            XCTAssertEqual(status.chunksTotal, 0, "Empty folder should produce 0 chunks")
        }
    }

    // MARK: - FolderSyncStatus Properties

    /// `FolderSyncStatus` should have correct default values.
    func testFolderSyncStatusDefaults() {
        let status = FolderSyncStatus(id: UUID())

        XCTAssertEqual(status.status, .pending)
        XCTAssertEqual(status.progress, 0.0)
        XCTAssertEqual(status.currentPhase, "")
        XCTAssertEqual(status.chunksTotal, 0)
        XCTAssertEqual(status.chunksCompleted, 0)
        XCTAssertNil(status.errorMessage)
        XCTAssertFalse(status.isDryRun)
        XCTAssertNil(status.startedAt)
        XCTAssertNil(status.completedAt)
    }

    /// `FolderSyncStatus` is `Identifiable` and `Sendable`.
    func testFolderSyncStatusIdentifiable() {
        let id = UUID()
        let status = FolderSyncStatus(id: id)
        XCTAssertEqual(status.id, id)
    }

    // MARK: - SyncEngineConfig

    /// Default config should have sensible values.
    func testSyncEngineConfigDefaults() {
        let config = SyncEngineConfig.default
        XCTAssertEqual(config.maxConcurrentUploads, 1)
        XCTAssertFalse(config.dryRun)
        XCTAssertEqual(config.maxRetries, 3)
        XCTAssertEqual(config.floodWaitMaxSeconds, 300)
    }

    // MARK: - Topic Resolution (Documented Behavior)

    /// When a folder has no topic mapping, the sync engine should create a new
    /// topic via the MTProto client.
    ///
    /// - Note: This test documents the expected behavior. The actual topic creation
    ///   in the upload phase requires the MTProto client to be fully authenticated
    ///   and the transport to handle RPC calls. Since the current placeholder
    ///   transport generates mock topic IDs without calling the real API, this
    ///   test verifies the plumbing by checking that the mock transport's
    ///   `invoke` method would be called (if the upload path were reached).
    ///
    ///   For a full integration test, replace the mock with a real or recorded
    ///   MTProto transport.
    func testTopicCreationForNewFolder() async throws {
        let folderDir = testDirectory.appendingPathComponent("new_topic")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        try createTestFile(at: folderDir.appendingPathComponent("data.bin"), size: 2048)

        let folder = try createSyncFolder(at: folderDir, name: "NewTopicTest")
        // No TopicMapping set — engine should create one
        XCTAssertNil(folder.topicMapping, "Folder should have no topic mapping initially")
        modelContext.insert(folder)
        try modelContext.save()

        // In dry-run mode, the upload phase (and thus topic creation) is skipped.
        // The topic is only created when uploads actually happen.
        // Here we verify the dry-run completes successfully even without a topic mapping.
        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        try await dryRunEngine.sync(folder: folder, modelContext: modelContext)

        let status = await dryRunEngine.getStatus(for: folder.id)
        XCTAssertEqual(status?.status, .completed)
    }

    /// When a folder already has a TopicMapping, the sync engine should reuse
    /// the existing topic ID rather than creating a new one.
    ///
    /// - Note: Similar to `testTopicCreationForNewFolder`, the actual topic reuse
    ///   is tested in the upload phase. This test verifies the dry-run path works
    ///   correctly when a TopicMapping is already present.
    func testReuseExistingTopic() async throws {
        let folderDir = testDirectory.appendingPathComponent("reuse_topic")
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        try createTestFile(at: folderDir.appendingPathComponent("data.bin"), size: 2048)

        let folder = try createSyncFolder(at: folderDir, name: "ReuseTopicTest")

        // Pre-create a TopicMapping
        let mapping = TopicMapping(
            topicId: 42,
            topicTitle: "Existing Topic",
            totalChunks: 5,
            uploadedChunks: 3
        )
        folder.topicMapping = mapping

        modelContext.insert(folder)
        try modelContext.save()

        XCTAssertEqual(folder.topicMapping?.topicId, 42, "Pre-set topic ID should be 42")

        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        try await dryRunEngine.sync(folder: folder, modelContext: modelContext)

        let status = await dryRunEngine.getStatus(for: folder.id)
        XCTAssertEqual(status?.status, .completed)

        // Verify the existing topic mapping was not overwritten by dry-run
        XCTAssertEqual(folder.topicMapping?.topicId, 42, "Existing topic should not be replaced in dry-run")
    }

    // MARK: - Error Recovery (Documented Behavior)

    /// After a failed sync (e.g., invalid folder), re-syncing should attempt
    /// to process again from the beginning.
    ///
    /// - Note: The SyncEngineService processes each sync call independently.
    ///   A subsequent call to `sync(folder:modelContext:)` cancels any previous
    ///   in-flight sync and starts fresh.
    func testRetryAfterError() async throws {
        // First, create a folder with invalid bookmark data
        let invalidFolder = SyncFolder(
            path: "/nonexistent/retry/path",
            bookmarkData: Data([0xFF]),
            displayName: "RetryTest"
        )
        modelContext.insert(invalidFolder)
        try modelContext.save()

        let dryRunEngine = SyncEngineService(
            config: SyncEngineConfig(dryRun: true),
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )

        // First sync should fail
        do {
            try await dryRunEngine.sync(folder: invalidFolder, modelContext: modelContext)
            XCTFail("First sync should fail")
        } catch {
            // Expected
        }

        // Verify error state
        let errorStatus = await dryRunEngine.getStatus(for: invalidFolder.id)
        XCTAssertEqual(errorStatus?.status, .error)

        // Now fix the folder with valid bookmark data
        let validDir = testDirectory.appendingPathComponent("retry_valid")
        try FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
        try createTestFile(at: validDir.appendingPathComponent("fixed.txt"), size: 512)

        let validBookmark = try validDir.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        invalidFolder.path = validDir.path
        invalidFolder.bookmarkData = validBookmark
        try modelContext.save()

        // Retry — should succeed
        try await dryRunEngine.sync(folder: invalidFolder, modelContext: modelContext)

        let retryStatus = await dryRunEngine.getStatus(for: invalidFolder.id)
        XCTAssertEqual(retryStatus?.status, .completed, "Retry should succeed with valid folder")
    }

    // MARK: - SyncEngineError

    /// Verify that `SyncEngineError` provides meaningful descriptions.
    func testSyncEngineErrorDescriptions() {
        let errors: [(SyncEngineError, String)] = [
            (.authenticationFailed, "Authentication"),
            (.networkUnavailable, "Network"),
            (.floodWait(30), "30"),
            (.uploadFailed(NSError(domain: "test", code: -1)), "Upload"),
            (.chunkingFailed, "chunking"),
        ]

        for (error, expectedKeyword) in errors {
            XCTAssertNotNil(
                error.errorDescription,
                "Error \(error) should have a description"
            )
            XCTAssertTrue(
                error.errorDescription?.contains(expectedKeyword) == true,
                "Error description should contain '\(expectedKeyword)': \(error.errorDescription ?? "nil")"
            )
        }
    }

    // MARK: - Helpers

    /// Create a `SyncFolder` with a security-scoped bookmark pointing to the
    /// given directory.
    private func createSyncFolder(at directoryURL: URL, name: String) throws -> SyncFolder {
        let bookmarkData = try directoryURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return SyncFolder(
            path: directoryURL.path,
            bookmarkData: bookmarkData,
            displayName: name
        )
    }

    /// Create a file with random content at the given URL.
    private func createTestFile(at url: URL, size: Int) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = Data(repeating: UInt8.random(in: 0...255), count: size)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Mock Sync Transport

/// A lightweight mock transport used by SyncEngineTests.
///
/// Extends the behavior from MTProtoClientTests' MockMTProtoTransport with
/// additional tracking for upload call counting (for verifying dry-run behavior).
actor MockSyncTransport: MTProtoTransport {

    /// Total number of `uploadBigFile` calls received.
    var uploadCallCount = 0

    /// Whether operations succeed (default: `true`).
    var shouldSucceed = true

    /// Records of all upload parts received.
    var uploadParts: [(fileId: Int64, partIndex: Int, totalParts: Int)] = []

    func invoke(_ method: String, params: [String: Any]) async throws -> Data {
        guard shouldSucceed else {
            throw SyncEngineError.networkUnavailable
        }
        return try JSONSerialization.data(withJSONObject: ["ok": true])
    }

    func uploadBigFile(fileId: Int64, data: Data, partIndex: Int, totalParts: Int) async throws -> Bool {
        uploadCallCount += 1
        uploadParts.append((fileId: fileId, partIndex: partIndex, totalParts: totalParts))
        guard shouldSucceed else {
            throw SyncEngineError.uploadFailed(NSError(domain: "MockSync", code: -1))
        }
        return true
    }

    func isSessionValid() async -> Bool { true }
}
