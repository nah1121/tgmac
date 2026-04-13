import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import OSLog

struct AddFolderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    private let logger = Logger(subsystem: "com.backupbot.app", category: "AddFolder")
    
    @State private var folderName: String = ""
    @State private var selectedPath: URL?
    @State private var topicName: String = ""
    @State private var isSelectingFolder: Bool = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false
    @State private var estimatedSize: String = "Calculating..."
    @State private var fileCount: Int = 0
    
    private var canSave: Bool {
        !folderName.isEmpty && selectedPath != nil && !topicName.isEmpty
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Backup Folder") {
                    HStack(spacing: 12) {
                        Image(systemName: selectedPath == nil ? "folder.badge.plus" : "folder.fill")
                            .font(.title2)
                            .foregroundStyle(selectedPath == nil ? .secondary : .accentColor)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedPath?.lastPathComponent ?? "No folder selected")
                                .font(.headline)
                            Text(selectedPath?.path ?? "Click browse to select a Smart Switch backup folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        
                        Spacer()
                        
                        Button("Browse...") {
                            selectFolder()
                        }
                        .disabled(isSelectingFolder)
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
                
                Section("Configuration") {
                    TextField("Display Name", text: $folderName)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Telegram Forum Topic", text: $topicName)
                        .textFieldStyle(.roundedBorder)
                        .help("This will be the topic name in the Telegram forum")
                }
                
                Section("Statistics") {
                    if let path = selectedPath {
                        HStack {
                            Label("Size", systemImage: "externaldrive")
                            Spacer()
                            Text(estimatedSize)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        
                        HStack {
                            Label("Files", systemImage: "doc.text")
                            Spacer()
                            Text("\(fileCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        Label("Select a folder to see statistics", systemImage: "arrow.up")
                            .foregroundStyle(.secondary)
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .frame(width: 550, height: 450)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Folder") {
                        saveFolder()
                    }
                    .disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }
    
    private func selectFolder() {
        isSelectingFolder = true
        
        DispatchQueue.main.async {
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = false
            openPanel.canChooseDirectories = true
            openPanel.allowsMultipleSelection = false
            openPanel.prompt = "Select"
            openPanel.message = "Choose a Samsung Smart Switch backup folder"
            openPanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Samsung/SmartSwitch/backup")
            
            openPanel.begin { result in
                isSelectingFolder = false
                
                guard result == .OK, let url = openPanel.url else { return }
                
                selectedPath = url
                
                if folderName.isEmpty {
                    folderName = url.lastPathComponent
                }
                
                if topicName.isEmpty {
                    let sanitized = url.lastPathComponent
                        .replacingOccurrences(of: " ", with: "_")
                        .replacingOccurrences(of: "/", with: "_")
                    topicName = String(sanitized.prefix(128))
                }
                
                calculateFolderStats(for: url)
                
                logger.info("Selected folder: \(url.path, privacy: .public)")
            }
        }
    }
    
    private func calculateFolderStats(for url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var size: Int64 = 0
            var count: Int = 0
            
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let fileURL as URL in enumerator {
                    if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                       values.isRegularFile == true,
                       let fileSize = values.fileSize {
                        size += Int64(fileSize)
                        count += 1
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.fileCount = count
                self.estimatedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        }
    }
    
    private func saveFolder() {
        guard let path = selectedPath else { return }
        
        do {
            let bookmarkData = try path.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            let folderId = UUID()
            
            SecureBookmark.shared.storeBookmark(id: folderId.uuidString, data: bookmarkData)
            
            // Calculate actual size in bytes for storage
            var totalSizeBytes: Int64 = 0
            if let size = ByteCountFormatter().byteCount(fromByteCount: Int64(fileCount > 0 ? Int64(estimatedSize.replacingOccurrences(of: ",", with: "")) : 0)) {
                totalSizeBytes = size
            }
            
            let syncFolder = SyncFolder(
                path: path.path,
                bookmarkData: bookmarkData,
                displayName: folderName
            )
            syncFolder.id = folderId
            syncFolder.topicName = topicName
            syncFolder.totalBytes = totalSizeBytes
            
            modelContext.insert(syncFolder)
            
            // Create topic mapping with placeholder topicId (will be updated when topic is created)
            let pathHash = computePathHash(path.path)
            let topicMapping = TopicMapping(
                topicId: 0, // Will be set when topic is created on Telegram
                topicTitle: topicName,
                syncFolder: syncFolder,
                folderPathHash: pathHash
            )
            
            modelContext.insert(topicMapping)
            syncFolder.topicMapping = topicMapping
            
            try modelContext.save()
            
            logger.info("Saved folder: \(folderName) with path: \(path.path)")
            
            dismiss()
        } catch {
            logger.error("Failed to save folder: \(error.localizedDescription)")
            errorMessage = "Failed to save folder: \(error.localizedDescription)"
            showError = true
        }
    }
    
    /// Compute a short hash of the folder path for unique topic naming
    private func computePathHash(_ path: String) -> String {
        let data = Data(path.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.prefix(8).joined()
    }
}