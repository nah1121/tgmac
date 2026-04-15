import Foundation
import SwiftData
import os

// MARK: - Upload Status

/// Status of an individual upload operation.
///
/// Each case carries display metadata for UI binding. The raw value
/// is persisted in SwiftData for query efficiency.
enum UploadStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case uploading
    case completed
    case failed
    case cancelled
    case retrying

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending:   "Pending"
        case .uploading: "Uploading..."
        case .completed: "Completed"
        case .failed:    "Failed"
        case .cancelled: "Cancelled"
        case .retrying:  "Retrying..."
        }
    }

    var systemImage: String {
        switch self {
        case .pending:   "clock"
        case .uploading: "arrow.up.cloud"
        case .completed: "checkmark.circle.fill"
        case .failed:    "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        case .retrying:  "arrow.clockwise.circle"
        }
    }

    var tintColor: String {
        switch self {
        case .pending:   "secondary"
        case .uploading: "cyan"
        case .completed: "green"
        case .failed:    "red"
        case .cancelled: "gray"
        case .retrying:  "orange"
        }
    }
}

// MARK: - Upload History Record

/// SwiftData model that records the history of each chunk upload attempt.
///
/// Every upload operation — whether successful, failed, or cancelled — is
/// persisted as an ``UploadHistoryRecord`` so the user can review the
/// complete upload timeline, inspect errors, and retry or cancel individual
/// entries from the UI.
///
/// Records are linked bidirectionally to their parent ``SyncFolder`` via
/// the ``syncFolder`` relationship, and cascade-deleted when the folder
/// is removed.
@Model
final class UploadHistoryRecord {

    // MARK: - Stored Properties

    @Attribute(.unique)
    var id: UUID

    /// The folder this upload belongs to.
    @Index
    var folderID: UUID

    /// The chunk index (zero-based) within the folder's chunk sequence.
    var chunkIndex: Int32

    /// Human-readable label for the chunk (e.g., "Chunk 3/10").
    var chunkLabel: String

    /// The encrypted file name that was uploaded.
    var fileName: String

    /// Size of the encrypted file in bytes.
    var fileSize: Int64

    /// Raw string representation of ``UploadStatus``.
    @Index
    var statusRaw: String

    /// Number of bytes uploaded so far (updated during upload).
    var bytesUploaded: Int64

    /// The Telegram topic ID the file was uploaded to.
    var topicID: Int64

    /// The Telegram message ID returned after successful upload.
    var telegramMessageID: Int64?

    /// Number of retry attempts made for this upload.
    var retryCount: Int32

    /// Maximum retries allowed.
    var maxRetries: Int32

    /// Error message if the upload failed.
    var errorMessage: String?

    /// When the upload was first created.
    var createdAt: Date

    /// When the upload started.
    var startedAt: Date?

    /// When the upload finished (successfully or with error).
    var completedAt: Date?

    /// Duration of the upload in seconds (computed from startedAt / completedAt).
    var durationSeconds: Double?

    /// Upload speed in bytes per second (computed after completion).
    var speedBytesPerSecond: Double?

    // MARK: - Relationships

    @Relationship(deleteRule: .cascade, inverse: \SyncFolder.uploadHistory)
    var syncFolder: SyncFolder?

    // MARK: - Computed Properties

    var status: UploadStatus {
        get { UploadStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    /// Upload progress as a fraction from 0.0 to 1.0.
    var progress: Double {
        guard fileSize > 0 else { return 0 }
        return Double(bytesUploaded) / Double(fileSize)
    }

    /// Whether this record is in a state that allows retry.
    var canRetry: Bool {
        status == .failed || status == .cancelled
    }

    /// Whether this record is in a state that allows cancellation.
    var canCancel: Bool {
        status == .pending || status == .uploading || status == .retrying
    }

    /// Whether the upload is in a terminal state.
    var isTerminal: Bool {
        status == .completed || status == .failed || status == .cancelled
    }

    /// Human-readable file size.
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// Human-readable upload speed.
    var formattedSpeed: String? {
        guard let speed = speedBytesPerSecond, speed > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
    }

    /// Human-readable duration.
    var formattedDuration: String? {
        guard let duration = durationSeconds, duration > 0 else { return nil }
        if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return String(format: "%dm %ds", minutes, seconds)
        }
    }

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        folderID: UUID,
        chunkIndex: Int32,
        chunkLabel: String,
        fileName: String,
        fileSize: Int64,
        status: UploadStatus = .pending,
        bytesUploaded: Int64 = 0,
        topicID: Int64 = 0,
        telegramMessageID: Int64? = nil,
        retryCount: Int32 = 0,
        maxRetries: Int32 = 5,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        durationSeconds: Double? = nil,
        speedBytesPerSecond: Double? = nil,
        syncFolder: SyncFolder? = nil
    ) {
        self.id = id
        self.folderID = folderID
        self.chunkIndex = chunkIndex
        self.chunkLabel = chunkLabel
        self.fileName = fileName
        self.fileSize = fileSize
        self.statusRaw = status.rawValue
        self.bytesUploaded = bytesUploaded
        self.topicID = topicID
        self.telegramMessageID = telegramMessageID
        self.retryCount = retryCount
        self.maxRetries = maxRetries
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationSeconds = durationSeconds
        self.speedBytesPerSecond = speedBytesPerSecond
        self.syncFolder = syncFolder
    }

    // MARK: - State Transitions

    /// Marks the upload as started.
    func markStarted() {
        statusRaw = UploadStatus.uploading.rawValue
        startedAt = Date()
    }

    /// Marks the upload as completed with the given Telegram message ID.
    func markCompleted(messageID: Int64) {
        statusRaw = UploadStatus.completed.rawValue
        telegramMessageID = messageID
        completedAt = Date()
        errorMessage = nil
        if let started = startedAt, let completed = completedAt {
            let duration = completed.timeIntervalSince(started)
            durationSeconds = duration
            if duration > 0 {
                speedBytesPerSecond = Double(fileSize) / duration
            }
        }
    }

    /// Marks the upload as failed with the given error message.
    func markFailed(error: String) {
        statusRaw = UploadStatus.failed.rawValue
        errorMessage = error
        completedAt = Date()
        if let started = startedAt, let completed = completedAt {
            durationSeconds = completed.timeIntervalSince(started)
        }
    }

    /// Marks the upload as cancelled by the user.
    func markCancelled() {
        statusRaw = UploadStatus.cancelled.rawValue
        completedAt = Date()
        if let started = startedAt {
            durationSeconds = completedAt?.timeIntervalSince(started)
        }
    }

    /// Marks the upload as retrying (increments the retry counter).
    func markRetrying() {
        retryCount += 1
        statusRaw = UploadStatus.retrying.rawValue
        startedAt = Date()
        completedAt = nil
        errorMessage = nil
    }

    /// Updates the bytes-uploaded counter.
    func updateProgress(bytesUploaded: Int64) {
        self.bytesUploaded = bytesUploaded
    }
}
