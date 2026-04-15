import Foundation
import SwiftData
import os

// MARK: - TopicMapping Model

/// Maps a local backup folder to a Telegram Saved Messages / forum topic.
///
/// Each ``TopicMapping`` records the Telegram topic ID and metadata
/// required to route uploaded chunks to the correct topic. It is linked
/// bidirectionally to a single ``SyncFolder``.
@Model
final class TopicMapping {

    // MARK: - Stored Properties

    /// Unique identifier matching the associated ``SyncFolder/id``.
    /// This is NOT the Telegram topic ID – see ``topicId``.
    var id: UUID

    /// Telegram topic (thread) ID inside Saved Messages.
    var topicId: Int64

    /// User-visible title of the Telegram topic.
    var topicTitle: String

    /// Hash of the folder path, used for deduplication lookups.
    /// Computed on creation via `SHA256.hash(data:)` of the path UTF-8 data.
    var folderPathHash: String?

    /// When the mapping was first created.
    var createdAt: Date

    /// When the mapping was last modified (title change, etc.).
    var updatedAt: Date

    /// ID of the last Telegram message sent to this topic.
    var lastMessageId: Int64?

    /// Timestamp of the most recent successful sync to this topic.
    var lastSyncDate: Date?

    /// Whether this mapping is currently active for uploads.
    var isActive: Bool

    /// Telegram topic icon colour code (as defined by the Bot API).
    var iconColor: Int32?

    /// Total number of chunks expected for the associated folder.
    var totalChunks: Int32

    /// Number of chunks successfully uploaded so far.
    var uploadedChunks: Int32

    /// Free-text description of the last error during sync, if any.
    var lastError: String?

    // MARK: - Relationships

    /// The folder this mapping is associated with.
    /// Set to `nil` automatically when the folder is deleted (`.nullify` rule).
    @Relationship(deleteRule: .nullify, inverse: \SyncFolder.topicMapping)
    var syncFolder: SyncFolder?

    // MARK: - Computed Properties

    /// Upload progress as a fraction from 0.0 to 1.0.
    ///
    /// Returns `1.0` when ``totalChunks`` is zero (nothing to upload).
    var progress: Double {
        guard totalChunks > 0 else { return 1.0 }
        return Double(uploadedChunks) / Double(totalChunks)
    }

    /// Whether all chunks have been uploaded.
    var isComplete: Bool {
        totalChunks > 0 && uploadedChunks >= totalChunks
    }

    /// Whether no chunks have been uploaded yet.
    var isPending: Bool {
        uploadedChunks == 0
    }

    // MARK: - Initialisation

    /// Creates a new ``TopicMapping``.
    ///
    /// - Parameters:
    ///   - topicId: Telegram topic (thread) ID.
    ///   - topicTitle: User-visible topic title.
    ///   - folderPathHash: Optional pre-computed hash of the folder path.
    ///   - createdAt: Creation timestamp (defaults to `now`).
    ///   - updatedAt: Last-modified timestamp (defaults to `now`).
    ///   - lastMessageId: ID of the last message sent (defaults to `nil`).
    ///   - lastSyncDate: Timestamp of last successful sync (defaults to `nil`).
    ///   - isActive: Whether the mapping is active (defaults to `true`).
    ///   - iconColor: Telegram topic icon colour code (defaults to `nil`).
    ///   - totalChunks: Expected chunk count (defaults to `0`).
    ///   - uploadedChunks: Chunks already uploaded (defaults to `0`).
    ///   - lastError: Error description (defaults to `nil`).
    ///   - syncFolder: Associated folder (defaults to `nil`).
    init(
        topicId: Int64,
        topicTitle: String,
        folderPathHash: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastMessageId: Int64? = nil,
        lastSyncDate: Date? = nil,
        isActive: Bool = true,
        iconColor: Int32? = nil,
        totalChunks: Int32 = 0,
        uploadedChunks: Int32 = 0,
        lastError: String? = nil,
        syncFolder: SyncFolder? = nil
    ) {
        self.id = UUID()
        self.topicId = topicId
        self.topicTitle = topicTitle
        self.folderPathHash = folderPathHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageId = lastMessageId
        self.lastSyncDate = lastSyncDate
        self.isActive = isActive
        self.iconColor = iconColor
        self.totalChunks = totalChunks
        self.uploadedChunks = uploadedChunks
        self.lastError = lastError
        self.syncFolder = syncFolder
    }

    // MARK: - Helper Methods

    /// Touches ``updatedAt`` to the current moment.
    func markUpdated() {
        self.updatedAt = Date()
    }

    /// Records a successful sync cycle.
    ///
    /// - Parameters:
    ///   - date: The completion timestamp (defaults to `now`).
    ///   - lastMessageId: The ID of the last Telegram message sent during this cycle.
    func recordSync(date: Date = Date(), lastMessageId: Int64? = nil) {
        self.lastSyncDate = date
        if let lastMessageId {
            self.lastMessageId = lastMessageId
        }
        self.lastError = nil
        markUpdated()
    }

    /// Increments ``uploadedChunks`` by the given amount, clamped to ``totalChunks``.
    ///
    /// - Parameter count: Number of additional chunks uploaded (defaults to `1`).
    func incrementUploadedChunks(by count: Int32 = 1) {
        uploadedChunks = min(uploadedChunks + count, totalChunks)
        markUpdated()
    }

    /// Resets progress counters to zero, clearing any error state.
    func resetProgress() {
        uploadedChunks = 0
        totalChunks = 0
        lastError = nil
        lastSyncDate = nil
        lastMessageId = nil
        markUpdated()
    }

    /// Records an error message and updates the timestamp.
    ///
    /// - Parameter message: Human-readable error description.
    func recordError(_ message: String) {
        self.lastError = message
        markUpdated()
    }

    /// Marks the mapping as inactive (archived) without deleting it.
    func archive() {
        self.isActive = false
        markUpdated()
    }

    /// Re-activates a previously archived mapping.
    func activate() {
        self.isActive = true
        markUpdated()
    }
}
