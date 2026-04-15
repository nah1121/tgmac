import SwiftUI

struct GeneralSettingsView: View {
    @Environment(ChunkerService.self) private var chunker

    // MARK: - AppStorage Keys

    @AppStorage("defaultChunkSize") private var chunkSizeRaw: String = "512"
    @AppStorage("dryRun") private var isDryRun = false
    @AppStorage("autoStartSync") private var autoStartSync = false
    @AppStorage("notifyOnComplete") private var notifyOnComplete = true
    @AppStorage("notifyOnError") private var notifyOnError = true

    // MARK: - UI State

    @State private var cacheSize: Int64 = 0
    @State private var isCalculatingCacheSize = false
    @State private var isClearingCache = false
    @State private var showCacheClearedAlert = false
    @State private var cacheClearError: String?

    var body: some View {
        Form {
            chunkSizeSection
            syncBehaviorSection
            notificationSection
            cacheManagementSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await refreshCacheSize()
        }
        .alert("Cache Cleared", isPresented: $showCacheClearedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Chunk cache has been cleared successfully.")
        }
    }

    // MARK: - Chunk Size Section

    @ViewBuilder
    private var chunkSizeSection: some View {
        Section {
            Picker("Default Chunk Size", selection: $chunkSizeRaw) {
                Text("500 MB").tag("500")
                Text("512 MB").tag("512")
                Text("700 MB").tag("700")
                Text("1000 MB (1 GB)").tag("1000")
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Default chunk size for file splitting")
            .help("Larger chunks upload faster but use more memory during processing.")
        } header: {
            Label("Chunk Size", systemImage: "cube")
        } footer: {
            Text("Files larger than the chunk size will be split into multiple encrypted parts before uploading to Telegram.")
        }
    }

    // MARK: - Sync Behavior Section

    @ViewBuilder
    private var syncBehaviorSection: some View {
        Section {
            Toggle(isOn: $isDryRun) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dry Run Mode")
                        .fontWeight(.medium)
                    Text("Scan and chunk files without uploading to Telegram.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Dry run mode toggle")
            .accessibilityHint("When enabled, files are scanned and chunked but not uploaded")

            Toggle(isOn: $autoStartSync) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Start Sync")
                        .fontWeight(.medium)
                    Text("Automatically start syncing when the app launches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Auto-start sync on launch")
        } header: {
            Label("Sync Behavior", systemImage: "arrow.triangle.2.circlepath")
        }
    }

    // MARK: - Notification Section

    @ViewBuilder
    private var notificationSection: some View {
        Section {
            Toggle(isOn: $notifyOnComplete) {
                Label("Sync Completed", systemImage: "checkmark.circle")
            }
            .accessibilityLabel("Notify when sync completes")

            Toggle(isOn: $notifyOnError) {
                Label("Sync Errors", systemImage: "exclamationmark.triangle")
            }
            .accessibilityLabel("Notify on sync errors")
        } header: {
            Label("Notifications", systemImage: "bell")
        } footer: {
            Text("Notifications are delivered via the system notification center.")
        }
    }

    // MARK: - Cache Management Section

    @ViewBuilder
    private var cacheManagementSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cache Size")
                        .fontWeight(.medium)
                    if isCalculatingCacheSize {
                        Text("Calculating...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    clearCache()
                } label: {
                    HStack(spacing: 4) {
                        if isClearingCache {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isClearingCache ? "Clearing..." : "Clear Cache")
                    }
                }
                .disabled(isClearingCache || cacheSize == 0)
                .alert("Cache Clear Error", isPresented: Binding(
                    get: { cacheClearError != nil },
                    set: { if !$0 { cacheClearError = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(cacheClearError ?? "")
                }
            }
        } header: {
            Label("Cache Management", systemImage: "internaldrive")
        } footer: {
            Text("The chunk cache stores encrypted file parts temporarily during processing. Clearing it will free disk space but will require re-chunking files on the next sync.")
        }
    }

    // MARK: - Actions

    private func refreshCacheSize() async {
        isCalculatingCacheSize = true
        cacheSize = await chunker.cacheSize()
        isCalculatingCacheSize = false
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            do {
                try await chunker.clearCache()
                await refreshCacheSize()
                showCacheClearedAlert = true
            } catch {
                await MainActor.run {
                    cacheClearError = "Failed to clear cache: \(error.localizedDescription)"
                }
            }
            isClearingCache = false
        }
    }
}
