import Foundation
import SwiftData

enum SyncStatus: Int, Codable {
    case pending = 0
    case scanning = 1
    case chunking = 2
    case uploading = 3
    case completed = 4
    case error = 5
    case paused = 6
}

@Model
@Index(\.path)
@Index(\.isActive, \.syncStatus)
class SyncFolder {
    @Attribute(.unique) var id: UUID
    var path: String
    var bookmarkData: Data
    var displayName: String
    var createdAt: Date
    var updatedAt: Date
    var isActive: Bool
    var lastEventId: UInt64
    var lastSyncDate: Date?
    var syncStatus: SyncStatus
    var errorMessage: String?
    
    var totalBytes: Int64
    var processedBytes: Int64
    var fileCount: Int
    
    var topicName: String?
    var dryRunEnabled: Bool
    var chunkSizeMB: Int
    
    @Relationship(deleteRule: .cascade, inverse: \FileRecord.syncFolder)
    var fileRecords: [FileRecord] = []
    
    @Relationship(deleteRule: .nullify)
    var topicMapping: TopicMapping?
    
    init(
        id: UUID = UUID(),
        path: String,
        bookmarkData: Data,
        displayName: String,
        topicName: String? = nil,
        totalBytes: Int64 = 0,
        processedBytes: Int64 = 0,
        fileCount: Int = 0,
        dryRunEnabled: Bool = false,
        chunkSizeMB: Int = 700,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isActive: Bool = true,
        lastEventId: UInt64 = UInt64.max,
        lastSyncDate: Date? = nil,
        syncStatus: SyncStatus = .pending,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.path = path
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.topicName = topicName
        self.totalBytes = totalBytes
        self.processedBytes = processedBytes
        self.fileCount = fileCount
        self.dryRunEnabled = dryRunEnabled
        self.chunkSizeMB = chunkSizeMB
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isActive = isActive
        self.lastEventId = lastEventId
        self.lastSyncDate = lastSyncDate
        self.syncStatus = syncStatus
        self.errorMessage = errorMessage
    }
    
    var resolvedURL: URL? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else { return nil }
            return url
        } catch {
            return nil
        }
    }
    
    var progress: Double {
        guard totalBytes > 0 else { return 0.0 }
        return Double(processedBytes) / Double(totalBytes)
    }
    
    var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
    
    func updateProgress(processed: Int64) {
        processedBytes = processed
        updatedAt = Date()
    }
}
