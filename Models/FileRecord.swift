import Foundation
import SwiftData

enum UploadStatus: Int, Codable {
    case pending = 0
    case chunking = 1
    case uploading = 2
    case completed = 3
    case failed = 4
}

@Model
@Index(\\.filePath)
@Index(\\.syncFolder, \\.uploadStatus)
final class FileRecord {
    @Attribute(.unique) var id: UUID
    var filePath: String
    var fileName: String
    var fileSize: Int64
    var relativePath: String
    var sha256Hash: String?
    var lastModified: Date
    var chunkCount: Int32
    var uploadedChunkCount: Int32
    var uploadStatus: UploadStatus
    var errorMessage: String?
    var retryCount: Int32
    var createdAt: Date
    var updatedAt: Date
    var lastUploadDate: Date?
    
    @Relationship(inverse: \SyncFolder.fileRecords) var syncFolder: SyncFolder?
    
    init(filePath: String, fileName: String, fileSize: Int64, relativePath: String, lastModified: Date, syncFolder: SyncFolder? = nil) {
        self.id = UUID()
        self.filePath = filePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.relativePath = relativePath
        self.lastModified = lastModified
        self.syncFolder = syncFolder
        self.chunkCount = 0
        self.uploadedChunkCount = 0
        self.uploadStatus = .pending
        self.retryCount = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    var progress: Double {
        guard chunkCount > 0 else { return 0.0 }
        return Double(uploadedChunkCount) / Double(chunkCount)
    }
    
    var isComplete: Bool {
        uploadStatus == .completed
    }
    
    var isPending: Bool {
        uploadStatus == .pending || uploadStatus == .chunking || uploadStatus == .uploading
    }
    
    func markChunking() {
        self.uploadStatus = .chunking
        self.updatedAt = Date()
    }
    
    func markUploading() {
        self.uploadStatus = .uploading
        self.updatedAt = Date()
    }
    
    func markCompleted() {
        self.uploadStatus = .completed
        self.lastUploadDate = Date()
        self.updatedAt = Date()
        self.errorMessage = nil
    }
    
    func markFailed(error: String) {
        self.uploadStatus = .failed
        self.errorMessage = error
        self.retryCount += 1
        self.updatedAt = Date()
    }
    
    func incrementUploadedChunks() {
        self.uploadedChunkCount += 1
        self.updatedAt = Date()
    }
    
    func setChunkCount(_ count: Int32) {
        self.chunkCount = count
        self.updatedAt = Date()
    }
    
    func setHash(_ hash: String) {
        self.sha256Hash = hash
        self.updatedAt = Date()
    }
    
    func resetProgress() {
        self.uploadedChunkCount = 0
        self.uploadStatus = .pending
        self.errorMessage = nil
        self.updatedAt = Date()
    }
}