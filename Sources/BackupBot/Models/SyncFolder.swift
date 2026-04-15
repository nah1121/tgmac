import Foundation
import SwiftData
import os

// MARK: - Sync Status

/// Represents the lifecycle stages of a folder synchronisation operation.
///
/// Each case carries a display name, SF Symbol name, and semantic tint colour
/// so the UI can bind directly without switch statements.
enum SyncStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case scanning
    case chunking
    case uploading
    case completed
    case error
    case paused

    /// ``CaseIterable`` conformance uses the raw string as a stable identifier.
    var id: String { rawValue }

    /// Human-readable label suitable for UI presentation.
    var displayName: String {
        switch self {
        case .pending:   "Pending"
        case .scanning:  "Scanning..."
        case .chunking:  "Chunking..."
        case .uploading: "Uploading..."
        case .completed: "Completed"
        case .error:     "Error"
        case .paused:    "Paused"
        }
    }

    /// SF Symbol name that visually represents the status.
    var systemImage: String {
        switch self {
        case .pending:   "clock"
        case .scanning:  "magnifyingglass"
        case .chunking:  "doc.zip"
        case .uploading: "arrow.up.cloud"
        case .completed: "checkmark.circle.fill"
        case .error:     "exclamationmark.triangle.fill"
        case .paused:    "pause.circle"
        }
    }

    /// Semantic colour token name. Interpret with `Color(_: tintColor)`.
    var tintColor: String {
        switch self {
        case .pending:   "secondary"
        case .scanning:  "blue"
        case .chunking:  "orange"
        case .uploading: "cyan"
        case .completed: "green"
        case .error:     "red"
        case .paused:    "yellow"
        }
    }
}

// MARK: - SyncFolder Model

/// A SwiftData model that represents a user-selected backup folder.
///
/// Each ``SyncFolder`` tracks its on-disk location via a security-scoped bookmark
/// (`bookmarkData`), its Telegram topic mapping, and the collection of
/// ``FileRecord`` entries produced during scanning.
///
/// - Note: `syncStatusRaw` stores the raw `String` representation of ``SyncStatus``
///   because SwiftData can persist `String` properties but not enum raw values
///   directly via the `@Model` macro in all configurations. The computed
///   ``syncStatus`` property translates between the two.
@Model
final class SyncFolder {

    // MARK: - Stored Properties

    /// Unique identifier for the folder tracking entry.
    @Attribute(.unique)
    var id: UUID

    /// User-visible label (defaults to the folder name on creation).
    var displayName: String

    /// Absolute filesystem path chosen by the user.
    @Index
    var path: String

    /// Security-scoped bookmark data so the app can re-gain access after launch.
    var bookmarkData: Data?

    /// The current sync lifecycle stage, stored as a raw string.
    @Index
    var syncStatusRaw: String

    /// Overall progress fraction (0.0 – 1.0), updated by the sync engine.
    var progressValue: Double

    /// Total byte count of all files discovered during scanning.
    var totalSize: Int64

    /// Number of file chunks generated for this folder.
    var totalChunks: Int32

    /// Number of chunks that have been successfully uploaded.
    var uploadedChunks: Int32

    /// Whether this folder is actively participating in sync cycles.
    @Index
    var isActive: Bool

    /// Timestamp of when the folder was first added.
    var createdAt: Date

    /// Timestamp of the most recent sync completion or attempt.
    var lastSyncDate: Date?

    /// A free-text description of the last error encountered, if any.
    var lastError: String?

    // MARK: - Relationships

    /// All file records discovered inside this folder.
    /// Cascade delete ensures records are removed when the folder is removed.
    @Relationship(deleteRule: .cascade, inverse: \FileRecord.syncFolder)
    var files: [FileRecord]

    /// Optional mapping to a Telegram Saved Messages / forum topic.
    @Relationship(inverse: \TopicMapping.syncFolder)
    var topicMapping: TopicMapping?

