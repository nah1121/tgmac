import SwiftUI
import SwiftData
import OSLog

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SyncFolder.createdAt, order: .reverse)]) private var folders: [SyncFolder]
    
    @State private var selectedFolder: SyncFolder?
    @State private var showingAddFolder = false
    @StateObject private var settings = AppSettings.shared
    @StateObject private var engine = SyncEngine.shared
    @State private var phoneNumber: String = ""
    @State private var authCode: String = ""
    @State private var authPassword: String = ""
    
    private let logger = Logger(subsystem: "com.backupbot.app", category: "ContentView")
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedFolder) {
                    ForEach(folders) { folder in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(folder.displayName)
                                    .font(.headline)
                                Text(folder.topicName ?? "No topic")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ProgressView(value: folder.progress)
                                .frame(width: 120)
                            statusBadge(for: folder.syncStatus)
                        }
                        .tag(folder)
                    }
                }
                .listStyle(.inset)
                
                HStack {
                    Button {
                        showingAddFolder = true
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                    }
                    Spacer()
                    Button {
                        engine.rescan(folders: folders)
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(folders.isEmpty)
                }
                .padding()
            }
        } detail: {
            if let folder = selectedFolder {
                folderDetail(folder)
            } else {
                Text("Select a folder to view details")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingAddFolder) {
            AddFolderView()
                .environment(\.modelContext, modelContext)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    engine.start(folders: folders, settings: settings)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(folders.isEmpty)
                
                Button {
                    engine.stopAll()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                
                Toggle(isOn: $engine.dryRun) {
                    Label("Dry Run", systemImage: "bolt.horizontal")
                }
            }
        }
    }
    
    private func folderDetail(_ folder: SyncFolder) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.displayName)
                        .font(.title2.weight(.semibold))
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(for: folder.syncStatus)
            }
            
            ProgressView(value: folder.progress) {
                Text("Progress")
            }
            .progressViewStyle(.linear)
            
            HStack {
                Label("Files: \(folder.fileCount)", systemImage: "doc.on.doc")
                Label("Chunk Size: \(folder.chunkSizeMB) MB", systemImage: "square.stack.3d.up")
                Label("Dry Run: \(folder.dryRunEnabled ? "On" : "Off")", systemImage: "bolt.horizontal")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            
            settingsPanel
            
            Spacer()
        }
        .padding()
    }
    
    private var settingsPanel: some View {
        Form {
            Section("Telegram API") {
                TextField("API ID", text: $settings.apiId)
                    .textFieldStyle(.roundedBorder)
                TextField("API Hash", text: $settings.apiHash)
                    .textFieldStyle(.roundedBorder)
                TextField("Forum Chat ID", text: $settings.forumChatId)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Circle()
                        .fill(engine.isAuthenticated ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(engine.isAuthenticated ? "Authenticated" : "Not Authenticated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Encryption") {
                SecureField("Passphrase", text: $settings.passphrase)
                    .textFieldStyle(.roundedBorder)
                Stepper(value: $settings.defaultChunkSizeMB, in: 100...700, step: 50) {
                    Text("Chunk Size: \(settings.defaultChunkSizeMB) MB")
                }
            }
            
            Section("MTProto Login") {
                TextField("Phone Number", text: $phoneNumber)
                    .textFieldStyle(.roundedBorder)
                TextField("Code", text: $authCode)
                    .textFieldStyle(.roundedBorder)
                SecureField("2FA Password (optional)", text: $authPassword)
                    .textFieldStyle(.roundedBorder)
                Button("Authenticate") {
                    engine.authenticate(phone: phoneNumber, code: authCode, password: authPassword.isEmpty ? nil : authPassword)
                }
                .disabled(phoneNumber.isEmpty || authCode.isEmpty)
            }
        }
        .frame(maxHeight: 280)
    }
    
    private func statusBadge(for status: SyncStatus) -> some View {
        let text: String
        let color: Color
        
        switch status {
        case .pending:
            text = "Pending"
            color = .gray
        case .scanning:
            text = "Scanning"
            color = .blue
        case .chunking:
            text = "Chunking"
            color = .orange
        case .uploading:
            text = "Uploading"
            color = .purple
        case .completed:
            text = "Done"
            color = .green
        case .error:
            text = "Error"
            color = .red
        case .paused:
            text = "Paused"
            color = .yellow
        }
        
        return Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.15)))
    }
}
