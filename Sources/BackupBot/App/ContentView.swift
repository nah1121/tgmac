import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncEngineService.self) private var syncEngine

    @Query(filter: #Predicate<SyncFolder> { $0.isActive }, sort: \SyncFolder.createdAt)
    private var activeFolders: [SyncFolder]

    @Query(sort: \SyncFolder.createdAt)
    private var allFolders: [SyncFolder]

    @State private var selectedFolder: SyncFolder?
    @State private var showingAddFolder = false
    @State private var isSyncingAll = false

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationTitle("Backup Folders")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            showingAddFolder = true
                        } label: {
                            Label("Add Folder", systemImage: "plus")
                        }
                        .help("Add a new folder to back up")

                        if !allFolders.isEmpty {
                            Menu {
                                Button {
                                    syncAllFolders()
                                } label: {
                                    Label("Sync All", systemImage: "play.fill")
                                }
                                .disabled(isSyncingAll)

                                Button {
                                    Task { await syncEngine.cancelAll() }
                                } label: {
                                    Label("Stop All", systemImage: "stop.fill")
                                }
                                .disabled(!isSyncingAll)
                            } label: {
                                Label("Sync Actions", systemImage: "ellipsis.circle")
                            }
                        }
                    }
                }
        } detail: {
            detailContent
        }
        .sheet(isPresented: $showingAddFolder) {
            AddFolderView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startBackup)) { _ in
            syncAllFolders()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopBackup)) { _ in
            Task { await syncEngine.cancelAll() }
        }
        .task {
            await SecureBookmark.shared.restoreAllBookmarks()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        if allFolders.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No Folders Yet")
                    .font(.headline)
                Text("Add a folder to start backing up your files to Telegram.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 200)
                Button("Add Folder") {
                    showingAddFolder = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List(allFolders, selection: $selectedFolder) { folder in
                FolderSidebarRow(folder: folder)
                    .tag(folder)
                    .contextMenu {
                        Button(role: .destructive) {
                            removeFolder(folder)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }

                        if folder.isActive {
                            Button {
                                toggleFolderActive(folder, active: false)
                            } label: {
                                Label("Pause", systemImage: "pause")
                            }
                        } else {
                            Button {
                                toggleFolderActive(folder, active: true)
                            } label: {
                                Label("Resume", systemImage: "play")
                            }
                        }
                    }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if let folder = selectedFolder {
            FolderDetailView(folder: folder)
        } else {
            ContentUnavailableView(
                "Select a Folder",
                systemImage: "folder",
                description: Text("Choose a folder from the sidebar to view its backup status and details.")
            )
        }
    }

    // MARK: - Actions

    private func syncAllFolders() {
        guard !activeFolders.isEmpty else { return }
        isSyncingAll = true
        Task {
            await syncEngine.syncAll(folders: activeFolders, modelContext: modelContext)
            isSyncingAll = false
        }
    }

    private func removeFolder(_ folder: SyncFolder) {
        modelContext.delete(folder)
        if selectedFolder?.id == folder.id {
            selectedFolder = nil
        }
    }

    private func toggleFolderActive(_ folder: SyncFolder, active: Bool) {
        folder.isActive = active
        if active && folder.syncStatusRaw != SyncStatus.completed.rawValue {
            folder.syncStatusRaw = SyncStatus.pending.rawValue
        }
    }
}

// MARK: - Sidebar Row

struct FolderSidebarRow: View {
    let folder: SyncFolder

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.syncStatus.systemImage)
                .foregroundStyle(colorForStatus(folder.syncStatus))
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.displayName)
                    .font(.body)
                    .lineLimit(1)

                if folder.syncStatus != .pending && folder.syncStatus != .completed {
                    Text(folder.syncStatus.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if folder.syncStatus == .completed {
                    Text("Up to date")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            if folder.syncStatus == .uploading || folder.syncStatus == .scanning || folder.syncStatus == .chunking {
                ProgressView(value: folder.progress)
                    .controlSize(.small)
                    .frame(width: 40)
                    .help(String(format: "%.0f%%", folder.progress * 100))
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