    /// Upload history records for this folder.
    @Relationship(deleteRule: .cascade, inverse: \UploadHistoryRecord.syncFolder)
    var uploadHistory: [UploadHistoryRecord]

    // MARK: - Computed Properties

    /// Typed accessor for the sync status.
    var syncStatus: SyncStatus {
        get {
            SyncStatus(rawValue: syncStatusRaw) ?? .pending
        }
        set {
            syncStatusRaw = newValue.rawValue
        }
    }

    /// Convenience alias – mirrors ``progressValue`` so callers can use either name.
    var progress: Double {
        get { progressValue }
        set { progressValue = newValue }
    }

    /// Attempts to resolve the stored security-scoped bookmark into a usable `URL`.
    ///
    /// Returns `nil` if `bookmarkData` is missing or the bookmark is stale.
    /// When the bookmark is stale the property logs a warning and sets
    /// ``lastError`` so the UI can prompt the user to re-select the folder.
    var resolvedURL: URL? {
        guard let data = bookmarkData else {
            Logger.syncEngine.warning("No bookmark data for folder \(self.displayName)")
            return nil
        }

        var isStale = false
        let resolved = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            Logger.syncEngine.warning("Bookmark is stale for folder \(self.displayName)")
            self.lastError = "Folder access bookmark is stale. Please re-select the folder."
            return nil
        }

        return resolved
    }

    /// The last path component of ``path``, useful for display when ``displayName``
    /// has not been customised.
    var folderName: String {
        (path as NSString).lastPathComponent
    }

    // MARK: - Initialisation

    /// Creates a new ``SyncFolder`` instance.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (defaults to a new `UUID()`).
    ///   - displayName: User-visible label (defaults to the folder name derived from `path`).
    ///   - path: Absolute filesystem path to the folder.
    ///   - bookmarkData: Security-scoped bookmark data, if already available.
    ///   - syncStatus: Initial sync status (defaults to `.pending`).
    ///   - progressValue: Initial progress fraction (defaults to `0.0`).
    ///   - totalSize: Sum of all discovered file sizes (defaults to `0`).
    ///   - totalChunks: Number of generated chunks (defaults to `0`).
    ///   - uploadedChunks: Number of chunks already uploaded (defaults to `0`).
    ///   - isActive: Whether the folder participates in sync (defaults to `true`).
    ///   - createdAt: Creation timestamp (defaults to `now`).
    ///   - lastSyncDate: Most recent sync timestamp (defaults to `nil`).
    ///   - lastError: Error description (defaults to `nil`).
    ///   - files: Associated file records (defaults to empty array).
    ///   - topicMapping: Associated Telegram topic mapping (defaults to `nil`).
    init(
        id: UUID = UUID(),
        displayName: String? = nil,
        path: String,
        bookmarkData: Data? = nil,
        syncStatus: SyncStatus = .pending,
        progressValue: Double = 0.0,
        totalSize: Int64 = 0,
        totalChunks: Int32 = 0,
        uploadedChunks: Int32 = 0,
        isActive: Bool = true,
        createdAt: Date = Date(),
        lastSyncDate: Date? = nil,
        lastError: String? = nil,
        files: [FileRecord] = [],
        topicMapping: TopicMapping? = nil,
        uploadHistory: [UploadHistoryRecord] = []
    ) {
        self.id = id
        self.displayName = displayName ?? (path as NSString).lastPathComponent
        self.path = path
        self.bookmarkData = bookmarkData
        self.syncStatusRaw = syncStatus.rawValue
        self.progressValue = progressValue
        self.totalSize = totalSize
        self.totalChunks = totalChunks
        self.uploadedChunks = uploadedChunks
        self.isActive = isActive
        self.createdAt = createdAt
        self.lastSyncDate = lastSyncDate
        self.lastError = lastError
        self.files = files
        self.topicMapping = topicMapping
        self.uploadHistory = uploadHistory
    }
}
