import SwiftUI
import SwiftData

/// Upload history viewer with retry and cancel controls.
///
/// Displays a chronological list of all upload operations for a folder,
/// showing chunk details, progress, timing, and error information.
/// Each entry provides contextual actions:
/// - **Failed / Cancelled** uploads: "Retry" button to re-queue the chunk
/// - **Uploading / Pending** uploads: "Cancel" button to abort the operation
/// - **Completed** uploads: read-only with timing and speed statistics
///
/// The view also provides bulk actions: "Retry All Failed" and "Cancel All Active".
struct UploadHistoryViewer: View {
    let folder: SyncFolder

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncEngineService.self) private var syncEngine
    @Environment(MTProtoClientService.self) private var mtprotoClient

    @Query private var uploadRecords: [UploadHistoryRecord]

    @State private var selectedFilter: UploadHistoryFilter = .all
    @State private var searchText = ""
    @State private var sortOrder: UploadHistorySort = .newest
    @State private var selectedRecord: UploadHistoryRecord?
    @State private var showingRetryConfirmation = false
    @State private var recordToRetry: UploadHistoryRecord?

    init(folder: SyncFolder) {
        self.folder = folder
        _uploadRecords = Query(
            filter: #Predicate<UploadHistoryRecord> { $0.folderID == folder.id },
            sort: \UploadHistoryRecord.createdAt
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with stats
            headerBar

            Divider()

            // Filter and sort bar
            filterBar

            Divider()

            // Upload list
            if filteredRecords.isEmpty {
                emptyState
            } else {
                uploadList
            }

            Divider()

            // Bulk action bar
            if hasActiveOrFailed {
                bulkActionBar
            }
        }
        .navigationTitle("Upload History")
        .alert("Retry Upload", isPresented: $showingRetryConfirmation) {
            Button("Retry", role: .none) {
                retryUpload(recordToRetry)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Retry uploading \(recordToRetry?.chunkLabel ?? "this chunk")?")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 20) {
            StatBadge(
                icon: "arrow.up.circle",
                label: "Total",
                value: "\(uploadRecords.count)",
                color: .accentColor
            )
            StatBadge(
                icon: "checkmark.circle.fill",
                label: "Completed",
                value: "\(uploadRecords.filter { $0.status == .completed }.count)",
                color: .green
            )
            StatBadge(
                icon: "exclamationmark.triangle.fill",
                label: "Failed",
                value: "\(uploadRecords.filter { $0.status == .failed }.count)",
                color: .red
            )
            StatBadge(
                icon: "arrow.clockwise.circle",
                label: "Retrying",
                value: "\(uploadRecords.filter { $0.status == .retrying }.count)",
                color: .orange
            )

            Spacer()

            if !uploadRecords.isEmpty {
                let totalBytes = uploadRecords.filter { $0.status == .completed }.reduce(Int64(0)) { $0 + $1.fileSize }
                Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Filter Bar

    @ViewBuilder
    private var filterBar: some View {
        HStack {
            Picker("Filter", selection: $selectedFilter) {
                ForEach(UploadHistoryFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()

            Picker("Sort", selection: $sortOrder) {
                ForEach(UploadHistorySort.allCases) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Upload List

    @ViewBuilder
    private var uploadList: some View {
        List(filteredRecords, selection: $selectedRecord) { record in
            UploadHistoryRow(record: record)
                .contextMenu {
                    if record.canRetry {
                        Button {
                            recordToRetry = record
                            showingRetryConfirmation = true
                        } label: {
                            Label("Retry Upload", systemImage: "arrow.clockwise")
                        }
                    }
                    if record.canCancel {
                        Button(role: .destructive) {
                            cancelUpload(record)
                        } label: {
                            Label("Cancel Upload", systemImage: "xmark.circle")
                        }
                    }
                    if record.status == .completed {
                        Button {
                            copyMessageID(record)
                        } label: {
                            Label("Copy Message ID", systemImage: "doc.on.doc")
                        }
                    }
                }
        }
        .listStyle(.inset)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            "No Upload History",
            systemImage: "clock.arrow.circlepath",
            description: Text(selectedFilter == .all
                ? "Upload history will appear here once you start backing up this folder."
                : "No \(selectedFilter.displayName.lowercased()) uploads found."
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bulk Action Bar

    @ViewBuilder
    private var bulkActionBar: some View {
        HStack {
            if hasFailedRecords {
                Button {
                    retryAllFailed()
                } label: {
                    Label("Retry All Failed", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            Spacer()

            if hasActiveRecords {
                Button(role: .destructive) {
                    cancelAllActive()
                } label: {
                    Label("Cancel All Active", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Computed Properties

    private var filteredRecords: [UploadHistoryRecord] {
        var result = uploadRecords

        // Apply filter
        switch selectedFilter {
        case .all: break
        case .active:
            result = result.filter { [.pending, .uploading, .retrying].contains($0.status) }
        case .completed:
            result = result.filter { $0.status == .completed }
        case .failed:
            result = result.filter { $0.status == .failed }
        case .cancelled:
            result = result.filter { $0.status == .cancelled }
        }

        // Apply search
        if !searchText.isEmpty {
            result = result.filter {
                $0.chunkLabel.localizedCaseInsensitiveContains(searchText) ||
                $0.fileName.localizedCaseInsensitiveContains(searchText) ||
                ($0.errorMessage?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        // Apply sort
        switch sortOrder {
        case .newest:
            result.sort { $0.createdAt > $1.createdAt }
        case .oldest:
            result.sort { $0.createdAt < $1.createdAt }
        case .sizeLargest:
            result.sort { $0.fileSize > $1.fileSize }
        case .status:
            result.sort { $0.statusRaw < $1.statusRaw }
        }

        return result
    }

    private var hasFailedRecords: Bool {
        uploadRecords.contains { $0.status == .failed }
    }

    private var hasActiveRecords: Bool {
        uploadRecords.contains { [.pending, .uploading, .retrying].contains($0.status) }
    }

    private var hasActiveOrFailed: Bool {
        hasFailedRecords || hasActiveRecords
    }

    // MARK: - Actions

    private func retryUpload(_ record: UploadHistoryRecord?) {
        guard let record else { return }
        record.markRetrying()

        // Re-trigger the sync for this specific chunk
        Task {
            do {
                try await syncEngine.sync(folder: folder, modelContext: modelContext)
            } catch {
                // Error will be recorded in the upload history automatically
            }
        }

        try? modelContext.save()
    }

    private func cancelUpload(_ record: UploadHistoryRecord) {
        record.markCancelled()

        // Cancel the specific upload in the MTProto client
        mtprotoClient.cancelUpload(fileId: record.id)

        try? modelContext.save()
    }

    private func retryAllFailed() {
        let failedRecords = uploadRecords.filter { $0.status == .failed || $0.status == .cancelled }
        for record in failedRecords {
            record.markRetrying()
        }
        try? modelContext.save()

        // Re-trigger the sync
        Task {
            try? await syncEngine.sync(folder: folder, modelContext: modelContext)
        }
    }

    private func cancelAllActive() {
        let activeRecords = uploadRecords.filter { [.pending, .uploading, .retrying].contains($0.status) }
        for record in activeRecords {
            record.markCancelled()
        }
        mtprotoClient.cancelAllUploads()
        syncEngine.cancelSync(folderId: folder.id)
        try? modelContext.save()
    }

    private func copyMessageID(_ record: UploadHistoryRecord) {
        if let messageID = record.telegramMessageID {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(messageID), forType: .string)
        }
    }
}

// MARK: - Upload History Row

/// A single row in the upload history list displaying chunk details and controls.
struct UploadHistoryRow: View {
    let record: UploadHistoryRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Status icon
            Image(systemName: record.status.systemImage)
                .foregroundStyle(colorForStatus(record.status))
                .font(.title3)
                .frame(width: 24, alignment: .center)

            // Content
            VStack(alignment: .leading, spacing: 6) {
                // Top row: chunk label and status badge
                HStack {
                    Text(record.chunkLabel)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()

                    // Status badge
                    Text(record.status.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(colorForStatus(record.status).opacity(0.12))
                        .foregroundStyle(colorForStatus(record.status))
                        .clipShape(Capsule())
                }

                // File name and size
                HStack(spacing: 8) {
                    Text(record.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(record.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                // Progress bar (for active uploads)
                if record.status == .uploading || record.status == .retrying {
                    ProgressView(value: record.progress)
                        .tint(colorForStatus(record.status))

                    HStack(spacing: 16) {
                        Text("\(Int(record.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        Text(ByteCountFormatter.string(fromByteCount: record.bytesUploaded, countStyle: .file) +
                             " / " +
                             ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                // Timing info (for completed uploads)
                if record.status == .completed {
                    HStack(spacing: 16) {
                        if let duration = record.formattedDuration {
                            Label(duration, systemImage: "clock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let speed = record.formattedSpeed {
                            Label(speed, systemImage: "speedometer")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Error info (for failed uploads)
                if let error = record.errorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                // Retry info
                if record.retryCount > 0 {
                    Text("Retry \(record.retryCount)/\(record.maxRetries)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            // Action buttons
            VStack(spacing: 6) {
                if record.canRetry {
                    Button {
                        // Handled by context menu or parent
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                    .help("Retry this upload")
                }

                if record.canCancel {
                    Button {
                        // Handled by context menu or parent
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel this upload")
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func colorForStatus(_ status: UploadStatus) -> Color {
        switch status {
        case .pending:   return .secondary
        case .uploading: return .cyan
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .gray
        case .retrying:  return .orange
        }
    }
}

// MARK: - Stat Badge

private struct StatBadge: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Filter Options

enum UploadHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed
    case failed
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:       "All"
        case .active:    "Active"
        case .completed: "Done"
        case .failed:    "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

// MARK: - Sort Options

enum UploadHistorySort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case sizeLargest
    case status

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newest:      "Newest"
        case .oldest:      "Oldest"
        case .sizeLargest: "Largest"
        case .status:      "Status"
        }
    }
}
