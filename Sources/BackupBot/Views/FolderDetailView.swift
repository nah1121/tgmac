import SwiftUI
import SwiftData

struct FolderDetailView: View {
    let folder: SyncFolder

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncEngineService.self) private var syncEngine
    @Environment(ChunkerService.self) private var chunker

    @Query private var fileRecords: [FileRecord]
    @AppStorage("dryRun") private var isDryRun = false
    @AppStorage("defaultChunkSize") private var chunkSizeRaw: String = "512"

    @State private var syncStatus: FolderSyncStatus?
    @State private var isExpanded: Bool = true
    @State private var showingRemoveConfirmation = false
    @State private var errorMessage: String?
    @State private var showingError = false

    @State private var showingUploadHistory = false

    init(folder: SyncFolder) {
        self.folder = folder
        _fileRecords = Query(
            filter: #Predicate<FileRecord> { $0.syncFolder?.id == folder.id },
            sort: \FileRecord.fileName
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header Section
                headerSection

                // Status & Progress Section
                statusSection

                // Topic Mapping Section
                if let topic = folder.topicMapping {
                    topicSection(topic)
                }

                // Action Buttons
                actionButtons

                // Files List
                filesSection
            }
            .padding(20)
        }
        .navigationTitle(folder.displayName)
        .task {
            // Poll sync status
            await pollSyncStatus()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            Task { await pollSyncStatus() }
        }
        .alert("Error", isPresented: $showingError) {
            Button("Dismiss", role: .cancel) {}
            if let status = syncStatus, let _ = status.errorMessage {
                Button("Retry") {
                    retrySync()
                }
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .confirmationDialog(
            "Remove Folder",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                removeFolder()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to remove \"\(folder.displayName)\"? This will not delete your files, but the backup configuration will be removed.")
        }
    }

    // MARK: - Header Section

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.title)
                    .foregroundStyle(.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 24) {
                StatItem(
                    icon: "externaldrive",
                    label: "Total Size",
                    value: ByteCountFormatter.string(fromByteCount: folder.totalSize, countStyle: .file)
                )
                StatItem(
                    icon: "doc.text",
                    label: "Files",
                    value: "\(fileRecords.count)"
                )
                StatItem(
                    icon: "arrow.up.arrow.down",
                    label: "Processed",
                    value: ByteCountFormatter.string(fromByteCount: processedBytesEstimate, countStyle: .file)
                )
            }
            .padding(.top, 4)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusIcon
                Text(currentStatusText)
                    .fontWeight(.semibold)
                Spacer()

                if let status = syncStatus {
                    Text(status.currentPhase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }

            ProgressView(value: progressValue) {
                EmptyView()
            } currentValueLabel: {
                Text(String(format: "%.1f%%", progressValue * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tint(progressTint)

            if let status = syncStatus {
                HStack(spacing: 16) {
                    if status.chunksTotal > 0 {
                        Label(
                            "Chunks: \(status.chunksCompleted)/\(status.chunksTotal)",
                            systemImage: "cube"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if status.isDryRun {
                        Label("Dry Run", systemImage: "eye")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusIcon: some View {
        let status = folder.syncStatus
        Image(systemName: status.systemImage)
            .foregroundStyle(Color(hex: status.tintColor))
            .font(.title3)
    }

    private var currentStatusText: String {
        if let status = syncStatus {
            return status.status.displayName
        }
        return folder.syncStatus.displayName
    }

    private var progressValue: Double {
        if let status = syncStatus {
            return status.progress
        }
        return folder.progress
    }

    private var progressTint: Color {
        switch folder.syncStatus {
        case .pending: return .secondary
        case .scanning: return .blue
        case .chunking: return .orange
        case .uploading: return .green
        case .completed: return .green
        case .error: return .red
        case .paused: return .yellow
        }
    }

    // MARK: - Topic Section

    @ViewBuilder
    private func topicSection(_ topic: TopicMapping) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.accent)
                Text("Telegram Topic")
                    .fontWeight(.semibold)
                Spacer()

                if topic.isComplete {
                    Label("Complete", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if topic.isActive {
                    Label("Active", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            HStack {
                Text("Topic:")
                    .foregroundStyle(.secondary)
                Text(topic.topicTitle)
            }
            .font(.caption)

            if topic.totalChunks > 0 {
                HStack {
                    Text("Progress:")
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(topic.uploadedChunks) / Double(topic.totalChunks))
                        .frame(width: 100)
                    Text("\(topic.uploadedChunks)/\(topic.totalChunks)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            if let lastError = topic.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(lastError)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            switch folder.syncStatus {
            case .pending, .completed, .error, .paused:
                Button {
                    startSync()
                } label: {
                    Label("Start Sync", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Start backing up this folder")

            case .scanning, .chunking, .uploading:
                Button {
                    stopSync()
                } label: {
                    Label("Stop Sync", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Stop the current sync")
            }

            Button {
                rescanFolder()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Re-scan folder for file changes")

                // Upload History
                NavigationLink {
                    UploadHistoryViewer(folder: folder)
                } label: {
                    Label("Upload History", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .help("View upload history with retry/cancel controls")

                Spacer()

                Button(role: .destructive) {
                    showingRemoveConfirmation = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            .help("Remove this folder from backup list")
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Files Section

    @ViewBuilder
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Files")
                    .font(.headline)
                Spacer()
                Text("\(fileRecords.count) file\(fileRecords.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }

            if fileRecords.isEmpty {
                ContentUnavailableView(
                    "No Files Scanned",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Start a sync to scan and process files in this folder.")
                )
                .frame(height: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(fileRecords) { file in
                            FileRowView(file: file)
                            if file.id != fileRecords.last?.id {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func startSync() {
        Task {
            do {
                try await syncEngine.sync(folder: folder, modelContext: modelContext)
            } catch {
                await MainActor.run {
                    errorMessage = "Sync failed: \(error.localizedDescription)"
                    showingError = true
                }
            }
        }
    }

    private func stopSync() {
        Task {
            await syncEngine.cancelSync(folderId: folder.id)
        }
    }

    private func rescanFolder() {
        folder.syncStatusRaw = SyncStatus.pending.rawValue
        folder.uploadedChunks = 0
    }

    private func retrySync() {
        folder.syncStatusRaw = SyncStatus.pending.rawValue
        folder.lastError = nil
        startSync()
    }

    private func removeFolder() {
        modelContext.delete(folder)
    }

    /// Estimated processed bytes based on upload progress ratio.
    private var processedBytesEstimate: Int64 {
        guard folder.totalSize > 0 else { return 0 }
        let ratio = folder.totalChunks > 0 ? Double(folder.uploadedChunks) / Double(folder.totalChunks) : folder.progress
        return Int64(Double(folder.totalSize) * ratio)
    }

    private func pollSyncStatus() async {
        if let status = await syncEngine.getStatus(for: folder.id) {
            syncStatus = status
        }
    }
}

// MARK: - Stat Item

private struct StatItem: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
    }
}

// MARK: - File Row View

struct FileRowView: View {
    let file: FileRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconForStatus(file.syncStatus))
                .foregroundStyle(colorForStatus(file.syncStatus))
                .font(.callout)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.body)
                    .lineLimit(1)
                Text(file.filePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(file.formattedSize)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.fileName), \(file.formattedSize), \(file.syncStatus.displayName)")
    }

    private func iconForStatus(_ status: FileSyncStatus) -> String {
        switch status {
        case .pending: return "circle.dashed"
        case .included: return "checkmark.circle.fill"
        case .skipped: return "forward.circle"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    private func colorForStatus(_ status: FileSyncStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .included: return .green
        case .skipped: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Color Hex Helper

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b, a: Double
        switch cleaned.count {
        case 6:
            (r, g, b, a) = (
                Double((int >> 16) & 0xFF) / 255,
                Double((int >> 8) & 0xFF) / 255,
                Double(int & 0xFF) / 255,
                1
            )
        case 8:
            (r, g, b, a) = (
                Double((int >> 24) & 0xFF) / 255,
                Double((int >> 16) & 0xFF) / 255,
                Double((int >> 8) & 0xFF) / 255,
                Double(int & 0xFF) / 255
            )
        default:
            (r, g, b, a) = (0, 0, 0, 1)
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
