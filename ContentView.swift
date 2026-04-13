import SwiftUI
import SwiftData
import OSLog

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SyncFolder.createdAt) private var folders: [SyncFolder]
    
    @StateObject private var syncEngine: SyncEngine
    @State private var showingAddFolder = false
    @State private var selectedFolderId: UUID?
    
    private let logger = Logger(subsystem: "com.backupbot.app", category: "ContentView")
    
    init() {
        _syncEngine = StateObject(wrappedValue: SyncEngine(modelContext: ModelContext.shared))
    }
    
    var body: some View {
        NavigationSplitView {
            // Sidebar - Folder List
            List(folders, selection: $selectedFolderId) { folder in
                FolderRowView(folder: folder)
                    .tag(folder.id)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddFolder = true
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                    }
                }
                
                ToolbarItem(placement: .automatic) {
                    Button {
                        if syncEngine.isRunning {
                            syncEngine.stopBackup()
                        } else {
                            Task {
                                await syncEngine.startBackup()
                            }
                        }
                    } label: {
                        Label(syncEngine.isRunning ? "Stop" : "Start", 
                              systemImage: syncEngine.isRunning ? "stop.fill" : "play.fill")
                    }
                    .disabled(folders.isEmpty)
                }
                
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: $syncEngine.isDryRun) {
                        Label("Dry Run", systemImage: "eye")
                    }
                    .help("Preview backup without uploading")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Backup Folders")
            .sheet(isPresented: $showingAddFolder) {
                AddFolderView()
            }
        } detail: {
            if let folderId = selectedFolderId,
               let folder = folders.first(where: { $0.id == folderId }) {
                FolderDetailView(folder: folder, syncEngine: syncEngine)
            } else {
                ContentUnavailableView(
                    "No Folder Selected",
                    systemImage: "folder",
                    description: Text("Select a folder from the sidebar to view details")
                )
            }
        }
        .onAppear {
            setupNotifications()
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StartBackup"),
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await syncEngine.startBackup()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StopBackup"),
            object: nil,
            queue: .main
        ) { _ in
            syncEngine.stopBackup()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ToggleDryRun"),
            object: nil,
            queue: .main
        ) { _ in
            syncEngine.toggleDryRun()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RescanFolders"),
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await syncEngine.rescanFolders()
            }
        }
    }
}

// MARK: - Folder Row View

struct FolderRowView: View {
    @ObservedObject var folder: SyncFolder
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                
                Text(folder.displayName)
                    .font(.headline)
                
                Spacer()
                
                if folder.syncStatus == .uploading || folder.syncStatus == .chunking || folder.syncStatus == .scanning {
                    ProgressView(value: folder.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                }
            }
            
            Text(folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            HStack {
                Label("\(folder.fileCount) files", systemImage: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if let error = folder.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
    
    private var statusIcon: String {
        switch folder.syncStatus {
        case .pending: return "clock"
        case .scanning: return "magnifyingglass"
        case .chunking: return "archivebox"
        case .uploading: return "arrow.up.circle"
        case .completed: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .paused: return "pause.circle"
        }
    }
    
    private var statusColor: Color {
        switch folder.syncStatus {
        case .pending: return .secondary
        case .scanning, .chunking, .uploading: return .accentColor
        case .completed: return .green
        case .error: return .red
        case .paused: return .orange
        }
    }
}

// MARK: - Folder Detail View

struct FolderDetailView: View {
    @ObservedObject var folder: SyncFolder
    @ObservedObject var syncEngine: SyncEngine
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Status Card
                StatusCard(folder: folder, syncEngine: syncEngine)
                
                // Statistics
                StatisticsSection(folder: folder)
                
                // Topic Info
                if let topic = folder.topicMapping {
                    TopicInfoSection(topic: topic)
                }
                
                // Recent Files
                RecentFilesSection(folder: folder)
                
                // Actions
                ActionButtons(folder: folder, syncEngine: syncEngine)
            }
            .padding()
        }
        .navigationTitle(folder.displayName)
    }
}

