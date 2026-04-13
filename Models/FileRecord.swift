import Foundation
import SwiftData

enum FileSyncStatus: Int, Codable {
    case pending = 0
    case chunked
    case uploading
    case uploaded
    case failed
}

@Model
final class FileRecord {
    @Attribute(.unique) var id: UUID
    var relativePath: String
    var sizeBytes: Int64
    var modifiedAt: Date
    var checksum: String?
    var status: FileSyncStatus
    var chunkIndex: Int?
    var lastError: String?
    var retries: Int
    var lastUpdated: Date
    
    @Relationship(inverse: \SyncFolder.fileRecords) var syncFolder: SyncFolder?
    
    init(
        id: UUID = UUID(),
        relativePath: String,
        sizeBytes: Int64,
        modifiedAt: Date,
        checksum: String? = nil,
        status: FileSyncStatus = .pending,
        chunkIndex: Int? = nil,
        lastError: String? = nil,
        retries: Int = 0,
        lastUpdated: Date = Date(),
        syncFolder: SyncFolder? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.checksum = checksum
        self.status = status
        self.chunkIndex = chunkIndex
        self.lastError = lastError
        self.retries = retries
        self.lastUpdated = lastUpdated
        self.syncFolder = syncFolder
    }
    
    func mark(status: FileSyncStatus, error: String? = nil, chunkIndex: Int? = nil) {
        self.status = status
        self.lastError = error
        self.chunkIndex = chunkIndex ?? self.chunkIndex
        self.lastUpdated = Date()
    }
}
