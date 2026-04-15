// SyncEngine.swift
// BackupBot (tgmac)
//
// Central orchestrator coordinating FileMonitor -> Chunker -> MTProtoClient.
// Manages the full backup pipeline: scan, chunk, encrypt, upload.
//
// Generated as part of the tgmac implementation plan (Task 3b).
// Swift 5.9, macOS 14+

import Foundation
import SwiftData
import os

// MARK: - SyncEngineError

/// Errors that can arise during the sync pipeline.
enum SyncEngineError: LocalizedError {
    /// The Telegram authentication flow failed (invalid code, expired token, etc.).
    case authenticationFailed

    /// The network is unavailable or the MTProto connection dropped.
    case networkUnavailable

    /// Telegram returned a FLOOD_WAIT error; the caller should wait the given number of seconds.
    case floodWait(Int32)

    /// A file upload failed with an underlying error.
    case uploadFailed(Error)

    /// The chunking / encryption step failed.
    case chunkingFailed

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Authentication failed. Please check your credentials and try again."
        case .networkUnavailable:
            return "Network is unavailable. Please check your internet connection."
        case .floodWait(let seconds):
            return "Telegram rate limit: please wait \(seconds) seconds before retrying."
        case .uploadFailed(let error):
            return "Upload failed: \(error.localizedDescription)"
        case .chunkingFailed:
            return "File chunking or encryption failed."
        }
    }
}

// MARK: - Folder Sync Status (Observable for UI)

/// Observable status for a single folder's sync operation.
///
/// This class is designed to be observed by SwiftUI views for real-time
/// progress display. It is NOT a SwiftData model — it lives only in memory
/// during an active sync operation.
///
/// ```swift
/// @State private var status: FolderSyncStatus?
/// // Bind to UI via the SyncEngine's getStatus() method
/// ```
@Observable
final class FolderSyncStatus: Identifiable, Sendable {
    /// The folder's unique identifier (matches ``SyncFolder/id``).
    let id: UUID

    /// Current lifecycle stage of the sync.
    var status: SyncStatus = .pending

    /// Overall progress from 0.0 to 1.0.
    var progress: Double = 0

    /// Human-readable description of the current phase (e.g., "Scanning files...", "Uploading chunk 3/10").
    var currentPhase: String = ""

    /// Total number of chunks that will be uploaded.
    var chunksTotal: Int = 0

    /// Number of chunks that have been fully uploaded.
    var chunksCompleted: Int = 0

    /// Error message if the sync failed.
    var errorMessage: String?

    /// Whether this is a dry-run (scan + chunk only, no upload).
    var isDryRun: Bool = false

    /// When the sync started.
    var startedAt: Date?

    /// When the sync finished (successfully or with error).
    var completedAt: Date?

    init(id: UUID) {
        self.id = id
    }
}

// MARK: - Sync Engine Configuration

/// Configuration for the sync engine behavior.
struct SyncEngineConfig: Sendable {
    /// Maximum number of concurrent uploads. v1 uses 1 (sequential).
    var maxConcurrentUploads: Int = 1

    /// If true, perform scan + chunk but skip actual upload.
    var dryRun: Bool = false

    /// Maximum number of retries per chunk on transient errors.
    var maxRetries: Int = 3

    /// Maximum seconds to wait on a FLOOD_WAIT before giving up.
    var floodWaitMaxSeconds: Int32 = 300  // 5 minutes

    /// Default configuration.
    static let `default` = SyncEngineConfig()
}

// MARK: - Sync Engine Service

