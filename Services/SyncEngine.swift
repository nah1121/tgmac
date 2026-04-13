import Foundation
import SwiftData
import OSLog
import Combine

enum SyncEngineError: LocalizedError {
    case authenticationFailed
    case networkUnavailable
    case floodWait(Int32)
    case uploadFailed(Error)
    case chunkingFailed(Error)
}

@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()
    
    private let logger = Logger(subsystem: "com.backupbot.app", category: "SyncEngine")
    private let fileMonitor = FileMonitor()
    private let chunker = Chunker()
    private let mtproto = MTProtoClient.shared
    
    @Published var dryRun: Bool = false
    @Published var isRunning: Bool = false
    @Published var isAuthenticated: Bool = false
    
    private init() {}
    
    func start(folders: [SyncFolder], settings: AppSettings) {
        guard !folders.isEmpty else { return }
        if !isAuthenticated && !(dryRun || folders.contains(where: { $0.dryRunEnabled })) {
            for folder in folders {
                folder.syncStatus = .error
                folder.errorMessage = "Authenticate MTProto before starting."
            }
            return
        }
        isRunning = true
        Task {
            for folder in folders {
                await process(folder: folder, settings: settings)
            }
            await MainActor.run { self.isRunning = false }
        }
    }
    
    func stopAll() {
        isRunning = false
    }
    
    func rescan(folders: [SyncFolder]) {
        for folder in folders {
            folder.syncStatus = .pending
            folder.processedBytes = 0
            folder.errorMessage = nil
        }
    }
    
    private func process(folder: SyncFolder, settings: AppSettings) async {
        guard isRunning else { return }
        
        folder.syncStatus = .scanning
        let inventory = fileMonitor.inventory(for: folder)
        folder.fileRecords = inventory.records
        folder.totalBytes = inventory.totalBytes
        folder.fileCount = inventory.fileCount
        
        folder.syncStatus = .chunking
        let manifest: ChunkManifest
        do {
            manifest = try chunker.buildChunks(
                for: folder,
                files: inventory.records,
                passphrase: settings.passphrase,
                chunkSizeMB: settings.defaultChunkSizeMB,
                dryRun: dryRun || folder.dryRunEnabled
            )
        } catch {
            folder.syncStatus = .error
            folder.errorMessage = "Chunking failed: \(error.localizedDescription)"
            return
        }
        
        let mapping: TopicMapping
        do {
            mapping = try await mtproto.ensureTopic(for: folder, in: settings.forumChatId)
            folder.topicMapping = mapping
        } catch {
            folder.syncStatus = .error
            folder.errorMessage = "Topic ensure failed: \(error.localizedDescription)"
            return
        }
        
        folder.syncStatus = .uploading
        for chunk in manifest.chunks {
            guard isRunning else { break }
            do {
                try await mtproto.uploadChunk(descriptor: chunk, to: mapping, dryRun: dryRun || folder.dryRunEnabled)
                mapping.incrementUploadedChunks()
                folder.processedBytes += chunk.sizeBytes
            } catch {
                mapping.recordError(error.localizedDescription)
                folder.syncStatus = .error
                folder.errorMessage = error.localizedDescription
                return
            }
        }
        
        if isRunning {
            folder.syncStatus = .completed
            folder.lastSyncDate = Date()
            folder.errorMessage = nil
        }
    }

    func authenticate(phone: String, code: String, password: String?) {
        Task {
            do {
                try await mtproto.authenticate(phoneNumber: phone, code: code, password: password)
                await MainActor.run {
                    self.isAuthenticated = true
                }
            } catch {
                logger.error("Authentication failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.isAuthenticated = false
                }
            }
        }
    }
}
