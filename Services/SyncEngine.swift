import Foundation
import SwiftData
import OSLog
import Combine
import CryptoKit

/// Sync engine state
enum SyncEngineState: Equatable {
    case idle
    case scanning
    case chunking
    case uploading
    case paused
    case stopping
    
    static func == (lhs: SyncEngineState, rhs: SyncEngineState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.scanning, .scanning),
             (.chunking, .chunking),
             (.uploading, .uploading),
             (.paused, .paused),
             (.stopping, .stopping):
            return true
        default:
            return false
        }
    }
}

/// Errors that can occur during sync operations
enum SyncEngineError: LocalizedError {
    case authenticationFailed
    case networkUnavailable
    case floodWait(Int32)
    case uploadFailed(Error)
    case chunkingFailed
    case folderNotFound
    case bookmarkResolutionFailed
    
    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Telegram authentication failed"
        case .networkUnavailable:
            return "Network unavailable"
        case .floodWait(let seconds):
            return "Rate limited. Please wait \(seconds) seconds"
        case .uploadFailed(let error):
            return "Upload failed: \(error.localizedDescription)"
        case .chunkingFailed:
            return "Failed to create chunks"
        case .folderNotFound:
            return "Folder not found"
        case .bookmarkResolutionFailed:
            return "Failed to access folder (permission denied)"
        }
    }
}

/// Main sync engine orchestrating backup operations
@MainActor
class SyncEngine: ObservableObject {
    private let logger = Logger(subsystem: "com.backupbot.app", category: "SyncEngine")
    
    @Published var state: SyncEngineState = .idle
    @Published var currentProgress: Double = 0.0
    @Published var statusMessage: String = "Ready"
    @Published var isDryRun: Bool = false
    @Published var activeFolderId: UUID?
    
    private let modelContext: ModelContext
    private let mtProtoClient: MTProtoClient
    private let chunker: Chunker
    private let fileMonitor: FileMonitor
    
    private var encryptionKey: SymmetricKey
    private var cancellables: Set<AnyCancellable> = []
    private var uploadTask: Task<Void, Never>?
    
    // Configuration
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 5.0
    
    init(
        modelContext: ModelContext,
        mtProtoClient: MTProtoClient = MTProtoClient(),
        chunker: Chunker = Chunker(),
        fileMonitor: FileMonitor = FileMonitor()
    ) {
        self.modelContext = modelContext
        self.mtProtoClient = mtProtoClient
        self.chunker = chunker
        self.fileMonitor = fileMonitor
        
        // Generate encryption key from user defaults (simplified - should use keychain)
        let keyData = UserDefaults.standard.data(forKey: "encryption.key") ?? Data(count: 32)
        if keyData.count < 32 {
            var newData = Data(count: 32)
            _ = newData.withUnsafeMutableBytes { ptr in
                SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
            }
            UserDefaults.standard.set(newData, forKey: "encryption.key")
            self.encryptionKey = SymmetricKey(data: newData)
        } else {
            self.encryptionKey = SymmetricKey(data: keyData)
        }
        
        setupBindings()
    }
    
