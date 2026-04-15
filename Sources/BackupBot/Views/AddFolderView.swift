import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct AddFolderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Folder selection state
    @State private var selectedURL: URL?
    @State private var folderPath: String = ""
    @State private var displayName: String = ""
    @State private var topicName: String = ""

    // Computed folder stats
    @State private var folderStats: FolderStats?
    @State private var isCalculatingStats = false

    // Validation state
    @State private var validationError: String?
    @State private var isSaving = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    // Bookmark data
    @State private var bookmarkData: Data?

    private let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.accent)
                Text("Add Backup Folder")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Form
            Form {
                Section {
                    folderPickerRow

                    TextField("Display Name", text: $displayName)
                        .accessibilityLabel("Display name for the backup folder")

                    TextField("Topic Name", text: $topicName)
                        .accessibilityLabel("Telegram topic name for this backup")
                        .help("This will be the topic title in your Telegram forum chat")
                } header: {
                    Text("Folder Information")
                } footer: {
                    Text("The display name is used in the sidebar. The topic name will be created in your Telegram forum chat.")
                }

                if let stats = folderStats {
                    Section {
                        HStack {
                            Label("Total Size", systemImage: "externaldrive")
                            Spacer()
                            Text(stats.formattedSize)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Label("File Count", systemImage: "doc")
                            Spacer()
                            Text(stats.formattedFileCount)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Label("Subfolders", systemImage: "folder")
                            Spacer()
                            Text(stats.formattedFolderCount)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Folder Statistics")
                    }
                }

                if isCalculatingStats {
                    Section {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Calculating folder statistics...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal)

            // Error display
            if let error = validationError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Folder", systemImage: "plus") {
                    saveFolder()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormValid || isSaving)
                .overlay {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
            .padding()
        }
        .frame(width: 520, height: 480)
        .alert("Error", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Computed Properties

    private var isFormValid: Bool {
        !folderPath.isEmpty && !displayName.isEmpty && !topicName.isEmpty && bookmarkData != nil
    }

    // MARK: - Subviews

    @ViewBuilder
    private var folderPickerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: folderPath.isEmpty ? "folder" : "folder.fill")
                .font(.title3)
                .foregroundStyle(folderPath.isEmpty ? .secondary : .accent)

            VStack(alignment: .leading, spacing: 2) {
                if folderPath.isEmpty {
                    Text("No folder selected")
                        .foregroundStyle(.secondary)
                } else {
                    Text(URL(fileURLWithPath: folderPath).lastPathComponent)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(folderPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button("Choose...") {
                chooseFolder()
            }
            .help("Select a folder to back up")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected folder path")
    }

    // MARK: - Folder Selection

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Folder to Back Up"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        panel.directoryURL = defaultDirectory

        if panel.runModal() == .OK, let url = panel.url {
            processSelectedURL(url)
        }
    }

    private func processSelectedURL(_ url: URL) {
        // Start security-scoped access
        let accessing = url.startAccessingSecurityScopedResource()

        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            validationError = "Cannot read the selected folder. Please check permissions."
            folderStats = nil
            return
        }

        validationError = nil

        // Create secure bookmark
        do {
            bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            validationError = "Failed to create bookmark for the selected folder: \(error.localizedDescription)"
            return
        }

        folderPath = url.path
        displayName = generateDisplayName(from: url)
        topicName = generateTopicName(from: url)

        // Calculate stats on background thread
        calculateFolderStats(at: url)
    }

    // MARK: - Name Generation

    private func generateDisplayName(from url: URL) -> String {
        let folderName = url.lastPathComponent
        return folderName
    }

    private func generateTopicName(from url: URL) -> String {
        let folderName = url.lastPathComponent
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Sanitize: replace spaces with underscores, remove special chars
        let sanitized = folderName
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            .trimmingCharacters(in: .init(charactersIn: "_-"))

        let date = dateFormatter.string(from: Date())
        return "\(sanitized)_\(date)"
    }

    // MARK: - Folder Statistics

    private func calculateFolderStats(at url: URL) {
        isCalculatingStats = true
        folderStats = nil

        Task.detached(priority: .userInitiated) {
            let stats = await Self.computeStats(at: url)

            await MainActor.run {
                folderStats = stats
                isCalculatingStats = false
            }
        }
    }

    private static func computeStats(at url: URL) async -> FolderStats {
        var totalSize: Int64 = 0
        var fileCount: Int = 0
        var folderCount: Int = 0
        let fileManager = FileManager.default

        func enumerate(directory: URL) {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for case let itemURL as URL in enumerator {
                do {
                    let resourceValues = try itemURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if resourceValues.isDirectory == true {
                        folderCount += 1
                    } else {
                        totalSize += Int64(resourceValues.fileSize ?? 0)
                        fileCount += 1
                    }
                } catch {
                    // Skip files we can't read
                    continue
                }
            }
        }

        enumerate(directory: url)

        return FolderStats(
            totalSize: totalSize,
            fileCount: fileCount,
            folderCount: folderCount
        )
    }

    // MARK: - Save

    private func saveFolder() {
        guard bookmarkData != nil else { return }
        isSaving = true

        do {
            let folder = SyncFolder(
                path: folderPath,
                bookmarkData: bookmarkData!,
                displayName: displayName,
                totalSize: folderStats?.totalSize ?? 0
            )

            let topicMapping = TopicMapping(
                topicId: 0,
                topicTitle: topicName
            )
            folder.topicMapping = topicMapping

            modelContext.insert(folder)
            try modelContext.save()

            // Store secure bookmark keyed by folder ID
            SecureBookmark.shared.storeBookmark(id: folder.id, data: bookmarkData!)

            dismiss()
        } catch {
            alertMessage = "Failed to save folder: \(error.localizedDescription)"
            showAlert = true
            isSaving = false
        }
    }
}

// MARK: - Folder Statistics Model

private struct FolderStats {
    let totalSize: Int64
    let fileCount: Int
    let folderCount: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var formattedFileCount: String {
        NumberFormatter.localizedString(from: NSNumber(value: fileCount), number: .decimal)
    }

    var formattedFolderCount: String {
        NumberFormatter.localizedString(from: NSNumber(value: folderCount), number: .decimal)
    }
}
