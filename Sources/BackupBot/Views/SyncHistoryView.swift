import SwiftUI
import SwiftData

struct SyncHistoryView: View {
    let folder: SyncFolder?

    @Query(sort: \SyncFolder.createdAt, order: .reverse)
    private var allFolders: [SyncFolder]

    @State private var selectedFilter: HistoryFilter = .all
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Filter Bar
            filterBar

            Divider()

            // History List
            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No Sync History",
                    systemImage: "clock",
                    description: Text(selectedFilter == .all
                        ? "Sync history will appear here once you start backing up folders."
                        : "No \(selectedFilter.displayName.lowercased()) syncs found."
                    )
                )
            } else {
                List(filteredEntries) { entry in
                    SyncHistoryRow(entry: entry)
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Filter Bar

    @ViewBuilder
    private var filterBar: some View {
        HStack {
            Picker("Filter", selection: $selectedFilter) {
                ForEach(HistoryFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()

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
    }

    // MARK: - Computed Properties

    /// Estimate processed bytes from chunk progress.
    private func processedBytes(for folder: SyncFolder) -> Int64 {
        guard folder.totalSize > 0 else { return 0 }
        let ratio = folder.totalChunks > 0 ? Double(folder.uploadedChunks) / Double(folder.totalChunks) : folder.progress
        return Int64(Double(folder.totalSize) * ratio)
    }

    private var filteredEntries: [SyncHistoryEntry] {
        let folders = folder.map { [$0] } ?? allFolders
        var entries: [SyncHistoryEntry] = []

        for folder in folders {
            let entry = SyncHistoryEntry(
                folderID: folder.id,
                folderName: folder.displayName,
                status: folder.syncStatus,
                totalBytes: folder.totalSize,
                processedBytes: processedBytes(for: folder),
                errorMessage: folder.lastError,
                topicName: folder.topicMapping?.topicTitle,
                timestamp: folder.createdAt
            )

            // Apply filter
            switch selectedFilter {
            case .all:
                entries.append(entry)
            case .completed:
                if entry.status == .completed {
                    entries.append(entry)
                }
            case .failed:
                if entry.status == .error {
                    entries.append(entry)
                }
            case .inProgress:
                if [.scanning, .chunking, .uploading].contains(entry.status) {
                    entries.append(entry)
                }
            }

            // Apply search
            if !searchText.isEmpty {
                entries = entries.filter { entry in
                    entry.folderName.localizedCaseInsensitiveContains(searchText) ||
                    (entry.topicName?.localizedCaseInsensitiveContains(searchText) ?? false)
                }
            }
        }

        return entries.sorted { $0.timestamp > $1.timestamp }
    }
}

// MARK: - History Entry Model

struct SyncHistoryEntry: Identifiable {
    let id: UUID
    let folderID: UUID
    let folderName: String
    let status: SyncStatus
    let totalBytes: Int64
    let processedBytes: Int64
    let errorMessage: String?
    let topicName: String?
    let timestamp: Date

    init(
        folderID: UUID,
        folderName: String,
        status: SyncStatus,
        totalBytes: Int64,
        processedBytes: Int64,
        errorMessage: String?,
        topicName: String?,
        timestamp: Date
    ) {
        self.id = folderID
        self.folderID = folderID
        self.folderName = folderName
        self.status = status
        self.totalBytes = totalBytes
        self.processedBytes = processedBytes
        self.errorMessage = errorMessage
        self.topicName = topicName
        self.timestamp = timestamp
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(processedBytes) / Double(totalBytes)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

// MARK: - History Row

struct SyncHistoryRow: View {
    let entry: SyncHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: folder name and status
            HStack {
                Image(systemName: entry.status.systemImage)
                    .foregroundStyle(colorForStatus(entry.status))
                    .font(.callout)

                Text(entry.folderName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                Text(entry.status.displayName)
                    .font(.caption)
                    .foregroundStyle(colorForStatus(entry.status))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(colorForStatus(entry.status).opacity(0.12), in: Capsule())
            }

            // Middle row: bytes and progress
            HStack(spacing: 16) {
                Text(entry.formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(ByteCountFormatter.string(fromByteCount: entry.processedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: entry.totalBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if entry.totalBytes > 0 {
                    Text(String(format: "%.0f%%", entry.progress * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            // Progress bar for in-progress entries
            if [.scanning, .chunking, .uploading].contains(entry.status) && entry.totalBytes > 0 {
                ProgressView(value: entry.progress)
                    .tint(colorForStatus(entry.status))
            }

            // Error message
            if let error = entry.errorMessage {
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

            // Topic name
            if let topic = entry.topicName {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                    Text(topic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func colorForStatus(_ status: SyncStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .scanning: return .blue
        case .chunking: return .orange
        case .uploading: return .green
        case .completed: return .green
        case .error: return .red
        case .paused: return .yellow
        }
    }
}

// MARK: - History Filter

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case inProgress
    case completed
    case failed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}