struct StatusCard: View {
    @ObservedObject var folder: SyncFolder
    @ObservedObject var syncEngine: SyncEngine
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: statusIcon)
                    .font(.title)
                    .foregroundStyle(statusColor)
                
                VStack(alignment: .leading) {
                    Text(statusText)
                        .font(.headline)
                    Text(folder.syncStatus.rawValue.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if syncEngine.activeFolderId == folder.id && syncEngine.isRunning {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            if folder.syncStatus == .uploading || folder.syncStatus == .chunking {
                ProgressView(value: folder.progress)
                    .progressViewStyle(.linear)
                
                Text("\(Int(folder.progress * 100))% Complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
    
    private var statusIcon: String {
        switch folder.syncStatus {
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .uploading: return "arrow.up.circle.fill"
        case .chunking: return "archivebox.fill"
        case .scanning: return "magnifyingglass.circle.fill"
        case .pending: return "clock.fill"
        case .paused: return "pause.circle.fill"
        }
    }
    
    private var statusColor: Color {
        switch folder.syncStatus {
        case .completed: return .green
        case .error: return .red
        case .uploading, .chunking, .scanning: return .accentColor
        case .pending: return .secondary
        case .paused: return .orange
        }
    }
    
    private var statusText: String {
        if let error = folder.errorMessage {
            return error
        }
        
        switch folder.syncStatus {
        case .completed: return "Backup Complete"
        case .error: return "Error Occurred"
        case .uploading: return "Uploading to Telegram"
        case .chunking: return "Creating Encrypted Chunks"
        case .scanning: return "Scanning Files"
        case .pending: return "Pending Backup"
        case .paused: return "Paused"
        }
    }
}

struct StatisticsSection: View {
    @ObservedObject var folder: SyncFolder
    
    var body: some View {
        Section {
            Text("Statistics")
                .font(.headline)
            
            Grid(horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    StatItem(label: "Total Size", value: ByteCountFormatter.string(fromByteCount: folder.totalBytes, countStyle: .file))
                    StatItem(label: "Files", value: "\(folder.fileCount)")
                }
                
                GridRow {
                    StatItem(label: "Processed", value: ByteCountFormatter.string(fromByteCount: folder.processedBytes, countStyle: .file))
                    StatItem(label: "Progress", value: "\(Int(folder.progress * 100))%")
                }
                
                if let lastSync = folder.lastSyncDate {
                    GridRow {
                        StatItem(label: "Last Sync", value: lastSync.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }
    }
}

struct StatItem: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .monospacedDigit()
        }
    }
}

struct TopicInfoSection: View {
    @ObservedObject var topic: TopicMapping
    
    var body: some View {
        Section {
            Text("Telegram Topic")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Topic Name", systemImage: "text.bubble")
                    Spacer()
                    Text(topic.topicTitle)
                        .foregroundStyle(.secondary)
                }
                
                if topic.topicId != 0 {
                    HStack {
                        Label("Topic ID", systemImage: "number")
                        Spacer()
                        Text("\(topic.topicId)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                
                HStack {
                    Label("Uploaded Chunks", systemImage: "arrow.up.doc")
                    Spacer()
                    Text("\(topic.uploadedChunks) / \(topic.totalChunks)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                
                if topic.isComplete {
                    Label("Sync Complete", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

struct RecentFilesSection: View {
    @Query var fileRecords: [FileRecord]
    
    init(folder: SyncFolder) {
        _fileRecords = Query(filter: #Predicate<FileRecord> { $0.syncFolder?.id == folder.id }, sort: \FileRecord.updatedAt, order: .reverse)
    }
    
    var body: some View {
        Section {
            Text("Recent Files")
                .font(.headline)
            
            if fileRecords.isEmpty {
                Text("No files recorded yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(fileRecords.prefix(5)) { record in
                    HStack {
                        Image(systemName: record.icon)
                            .foregroundStyle(record.statusColor)
                        
                        VStack(alignment: .leading) {
                            Text(record.fileName)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(record.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

extension FileRecord {
    var icon: String {
        switch uploadStatus {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .uploading: return "arrow.up.circle"
        case .chunking: return "archivebox"
        case .pending: return "clock"
        }
    }
    
    var statusColor: Color {
        switch uploadStatus {
        case .completed: return .green
        case .failed: return .red
        case .uploading, .chunking: return .accentColor
        case .pending: return .secondary
        }
    }
}

struct ActionButtons: View {
    @ObservedObject var folder: SyncFolder
    @ObservedObject var syncEngine: SyncEngine
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        Section {
            Text("Actions")
                .font(.headline)
            
            HStack(spacing: 12) {
                Button {
                    folder.syncStatus = .pending
                    try? modelContext.save()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                
                Button {
                    // Remove folder
                    modelContext.delete(folder)
                    try? modelContext.save()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                
                Spacer()
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(minWidth: 1000, minHeight: 700)
}