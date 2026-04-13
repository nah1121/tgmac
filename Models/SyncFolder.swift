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
    var isActive: Bool
    var lastEventId: UInt64
    var lastSyncDate: Date?
    var syncStatus: SyncStatus
    var errorMessage: String?
    
    var totalBytes: Int64
    var processedBytes: Int64
    
    var topicName: String?
    
    @Relationship(deleteRule: .cascade, inverse: \FileRecord.syncFolder)
    var fileRecords: [FileRecord] = []
    
    @Relationship(deleteRule: .nullify)
    var topicMapping: TopicMapping?
    
    init(path: String, bookmarkData: Data, displayName: String) {
        self.id = UUID()
        self.path = path
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.createdAt = Date()
        self.isActive = true
        self.lastEventId = UInt64.max
        self.syncStatus = .pending
        self.totalBytes = 0
        self.processedBytes = 0
        self.topicName = nil
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
}