import Foundation
import SwiftData
import os

// MARK: - File Sync Status

/// Sync status for an individual file record within a backup folder.
enum FileSyncStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case included
    case skipped
    case error

    /// Stable identifier matching the raw value.
    var id: String { rawValue }

    /// Human-readable label for UI presentation.
    var displayName: String {
        switch self {
        case .pending:  "Pending"
        case .included: "Included"
        case .skipped:  "Skipped"
        case .error:    "Error"
        }
    }

    /// SF Symbol name representing the status.
    var systemImage: String {
        switch self {
        case .pending:  "clock"
        case .included: "checkmark.circle"
        case .skipped:  "forward.end"
        case .error:    "exclamationmark.triangle"
        }
    }
}

// MARK: - FileRecord Model

/// Per-file metadata produced during the scanning phase of a folder sync.
///
/// Each ``FileRecord`` is owned by a single ``SyncFolder`` and is deleted
/// automatically when its parent folder is removed (cascade rule).
@Model
final class FileRecord {

    // MARK: - Stored Properties

    /// Unique identifier for the file record.
    @Attribute(.unique)
    var id: UUID

    /// The file name (last path component), extracted at scan time.
    var fileName: String

    /// Relative path from the folder root, used as a stable key across renames.
    /// Prefixed with ``SyncFolder/path`` at runtime to obtain the absolute location.
    @Index
    var filePath: String

    /// File size in bytes as reported by `FileManager.attributesOfItem(atPath:)`.
    var fileSize: Int64

    /// Hex-encoded SHA-256 digest of the file contents, computed during scanning.
    /// Stored for deduplication and change detection.
    var sha256Hash: String?

    /// Zero-based index of the chunk that contains this file's data.
    /// Multiple files may share the same chunk index if they are bundled together.
    var chunkIndex: Int32

    /// Raw string representation of ``FileSyncStatus``.
    /// Persisted as `String` for SwiftData compatibility.
    var syncStatusRaw: String

    /// When the record was first created.
    var createdAt: Date

    // MARK: - Relationships

    /// The parent folder that contains this file.
    /// Deleted automatically when the parent folder is removed.
    var syncFolder: SyncFolder?

    // MARK: - Computed Properties

    /// Typed accessor for the file's sync status.
    var syncStatus: FileSyncStatus {
        get {
            FileSyncStatus(rawValue: syncStatusRaw) ?? .pending
        }
        set {
            syncStatusRaw = newValue.rawValue
        }
    }

    /// Human-readable file size string (e.g. "1.2 MB") formatted via
    /// ``ByteCountFormatter`` with `.file` style.
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    // MARK: - Initialisation

    /// Creates a new ``FileRecord``.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (defaults to `UUID()`).
    ///   - fileName: File name (last path component).
    ///   - filePath: Relative path from the folder root.
    ///   - fileSize: Size in bytes.
    ///   - sha256Hash: Optional hex-encoded SHA-256 digest.
    ///   - chunkIndex: Zero-based chunk index (defaults to `-1` meaning unassigned).
    ///   - syncStatus: Initial sync status (defaults to `.pending`).
    ///   - createdAt: Creation timestamp (defaults to `now`).
    ///   - syncFolder: Parent folder (defaults to `nil`).
    init(
        id: UUID = UUID(),
        fileName: String,
        filePath: String,
        fileSize: Int64,
        sha256Hash: String? = nil,
        chunkIndex: Int32 = -1,
        syncStatus: FileSyncStatus = .pending,
        createdAt: Date = Date(),
        syncFolder: SyncFolder? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.filePath = filePath
        self.fileSize = fileSize
        self.sha256Hash = sha256Hash
        self.chunkIndex = chunkIndex
        self.syncStatusRaw = syncStatus.rawValue
        self.createdAt = createdAt
        self.syncFolder = syncFolder
    }
}
