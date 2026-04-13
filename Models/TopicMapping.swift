import Foundation
import SwiftData

@Model
final class TopicMapping {
    @Attribute(.unique) var topicId: Int64
    var topicTitle: String
    var folderPathHash: String?
    var forumChatId: Int64?
    var createdAt: Date
    var updatedAt: Date
    var lastMessageId: Int64?
    var lastSyncDate: Date?
    var isActive: Bool
    var iconColor: Int32?
    var totalChunks: Int32
    var uploadedChunks: Int32
    var lastError: String?
    var keyVersion: Int
    
    @Relationship(inverse: \SyncFolder.topicMapping) var syncFolder: SyncFolder?
    
    init(
        topicId: Int64,
        topicTitle: String,
        syncFolder: SyncFolder? = nil,
        forumChatId: Int64? = nil,
        folderPathHash: String? = nil,
        iconColor: Int32? = nil,
        keyVersion: Int = 1
    ) {
        self.topicId = topicId
        self.topicTitle = topicTitle
        self.syncFolder = syncFolder
        self.forumChatId = forumChatId
        self.folderPathHash = folderPathHash
        self.iconColor = iconColor
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isActive = true
        self.totalChunks = 0
        self.uploadedChunks = 0
        self.keyVersion = keyVersion
    }
    
    var progress: Double {
        guard totalChunks > 0 else { return 0.0 }
        return Double(uploadedChunks) / Double(totalChunks)
    }
    
    var isComplete: Bool {
        uploadedChunks >= totalChunks && totalChunks > 0
    }
    
    var isPending: Bool {
        totalChunks > uploadedChunks
    }
    
    func markUpdated() {
        self.updatedAt = Date()
    }
    
    func recordSync(messageId: Int64) {
        self.lastMessageId = messageId
        self.lastSyncDate = Date()
        markUpdated()
    }
    
    func incrementUploadedChunks() {
        self.uploadedChunks += 1
        markUpdated()
    }
    
    func resetProgress(totalChunks: Int32) {
        self.totalChunks = totalChunks
        self.uploadedChunks = 0
        self.lastError = nil
        markUpdated()
    }
    
    func recordError(_ error: String) {
        self.lastError = error
        markUpdated()
    }
    
    func archive() {
        self.isActive = false
        markUpdated()
    }
    
    func activate() {
        self.isActive = true
        markUpdated()
    }
}
