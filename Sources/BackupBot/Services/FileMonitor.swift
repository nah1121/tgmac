//
//  FileMonitor.swift
//  BackupBot
//
//  Created by BackupBot Generator
//  Copyright (c) 2024 nah1121. All rights reserved.
//
//  File system monitoring service that watches sync folders for changes using
//  DispatchSource-based file system event sources. Provides debounced event
//  delivery through AsyncStream to avoid flooding consumers with rapid-fire events.
//
//  ## Design Note
//  `DispatchSource.makeFileSystemObjectSource` watches a single file descriptor.
//  When applied to a directory, it fires when the directory's metadata or content
//  listing changes (files added, removed, or modified within it). Unlike
//  `FSEventStream`, it does not report *which* specific file changed — only that
//  *something* changed in the watched directory. The consumer (e.g., SyncEngine)
//  is expected to re-scan the directory and diff against the previous snapshot.
//
//  For per-file granularity, `FSEventStreamCreate` from `CoreServices` could be
//  adopted in a future iteration.

import Foundation
import os

// MARK: - Public Types

/// Represents a file system change event within a monitored folder.
///
/// Because `DispatchSource` only notifies that *something* changed in a directory,
/// events are emitted at the folder level. The consumer should re-scan the
/// directory to determine which specific files were added, modified, or deleted.
enum FileChangeEvent: Sendable, Hashable {
    /// One or more files were created in the monitored folder.
    case added(filePath: String)
    /// One or more existing files were modified.
    case modified(filePath: String)
    /// One or more files were deleted from the monitored folder.
    case deleted(filePath: String)

    /// The path associated with this event.
    var filePath: String {
        switch self {
        case .added(let path), .modified(let path), .deleted(let path):
            return path
        }
    }
}

/// Configuration parameters for file monitoring behavior.
struct MonitorConfig: Sendable {
    /// Minimum quiet period (in seconds) after the last event before aggregated
    /// events are emitted. Higher values reduce event frequency but increase latency.
    let debounceInterval: TimeInterval

    /// Reserved for potential future use with FSEventStream-based monitoring.
    let latency: CFTimeInterval

    /// Sensible defaults for a backup application: 2-second debounce, 1-second latency.
    static let `default` = MonitorConfig(
        debounceInterval: 2.0,
        latency: 1.0
    )

    /// Aggressive configuration for testing or real-time sync needs.
    static let aggressive = MonitorConfig(
        debounceInterval: 0.5,
        latency: 0.25
    )

    /// Relaxed configuration to minimize CPU usage on battery.
    static let relaxed = MonitorConfig(
        debounceInterval: 5.0,
        latency: 3.0
    )
}

/// Errors specific to file monitoring operations.
enum FileMonitorError: LocalizedError, Sendable {
    /// The folder's bookmark could not be resolved to a file URL.
    case folderNotResolved(String)
    /// The folder is already being monitored.
    case alreadyMonitoring(UUID)
    /// The folder is not currently being monitored.
    case notMonitoring(UUID)
    /// The POSIX file descriptor could not be opened for the folder.
    case fileDescriptorFailed(path: String, errnoValue: Int32)

    var errorDescription: String? {
        switch self {
        case .folderNotResolved(let name):
            return "Cannot resolve URL for folder: \(name)"
        case .alreadyMonitoring(let id):
            return "Already monitoring folder \(id)"
        case .notMonitoring(let id):
            return "Not monitoring folder \(id)"
        case .fileDescriptorFailed(let path, let errnoVal):
            let reason = String(cString: strerror(errnoVal))
            return "Failed to open file descriptor for '\(path)': errno \(errnoVal) (\(reason))"
        }
    }
}

// MARK: - FileMonitorService