/// Central orchestrator that coordinates the full backup pipeline:
///
/// ```
/// SyncFolder -> [scan] -> file inventory
///            -> [chunk] -> [ChunkDescriptor] (encrypted archives)
///            -> [upload] -> Telegram forum topics
/// ```
///
/// Thread safety is guaranteed by actor isolation. Each folder sync runs in
/// its own `Task`, tracked by `activeTasks` for cancellation support.
///
/// ## Usage
/// ```swift
/// let engine = SyncEngineService(
///     chunker: chunkerService,
///     mtprotoClient: mtprotoClient,
///     fileMonitor: fileMonitor
/// )
/// try await engine.sync(folder: myFolder, modelContext: context)
/// ```
actor SyncEngineService {

    // MARK: - Dependencies

    /// Handles file scanning, chunking, and encryption.
    private let chunker: ChunkerService

    /// Handles Telegram API communication (auth, upload, topics).
    private var mtprotoClient: MTProtoClientService

    /// Monitors file system changes for real-time sync triggers.
    private let fileMonitor: FileMonitorService

    // MARK: - Configuration

    private let config: SyncEngineConfig

    // MARK: - State

    /// Active sync tasks keyed by folder ID.
    private var activeTasks: [UUID: Task<Void, Error>] = [:]

    /// Per-folder sync status for UI observation.
    private var statusMap: [UUID: FolderSyncStatus] = [:]

    // MARK: - Logger

    private let logger = Logger.syncEngine

    // MARK: - Initialization

    /// Creates the sync engine with its required dependencies.
    ///
    /// - Parameters:
    ///   - config: Engine configuration (defaults to sequential uploads).
    ///   - chunker: Service for scanning, chunking, and encrypting files.
    ///   - mtprotoClient: Telegram MTProto client for API communication.
    ///   - fileMonitor: File system monitor for change detection.
    init(
        config: SyncEngineConfig = .default,
        chunker: ChunkerService,
        mtprotoClient: MTProtoClientService,
        fileMonitor: FileMonitorService
    ) {
        self.config = config
        self.chunker = chunker
        self.mtprotoClient = mtprotoClient
        self.fileMonitor = fileMonitor
        logger.info("SyncEngineService initialized (dryRun=\(config.dryRun), maxConcurrent=\(config.maxConcurrentUploads))")
    }

    // MARK: - Public API

    /// Syncs a single folder through the full pipeline: scan -> chunk -> upload.
    ///
    /// The method is idempotent — calling it again for a folder that's already
    /// syncing will cancel the previous sync and start a new one.
    ///
    /// - Parameters:
    ///   - folder: The ``SyncFolder`` to sync.
    ///   - modelContext: Optional SwiftData context for persisting progress updates.
    /// - Throws: ``SyncEngineError`` or underlying transport/chunker errors.
    func sync(folder: SyncFolder, modelContext: ModelContext?) async throws {
        // Cancel any existing sync for this folder
        if let existingTask = activeTasks[folder.id] {
            existingTask.cancel()
            activeTasks.removeValue(forKey: folder.id)
            logger.info("Cancelled existing sync for folder: \(folder.displayName)")
        }

        // Initialize folder sync status
        let status = FolderSyncStatus(id: folder.id)
        status.isDryRun = config.dryRun
        statusMap[folder.id] = status

        // Create the sync task
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }

            do {
                status.startedAt = Date()
                logger.info("Starting sync for folder: \(folder.displayName) (dryRun=\(config.dryRun))")

                // --- Phase 1: Scanning ---
                try Task.checkCancellation()
                await self.updateFolderStatus(folder, modelContext: modelContext, to: .scanning)
                status.currentPhase = "Scanning files..."
                status.status = .scanning

                // --- Phase 2: Chunking ---
                try Task.checkCancellation()
                await self.updateFolderStatus(folder, modelContext: modelContext, to: .chunking)
                status.currentPhase = "Chunking and encrypting files..."
                status.status = .chunking

                let chunks = try await self.chunkPhase(
                    folder: folder,
                    modelContext: modelContext,
                    status: status
                )

                status.chunksTotal = chunks.count
                logger.info("Chunking complete: \(chunks.count) chunks for \(folder.displayName)")

                // --- Phase 3: Uploading ---
                try Task.checkCancellation()

                if config.dryRun {
                    status.currentPhase = "Dry run complete (no uploads performed)"
                    status.status = .completed
                    status.completedAt = Date()
                    status.progress = 1.0
                    await self.updateFolderStatus(folder, modelContext: modelContext, to: .completed)
                    logger.info("Dry run complete for folder: \(folder.displayName)")
                    return
                }

                await self.updateFolderStatus(folder, modelContext: modelContext, to: .uploading)
                status.currentPhase = "Uploading chunks..."
                status.status = .uploading

                try await self.uploadPhase(
                    folder: folder,
                    chunks: chunks,
                    modelContext: modelContext,
                    status: status
                )

                // --- Completion ---
                status.status = .completed
                status.currentPhase = "Sync complete"
                status.progress = 1.0
                status.completedAt = Date()
                await self.updateFolderStatus(folder, modelContext: modelContext, to: .completed)

                logger.info("Sync complete for folder: \(folder.displayName) (\(status.chunksCompleted)/\(status.chunksTotal) chunks uploaded)")

            } catch is CancellationError {
                status.status = .paused
                status.currentPhase = "Sync cancelled"
                status.completedAt = Date()
                await self.updateFolderStatus(folder, modelContext: modelContext, to: .paused)
                logger.info("Sync cancelled for folder: \(folder.displayName)")

            } catch let error as SyncEngineError {
                status.status = .error
                status.errorMessage = error.errorDescription ?? error.localizedDescription
                status.currentPhase = "Error: \(status.errorMessage ?? "Unknown")"
                status.completedAt = Date()
                await self.updateFolderStatus(folder, modelContext: modelContext, to: .error, errorMessage: status.errorMessage)
                logger.error("Sync error for folder \(folder.displayName): \(error.errorDescription ?? "unknown")")

            } catch {
                let syncError = SyncEngineError.uploadFailed(error)
                status.status = .error
                status.errorMessage = syncError.errorDescription ?? error.localizedDescription
                status.currentPhase = "Error: \(status.errorMessage ?? "Unknown")"
                status.completedAt = Date()
                await self.updateFolderStatus(folder, modelContext: modelContext, to: .error, errorMessage: status.errorMessage)
                logger.error("Unexpected error for folder \(folder.displayName): \(error.localizedDescription)")
            }
        }

        activeTasks[folder.id] = task

        // Await completion to propagate errors
        try await task.value
    }

    /// Syncs all active folders sequentially.
    ///
    /// - Parameters:
    ///   - folders: Array of ``SyncFolder`` models to sync.
    ///   - modelContext: Optional SwiftData context for persisting progress.
    func syncAll(folders: [SyncFolder], modelContext: ModelContext?) async {
        logger.info("Starting sync for \(folders.count) folders")

        for folder in folders {
            // Skip inactive folders
            guard folder.isActive else {
                logger.debug("Skipping inactive folder: \(folder.displayName)")
                continue
            }

            // Skip folders that are already in a terminal state
            let currentStatus = folder.syncStatus
            if currentStatus == .completed {
                logger.debug("Skipping completed folder: \(folder.displayName)")
                continue
            }

            do {
                try await sync(folder: folder, modelContext: modelContext)
            } catch {
                logger.error("Failed to sync folder \(folder.displayName): \(error.localizedDescription)")
                // Continue with the next folder rather than stopping all
            }
        }

        logger.info("SyncAll complete")
    }

    /// Cancels the sync operation for a specific folder.
    ///
    /// - Parameter folderId: The UUID of the folder to cancel.
    func cancelSync(folderId: UUID) {
        guard let task = activeTasks[folderId] else {
            logger.debug("cancelSync: no active task for folderId=\(folderId)")
            return
        }
        task.cancel()
        activeTasks.removeValue(forKey: folderId)

        // Update the in-memory status
        if var status = statusMap[folderId] {
            status.status = .paused
            status.currentPhase = "Sync cancelled by user"
            status.completedAt = Date()
            statusMap[folderId] = status
        }

        logger.info("Sync cancelled for folderId=\(folderId)")
    }

    /// Cancels all active sync operations.
    func cancelAll() {
        let count = activeTasks.count
        for (folderId, task) in activeTasks {
            task.cancel()
            if var status = statusMap[folderId] {
                status.status = .paused
                status.currentPhase = "Sync cancelled by user"
                status.completedAt = Date()
                statusMap[folderId] = status
            }
        }
        activeTasks.removeAll()

        if count > 0 {
            logger.info("Cancelled all \(count) active syncs")
        }
    }

    /// Gets the current sync status for a specific folder.
    ///
    /// - Parameter folderId: The folder's UUID.
    /// - Returns: The ``FolderSyncStatus`` if a sync exists for this folder, otherwise `nil`.
    func getStatus(for folderId: UUID) -> FolderSyncStatus? {
        return statusMap[folderId]
    }

    /// Gets all current sync statuses.
    ///
    /// - Returns: An array of ``FolderSyncStatus`` for all tracked folders.
    func getAllStatuses() -> [FolderSyncStatus] {
        return Array(statusMap.values)
    }

    /// Whether any sync operation is currently in progress.
    var isSyncing: Bool {
        return !activeTasks.isEmpty
    }

    // MARK: - Internal Pipeline: Chunking

    /// Phase 2: Scans the folder and creates encrypted chunk archives.
    ///
    /// Delegates to ``ChunkerService/process(folder:modelContext:)`` which:
    /// 1. Resolves the secure bookmark URL
    /// 2. Walks the directory tree
    /// 3. Groups files into <= 1.8 GB chunks
    /// 4. Creates AES-256-GCM encrypted .tar archives
    /// 5. Persists ``FileRecord`` entries to SwiftData
    ///
    /// - Parameters:
    ///   - folder: The folder to chunk.
    ///   - modelContext: SwiftData context for persisting file records.
    ///   - status: Observable status to update during chunking.
    /// - Returns: Array of ``ChunkDescriptor`` for each encrypted chunk.
    /// - Throws: ``SyncEngineError/chunkingFailed`` or underlying chunker errors.
    private func chunkPhase(
        folder: SyncFolder,
        modelContext: ModelContext?,
        status: FolderSyncStatus
    ) async throws -> [ChunkDescriptor] {
        logger.info("ChunkPhase starting for folder: \(folder.displayName)")

        do {
            let chunks = try await chunker.process(folder: folder, modelContext: modelContext)
            logger.info("ChunkPhase complete: \(chunks.count) chunks produced")
            return chunks
        } catch {
            logger.error("ChunkPhase failed for \(folder.displayName): \(error.localizedDescription)")
            throw SyncEngineError.chunkingFailed
        }
    }

    // MARK: - Internal Pipeline: Uploading

    /// Phase 3: Uploads each encrypted chunk to the appropriate Telegram forum topic.
    ///
    /// For v1, chunks are uploaded sequentially (one at a time).
    /// Each chunk is uploaded to the folder's dedicated forum topic.
    /// If the topic doesn't exist yet, it is created via ``MTProtoClientService/createTopic(title:)``.
    ///
    /// - Parameters:
    ///   - folder: The folder being synced.
    ///   - chunks: Array of ``ChunkDescriptor`` to upload.
    ///   - modelContext: SwiftData context for persisting topic mappings and progress.
    ///   - status: Observable status to update during upload.
    /// - Throws: ``SyncEngineError/uploadFailed`` or ``SyncEngineError/floodWait``.
    private func uploadPhase(
        folder: SyncFolder,
        chunks: [ChunkDescriptor],
        modelContext: ModelContext?,
        status: FolderSyncStatus
    ) async throws {
        guard !chunks.isEmpty else {
            logger.info("No chunks to upload for \(folder.displayName)")
            return
        }

        logger.info("UploadPhase starting for folder: \(folder.displayName) (\(chunks.count) chunks)")

        // Resolve or create the forum topic for this folder
        let topicId = try await resolveTopic(for: folder, modelContext: modelContext)
        logger.info("Using topicId=\(topicId) for folder: \(folder.displayName)")

        // Update topic mapping with total chunks count
        await updateTopicMapping(folder: folder, topicId: topicId, totalChunks: Int32(chunks.count), modelContext: modelContext)

        // Upload each chunk sequentially (v1: concurrency = 1)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()

            status.currentPhase = "Uploading chunk \(index + 1)/\(chunks.count)"
            status.chunksCompleted = index
            status.progress = Double(index) / Double(chunks.count)
            logger.info("Uploading chunk \(index + 1)/\(chunks.count) (\(chunk.encryptedSize) bytes)")

            // Retry loop per chunk
            var retryCount = 0
            var uploadSucceeded = false

            while !uploadSucceeded && retryCount < config.maxRetries {
                do {
                    try Task.checkCancellation()

                    // Perform the upload via MTProto client
                    _ = try await mtprotoClient.uploadFile(
                        fileURL: chunk.encryptedFileURL,
                        toTopicId: topicId,
                        progressHandler: { [weak self] uploadProgress in
                            Task { [weak self] in
                                guard let self else { return }
                                // Update per-chunk progress within the overall progress
                                let chunkFraction = uploadProgress.fractionCompleted
                                let overallProgress = (Double(index) + chunkFraction) / Double(chunks.count)
                                var s = self.statusMap[folder.id]
                                s?.progress = overallProgress
                                if let s { self.statusMap[folder.id] = s }
                            }
                        }
                    )

                    uploadSucceeded = true
                    status.chunksCompleted = index + 1

                    // Increment the topic mapping counter
                    await incrementTopicMapping(folder: folder, modelContext: modelContext)

                    logger.info("Chunk \(index + 1)/\(chunks.count) uploaded successfully")

                } catch is CancellationError {
                    throw CancellationError()

                } catch let error as SyncEngineError {
                    if case .floodWait(let seconds) = error {
                        if seconds > config.floodWaitMaxSeconds {
                            logger.error("FLOOD_WAIT \(seconds)s exceeds max \(config.floodWaitMaxSeconds)s; giving up on chunk \(index + 1)")
                            throw error
                        }
                        retryCount += 1
                        logger.warning("FLOOD_WAIT \(seconds)s on chunk \(index + 1), retry \(retryCount)/\(config.maxRetries)")
                        // Wait before retrying
                        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                        continue
                    }
                    // Non-retryable SyncEngineError
                    await recordTopicMappingError(folder: folder, error: error.localizedDescription, modelContext: modelContext)
                    throw error

                } catch {
                    retryCount += 1
                    logger.error("Upload failed for chunk \(index + 1) (attempt \(retryCount)/\(config.maxRetries)): \(error.localizedDescription)")

                    if retryCount >= config.maxRetries {
                        await recordTopicMappingError(folder: folder, error: error.localizedDescription, modelContext: modelContext)
                        throw SyncEngineError.uploadFailed(error)
                    }

                    // Exponential backoff
                    let backoffSeconds = UInt64(pow(2.0, Double(retryCount)))
                    logger.info("Retrying chunk \(index + 1) after \(backoffSeconds)s backoff")
                    try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                }
            }

            // Update the folder's processed bytes in SwiftData
            let processedSoFar = chunks.prefix(index + 1).reduce(Int64(0)) { $0 + $1.totalSize }
            await updateFolderProgress(
                folderId: folder.id,
                processedBytes: processedSoFar,
                totalBytes: folder.totalSize,
                modelContext: modelContext
            )
        }

        // Final progress update
        status.chunksCompleted = chunks.count
        status.progress = 1.0
        status.currentPhase = "All chunks uploaded"
        logger.info("UploadPhase complete: \(chunks.count) chunks uploaded for \(folder.displayName)")
    }

    // MARK: - Topic Resolution

    /// Resolves the forum topic ID for a folder.
    ///
    /// If the folder already has a ``TopicMapping`` with a valid topic ID, returns it.
    /// Otherwise, creates a new forum topic via the MTProto client.
    ///
    /// - Parameters:
    ///   - folder: The folder to resolve a topic for.
    ///   - modelContext: SwiftData context for persisting the new topic mapping.
    /// - Returns: The resolved forum topic ID.
    /// - Throws: Network or API errors from the MTProto client.
    private func resolveTopic(for folder: SyncFolder, modelContext: ModelContext?) async throws -> Int64 {
        // If the folder already has a topic mapping, reuse it
        if let existing = folder.topicMapping, existing.topicId > 0 {
            logger.debug("Reusing existing topicId=\(existing.topicId) for \(folder.displayName)")
            return existing.topicId
        }

        // Create a new topic
        let topicTitle = folder.topicMapping?.topicTitle ?? folder.folderName
        let topicId = try await mtprotoClient.createTopic(title: topicTitle)

        logger.info("Created new topicId=\(topicId) with title '\(topicTitle)' for \(folder.displayName)")

        // Persist the topic mapping to SwiftData
        if let modelContext {
            await MainActor.run { [modelContext] in
                let mapping = TopicMapping(
                    topicId: topicId,
                    topicTitle: topicTitle,
                    totalChunks: 0,
                    uploadedChunks: 0
                )
                folder.topicMapping = mapping
                try? modelContext.save()
            }
        }

        return topicId
    }

    // MARK: - Progress Updates

    /// Updates the ``FolderSyncStatus`` in-memory record for a folder.
    ///
    /// - Parameters:
    ///   - folderId: The folder's UUID.
    ///   - update: Closure that mutates the status in place.
    private func updateStatus(folderId: UUID, update: (inout FolderSyncStatus) -> Void) {
        if var status = statusMap[folderId] {
            update(&status)
            statusMap[folderId] = status
        }
    }

    /// Updates the ``SyncFolder`` model's `syncStatus` and persists to SwiftData.
    ///
    /// UI updates must be dispatched to the main actor.
    ///
    /// - Parameters:
    ///   - folder: The folder model to update.
    ///   - modelContext: SwiftData context for persistence.
    ///   - status: The new ``SyncStatus``.
    ///   - errorMessage: Optional error message for `.error` status.
    private func updateFolderStatus(
        _ folder: SyncFolder,
        modelContext: ModelContext?,
        to status: SyncStatus,
        errorMessage: String? = nil
    ) async {
        await MainActor.run { [modelContext] in
            folder.syncStatus = status
            folder.lastError = errorMessage
            try? modelContext?.save()
        }
    }

    /// Updates the ``SyncFolder`` model's byte-level progress and persists.
    ///
    /// - Parameters:
    ///   - folderId: The folder's UUID (for status map lookup).
    ///   - processedBytes: Bytes processed so far.
    ///   - totalBytes: Total bytes to process.
    ///   - modelContext: SwiftData context for persistence.
    private func updateFolderProgress(
        folderId: UUID,
        processedBytes: Int64,
        totalBytes: Int64,
        modelContext: ModelContext?
    ) {
        updateStatus(folderId: folderId) { status in
            let overallProgress = totalBytes > 0 ? Double(processedBytes) / Double(totalBytes) : 0
            status.progress = max(status.progress, overallProgress)
        }
    }

    // MARK: - Topic Mapping Helpers

    /// Updates (or creates) the ``TopicMapping`` with the total chunks count.
    private func updateTopicMapping(
        folder: SyncFolder,
        topicId: Int64,
        totalChunks: Int32,
        modelContext: ModelContext?
    ) async {
        await MainActor.run { [modelContext] in
            if let existing = folder.topicMapping {
                existing.totalChunks = totalChunks
            } else {
                let mapping = TopicMapping(
                    topicId: topicId,
                    topicTitle: folder.topicMapping?.topicTitle ?? folder.folderName,
                    totalChunks: totalChunks,
                    uploadedChunks: 0
                )
                folder.topicMapping = mapping
            }
            try? modelContext?.save()
        }
    }

    /// Increments the uploaded chunks counter on the folder's ``TopicMapping``.
    private func incrementTopicMapping(folder: SyncFolder, modelContext: ModelContext?) async {
        await MainActor.run { [modelContext] in
            folder.topicMapping?.incrementUploadedChunks()
            folder.topicMapping?.recordSync()
            try? modelContext?.save()
        }
    }

    /// Records an error on the folder's ``TopicMapping``.
    private func recordTopicMappingError(folder: SyncFolder, error: String, modelContext: ModelContext?) async {
        await MainActor.run { [modelContext] in
            folder.topicMapping?.recordError(error)
            try? modelContext?.save()
        }
    }
}