    private func setupBindings() {
        // Monitor auth state changes
        mtProtoClient.$authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .unauthorized {
                    self?.statusMessage = "Authentication required"
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Commands
    
    /// Start backup process for all active folders
    func startBackup() async {
        guard state == .idle || state == .paused else {
            logger.warning("Cannot start backup, current state: \(state)")
            return
        }
        
        logger.info("Starting backup (dryRun: \(isDryRun))")
        
        uploadTask = Task {
            await runBackupLoop()
        }
    }
    
    /// Stop backup process gracefully
    func stopBackup() {
        logger.info("Stopping backup")
        state = .stopping
        uploadTask?.cancel()
        uploadTask = nil
    }
    
    /// Toggle dry-run mode
    func toggleDryRun() {
        isDryRun.toggle()
        logger.info("Dry run mode: \(isDryRun)")
    }
    
    /// Rescan all folders for changes
    func rescanFolders() async {
        logger.info("Rescanning folders")
        
        do {
            let fetchDescriptor = FetchDescriptor<SyncFolder>(
                predicate: #Predicate { $0.isActive }
            )
            let folders = try modelContext.fetch(fetchDescriptor)
            
            for folder in folders {
                try await rescanFolder(folder)
            }
        } catch {
            logger.error("Failed to fetch folders: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Internal Processing
    
    private func runBackupLoop() async {
        do {
            let fetchDescriptor = FetchDescriptor<SyncFolder>(
                predicate: #Predicate { $0.isActive && $0.syncStatus != .completed }
            )
            let folders = try modelContext.fetch(fetchDescriptor)
            
            guard !folders.isEmpty else {
                await MainActor.run {
                    state = .idle
                    statusMessage = "No folders to backup"
                }
                return
            }
            
            for folder in folders {
                guard !Task.isCancelled else { break }
                
                await processFolder(folder)
            }
            
            await MainActor.run {
                state = .idle
                statusMessage = "Backup complete"
                currentProgress = 1.0
            }
        } catch {
            await MainActor.run {
                state = .idle
                statusMessage = "Error: \(error.localizedDescription)"
            }
            logger.error("Backup loop error: \(error.localizedDescription)")
        }
    }
    
    private func processFolder(_ folder: SyncFolder) async {
        guard !Task.isCancelled else { return }
        
        await MainActor.run {
            activeFolderId = folder.id
            state = .scanning
            statusMessage = "Scanning: \(folder.displayName)"
        }
        
        do {
            // Resolve bookmark
            guard let folderURL = SecureBookmark.shared.resolveBookmark(id: folder.id.uuidString) else {
                throw SyncEngineError.bookmarkResolutionFailed
            }
            defer { SecureBookmark.shared.stopAccessing(folderURL) }
            
            // Check authentication
            guard mtProtoClient.authState == .authorized || isDryRun else {
                throw SyncEngineError.authenticationFailed
            }
            
            // Get or create topic
            var topicId: Int64 = 0
            if !isDryRun {
                topicId = try await mtProtoClient.ensureTopicExists(name: folder.topicName ?? folder.folderName)
                
                // Update topic mapping
                if let mapping = folder.topicMapping {
                    mapping.topicId = topicId
                }
            }
            
            // Scan and create file records
            try await scanFolderContents(folder, url: folderURL)
            
            // Create chunks
            await MainActor.run {
                state = .chunking
                statusMessage = "Creating chunks: \(folder.displayName)"
            }
            
            let manifest = try await chunker.createChunks(
                from: folderURL,
                folderId: folder.id,
                encryptionKey: encryptionKey
            )
            
            // Upload chunks
            await MainActor.run {
                state = .uploading
                statusMessage = "Uploading chunks: \(folder.displayName)"
            }
            
            try await uploadChunks(manifest: manifest, topicId: topicId, folder: folder)
            
            // Mark complete
            folder.syncStatus = .completed
            folder.lastSyncDate = Date()
            folder.processedBytes = folder.totalBytes
            
            try modelContext.save()
            
            logger.info("Completed backup for: \(folder.displayName)")
            
        } catch {
            await MainActor.run {
                folder.syncStatus = .error
                folder.errorMessage = error.localizedDescription
                statusMessage = "Error: \(error.localizedDescription)"
            }
            logger.error("Failed to process folder \(folder.displayName): \(error.localizedDescription)")
        }
    }
    
    private func scanFolderContents(_ folder: SyncFolder, url: URL) async throws {
        let fm = FileManager.default
        var totalFiles = 0
        
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  let modDate = values.contentModificationDate else {
                continue
            }
            
            totalFiles += 1
            
            // Check if record exists
            let fetchDescriptor = FetchDescriptor<FileRecord>(
                predicate: #Predicate { $0.filePath == fileURL.path }
            )
            let existingRecords = try modelContext.fetch(fetchDescriptor)
            
            if existingRecords.isEmpty {
                // Create new record
                let relativePath = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                let record = FileRecord(
                    filePath: fileURL.path,
                    fileName: fileURL.lastPathComponent,
                    fileSize: Int64(fileSize),
                    relativePath: relativePath,
                    lastModified: modDate,
                    syncFolder: folder
                )
                modelContext.insert(record)
            }
        }
        
        folder.totalBytes = Int64(totalFiles) // Simplified count
        logger.info("Scanned \(totalFiles) files in \(folder.displayName)")
    }
    
    private func uploadChunks(manifest: ChunkManifest, topicId: Int64, folder: SyncFolder) async throws {
        var uploadedCount = 0
        let totalCount = manifest.chunks.count
        
        for (index, chunk) in manifest.chunks.enumerated() {
            guard !Task.isCancelled else { break }
            
            if chunk.uploaded {
                continue
            }
            
            let chunkURL = URL(fileURLWithPath: chunk.localPath)
            
            if !isDryRun {
                // Retry logic
                var retries = 0
                var success = false
                
                while retries < maxRetries && !success {
                    do {
                        try await mtProtoClient.uploadFile(
                            url: chunkURL,
                            toTopic: topicId,
                            progress: { [weak self] progress in
                                Task { @MainActor in
                                    self?.currentProgress = (Double(index) + progress) / Double(totalCount)
                                }
                            }
                        )
                        success = true
                    } catch MTProtoError.floodWait(let seconds) {
                        logger.warning("Flood wait: \(seconds)s")
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        retries += 1
                    } catch {
                        retries += 1
                        if retries >= maxRetries {
                            throw SyncEngineError.uploadFailed(error)
                        }
                        try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    }
                }
            }
            
            uploadedCount += 1
            currentProgress = Double(uploadedCount) / Double(totalCount)
            
            // Update topic mapping
            folder.topicMapping?.incrementUploadedChunks()
            
            logger.debug("Uploaded chunk \(index + 1)/\(totalCount)")
        }
        
        // Cleanup chunks after upload
        if !isDryRun {
            try chunker.cleanupCache(olderThan: Date().addingTimeInterval(-3600))
        }
    }
    
    private func rescanFolder(_ folder: SyncFolder) async throws {
        guard let folderURL = SecureBookmark.shared.resolveBookmark(id: folder.id.uuidString) else {
            throw SyncEngineError.bookmarkResolutionFailed
        }
        defer { SecureBookmark.shared.stopAccessing(folderURL) }
        
        let events = try await fileMonitor.rescan(path: folderURL)
        logger.info("Rescan found \(events.count) changes in \(folder.displayName)")
        
        // Reset status to trigger re-upload
        folder.syncStatus = .pending
        folder.topicMapping?.resetProgress(totalChunks: 0)
        
        try modelContext.save()
    }
    
    // MARK: - Properties
    
    var overallProgress: String {
        String(format: "%.1f%%", currentProgress * 100)
    }
    
    var isRunning: Bool {
        state == .scanning || state == .chunking || state == .uploading
    }
}