/// Actor-based file system monitoring service.
///
/// Uses `DispatchSource.makeFileSystemObjectSource` to watch for changes in
/// monitored folders. Events are debounced to aggregate rapid-fire changes
/// (e.g., a bulk copy operation) into a single batch, then delivered through
/// `AsyncStream` for ergonomic consumption by Swift concurrency code.
///
/// ## Event Flow
/// ```
/// File system change within watched directory
///   → DispatchSource event handler fires on sourceQueue
///     → [weak self] hop: Task { await self.recordEvent(...) }
///       → Event accumulated in pendingEvents set
///         → Existing debounce task cancelled; new one started
///           → After debounceInterval seconds of quiet (via Task.sleep):
///             → All pending events emitted via AsyncStream continuation
/// ```
///
/// ## Retain Safety
/// The dispatch source's event handler captures `[weak self]` to break the
/// potential retain cycle: actor → eventSources → dispatchSource → handler → actor.
/// If the actor is deallocated while monitoring, the handler becomes a no-op.
///
/// ## Usage
/// ```swift
/// let monitor = FileMonitorService()
/// try await monitor.startMonitoring(folder: syncFolder)
///
/// // In a separate Task:
/// for await (folderId, event) in monitor.events(for: syncFolder.id) {
///     await syncEngine.handleFolderChanged(folderId: folderId, event: event)
/// }
///
/// // Cleanup:
/// await monitor.stopMonitoring(folderId: syncFolder.id)
/// ```
actor FileMonitorService {

    // MARK: - State

    private let logger = Logger.fileMonitor
    private let config: MonitorConfig

    /// Active AsyncStreams keyed by folder ID.
    private var streams: [UUID: AsyncStream<(UUID, FileChangeEvent)>] = [:]

    /// Continuations for pushing events into the streams.
    private var continuations: [UUID: AsyncStream<(UUID, FileChangeEvent)>.Continuation] = [:]

    /// Active dispatch sources watching the file system.
    private var eventSources: [UUID: DispatchSourceFileSystemObject] = [:]

    /// POSIX file descriptors for each monitored folder.
    private var fileDescriptors: [UUID: Int32] = [:]

    /// The resolved URL being watched for each folder ID.
    private var monitoredPaths: [UUID: URL] = [:]

    /// Active debounce tasks, one per folder. Setting a new event cancels
    /// the previous task and starts a fresh one.
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]

    /// Accumulated pending events for each folder, waiting for debounce to fire.
    private var pendingEvents: [UUID: Set<FileChangeEvent>] = [:]

    private let fileManager = FileManager.default

    /// Serial dispatch queue for dispatch source event handlers.
    private let sourceQueue: DispatchQueue

    // MARK: - Initialization

    /// Create a new file monitor service.
    ///
    /// - Parameter config: Monitoring configuration. Defaults to `.default`
    ///   (2-second debounce, 1-second latency).
    init(config: MonitorConfig = .default) {
        self.config = config
        self.sourceQueue = DispatchQueue(
            label: "com.nah1121.BackupBot.file-monitor",
            qos: .utility
        )
        logger.info("FileMonitorService initialized (debounce: \(self.config.debounceInterval)s, latency: \(self.config.latency)s)")
    }

    // MARK: - Public API

    /// Start monitoring a sync folder for file system changes.
    ///
    /// Resolves the folder's security-scoped bookmark, opens a POSIX file
    /// descriptor with `O_EVTONLY`, creates a `DispatchSource` file system
    /// object source, and sets up an `AsyncStream` for event delivery.
    ///
    /// - Parameter folder: The `SyncFolder` model to monitor.
    /// - Throws: `FileMonitorError` if the URL cannot be resolved, the folder
    ///   is already monitored, or the file descriptor cannot be opened.
    func startMonitoring(folder: SyncFolder) async throws {
        let folderId = folder.id
        let displayName = folder.displayName

        guard !isMonitoring(folderId: folderId) else {
            logger.warning("Already monitoring folder: \(displayName) (\(folderId))")
            throw FileMonitorError.alreadyMonitoring(folderId)
        }

        // ── Resolve the folder URL from security-scoped bookmark ──
        guard let folderURL = folder.resolvedURL else {
            logger.error("Cannot resolve bookmark for folder: \(displayName)")
            throw FileMonitorError.folderNotResolved(displayName)
        }

        guard fileManager.fileExists(atPath: folderURL.path) else {
            logger.error("Folder path does not exist: \(folderURL.path)")
            throw FileMonitorError.folderNotResolved(displayName)
        }

        // ── Open a file descriptor with O_EVTONLY ──
        // O_EVTONLY: opens for event monitoring only; does not prevent
        // unmounting or deletion of the volume/directory.
        let fd = Darwin.open(folderURL.path, O_EVTONLY)
        guard fd >= 0 else {
            let err = errno
            logger.error("Failed to open fd for \(folderURL.path): errno \(err)")
            throw FileMonitorError.fileDescriptorFailed(path: folderURL.path, errnoValue: err)
        }

        logger.info("Starting file monitoring: \(displayName) at \(folderURL.path) (fd=\(fd))")

        // Store state
        monitoredPaths[folderId] = folderURL
        fileDescriptors[folderId] = fd
        pendingEvents[folderId] = []

        // ── Create AsyncStream for event delivery ──
        let (stream, continuation) = AsyncStream<(UUID, FileChangeEvent)>.makeStream()
        streams[folderId] = stream
        continuations[folderId] = continuation

        // ── Create DispatchSource ──
        let source = sourceQueue.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .attrib, .link],
            queue: sourceQueue
        )

        // Capture values needed by the closure. `self` is captured weakly
        // to prevent a retain cycle (actor → source → handler → actor).
        let capturedFolderId = folderId
        let capturedPath = folderURL.path
        let capturedDebounce = config.debounceInterval
        let capturedLog = logger

        source.setEventHandler { [weak self] in
            guard let self else {
                capturedLog.debug("FileMonitorService deallocated — dropping event for \(capturedPath)")
                return
            }

            // Hop to the actor's executor to safely mutate state
            Task { [weak self] in
                await self?.recordEvent(
                    folderId: capturedFolderId,
                    path: capturedPath,
                    debounceInterval: capturedDebounce
                )
            }
        }

        source.setCancelHandler {
            // Close the file descriptor. DispatchSource does NOT do this automatically.
            Darwin.close(fd)
            capturedLog.debug("Dispatch source canceled, fd=\(fd) closed for folder \(capturedFolderId)")
        }

        eventSources[folderId] = source
        source.resume()

        logger.info("File monitoring active for: \(displayName)")
    }

    /// Record a file system event for debounced delivery.
    ///
    /// Called from the dispatch source event handler (via `Task` hop to the
    /// actor's executor) when a change is detected in a monitored folder.
    ///
    /// Each call cancels the previous debounce task and starts a new one.
    /// After `debounceInterval` seconds of quiet, all accumulated events
    /// are emitted through the AsyncStream.
    ///
    /// - Parameters:
    ///   - folderId: UUID of the monitored folder.
    ///   - path: The folder path where the change was detected.
    ///   - debounceInterval: Seconds to wait before emitting.
    func recordEvent(folderId: UUID, path: String, debounceInterval: TimeInterval) {
        guard isMonitoring(folderId: folderId) else {
            return
        }

        guard !Task.isCancelled else {
            logger.debug("Task cancelled — ignoring event for folder \(folderId)")
            return
        }

        // Accumulate the event (deduplicated by filePath via Equatable)
        let event = FileChangeEvent.modified(filePath: path)
        pendingEvents[folderId]?.insert(event)

        // Cancel the existing debounce task
        debounceTasks[folderId]?.cancel()

        // Start a new debounce task
        debounceTasks[folderId] = Task { [weak self] in
            // Sleep for the debounce interval. If cancelled (superseded by
            // a newer event), this Task will throw CancellationError and
            // the events remain in pendingEvents for the next Task.
            do {
                try await Task.sleep(for: .seconds(debounceInterval))
            } catch {
                // Cancelled — exit silently
                return
            }

            // Hop to the actor to emit
            await self?.emitPendingEvents(folderId: folderId)
        }
    }

    /// Emit all pending events for a folder and clear the pending set.
    private func emitPendingEvents(folderId: UUID) {
        guard let events = pendingEvents[folderId], !events.isEmpty else {
            debounceTasks.removeValue(forKey: folderId)
            return
        }

        let continuation = continuations[folderId]
        let count = events.count

        for event in events {
            continuation?.yield((folderId, event))
        }

        pendingEvents[folderId] = []
        debounceTasks.removeValue(forKey: folderId)

        let name = monitoredPaths[folderId]?.lastPathComponent ?? folderId.uuidString
        logger.debug("Emitted \(count) debounced event(s) for folder '\(name)'")
    }

    /// Stop monitoring a specific folder.
    ///
    /// Cancels the dispatch source, invalidates the debounce task, finishes
    /// the event stream continuation, and removes all associated state.
    ///
    /// - Parameter folderId: UUID of the folder to stop monitoring.
    func stopMonitoring(folderId: UUID) {
        guard isMonitoring(folderId: folderId) else {
            logger.debug("Not monitoring folder \(folderId) — nothing to stop")
            return
        }

        let name = monitoredPaths[folderId]?.lastPathComponent ?? folderId.uuidString
        logger.info("Stopping file monitoring for: \(name)")

        // Cancel the dispatch source (triggers cancel handler → closes fd)
        if let source = eventSources.removeValue(forKey: folderId) {
            source.cancel()
        }

        // Clean up remaining state
        fileDescriptors.removeValue(forKey: folderId)
        debounceTasks[folderId]?.cancel()
        debounceTasks.removeValue(forKey: folderId)
        continuations.removeValue(forKey: folderId)?.finish()
        pendingEvents.removeValue(forKey: folderId)
        streams.removeValue(forKey: folderId)
        monitoredPaths.removeValue(forKey: folderId)

        logger.info("File monitoring stopped for: \(name)")
    }

    /// Stop monitoring all folders.
    ///
    /// Iterates over all active monitors and stops each one.
    /// Safe to call when no folders are being monitored.
    func stopAll() {
        let activeIds = Array(eventSources.keys)
        if activeIds.isEmpty {
            logger.debug("No active monitors to stop")
            return
        }
        logger.info("Stopping all file monitoring (\(activeIds.count) folders)")
        for id in activeIds {
            stopMonitoring(folderId: id)
        }
    }

    /// Get an async stream of file change events for a specific folder.
    ///
    /// - Parameter folderId: UUID of the monitored folder.
    /// - Returns: An `AsyncStream` of `(folderId, FileChangeEvent)` tuples.
    ///   If the folder is not being monitored, returns a stream that
    ///   immediately finishes.
    func events(for folderId: UUID) -> AsyncStream<(UUID, FileChangeEvent)> {
        guard let stream = streams[folderId] else {
            logger.warning("No event stream for folder \(folderId) — returning finished stream")
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return stream
    }

    /// Check whether a folder is currently being monitored.
    ///
    /// - Parameter folderId: UUID of the folder to check.
    /// - Returns: `true` if an active dispatch source exists for this folder.
    func isMonitoring(folderId: UUID) -> Bool {
        eventSources[folderId] != nil
    }

    /// Get the list of currently monitored folder IDs.
    func monitoredFolderIds() -> [UUID] {
        Array(eventSources.keys)
    }
}
