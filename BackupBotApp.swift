import SwiftUI
import SwiftData
import OSLog

@main
struct BackupBotApp: App {
    private let logger = Logger(subsystem: "com.backupbot.app", category: "AppLifecycle")
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        SecureBookmark.shared.restoreAllBookmarks()
        logger.info("BackupBotApp initialized, restored secure bookmarks")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 700)
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    if newPhase == .background {
                        SecureBookmark.shared.saveAllBookmarks()
                        logger.debug("App entering background, saved secure bookmarks")
                    }
                }
        }
        .modelContainer(for: [SyncFolder.self, FileRecord.self, TopicMapping.self])
        .commands {
            CommandMenu("Backup") {
                Button("Start Backup") {
                    NotificationCenter.default.post(name: .init("StartBackup"), object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                
                Button("Stop Backup") {
                    NotificationCenter.default.post(name: .init("StopBackup"), object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command])
                
                Divider()
                
                Button("Toggle Dry Run") {
                    NotificationCenter.default.post(name: .init("ToggleDryRun"), object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                
                Divider()
                
                Button("Rescan Folders") {
                    NotificationCenter.default.post(name: .init("RescanFolders"), object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            
            CommandGroup(replacing: .appInfo) {
                Button("About Backup Bot") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: "Telegram Samsung Backup Bot\nVersion 1.0\n\nLocal-first backup utility for Samsung Smart Switch backups",
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 11),
                                    .foregroundColor: NSColor.secondaryLabelColor
                                ]
                            )
                        ]
                    )
                }
            }
        }
        
        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            TelegramSettingsView()
                .tabItem {
                    Label("Telegram", systemImage: "paperplane.fill")
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("chunkSize") private var chunkSize: Int = 700 // MB
    @AppStorage("autoStartOnLaunch") private var autoStartOnLaunch: Bool = false
    @AppStorage("showNotifications") private var showNotifications: Bool = true
    
    var body: some View {
        Form {
            Section("Chunking") {
                Picker("Max Chunk Size", selection: $chunkSize) {
                    Text("500 MB").tag(500)
                    Text("700 MB").tag(700)
                    Text("1 GB").tag(1024)
                    Text("1.5 GB").tag(1536)
                }
                .help("Maximum size for each encrypted chunk uploaded to Telegram")
            }
            
            Section("Startup") {
                Toggle("Auto-start backup on launch", isOn: $autoStartOnLaunch)
                    .help("Automatically start backing up when the app launches")
            }
            
            Section("Notifications") {
                Toggle("Show notifications", isOn: $showNotifications)
                    .help("Show notifications for backup completion and errors")
            }
            
            Section("About") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Backup Bot v1.0")
                        .font(.headline)
                    Text("Local-first backup utility for Samsung Smart Switch backups to Telegram.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Encrypted chunks are uploaded to your private Telegram forum for secure cloud storage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct TelegramSettingsView: View {
    @StateObject private var mtProtoClient = MTProtoClient()
    @AppStorage("telegram.apiId") private var apiId: Int32 = 0
    @AppStorage("telegram.apiHash") private var apiHash: String = ""
    @AppStorage("telegram.forumChatId") private var forumChatId: Int64 = 0
    @AppStorage("telegram.phoneNumber") private var phoneNumber: String = ""
    
    @State private var showingAuthSheet: Bool = false
    @State private var verificationCode: String = ""
    @State private var twoFAPassword: String = ""
    @State private var authError: String?
    @State private var isTesting: Bool = false
    @State private var testResult: Bool?
    
    var body: some View {
        Form {
            Section("API Credentials") {
                TextField("API ID", value: $apiId, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .help("Get from https://my.telegram.org/apps")
                
                SecureField("API Hash", text: $apiHash)
                    .textFieldStyle(.roundedBorder)
                    .help("Get from https://my.telegram.org/apps")
                
                TextField("Forum Chat ID", value: $forumChatId, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .help("The ID of your Telegram forum (use @userinfobot to find)")
            }
            
            Section("Authentication") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Status: \(authStatusText)")
                            .font(.body)
                        if let error = authError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    
                    Spacer()
                    
                    Button(authButtonLabel) {
                        if mtProtoClient.authState == .authorized {
                            mtProtoClient.clearSession()
                        } else {
                            showingAuthSheet = true
                        }
                    }
                    .disabled(!canAuthenticate)
                }
                
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(apiId == 0 || apiHash.isEmpty || forumChatId == 0)
                
                if isTesting {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Testing connection...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let result = testResult {
                    Label(result ? "Connection successful" : "Connection failed",
                          systemImage: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                }
            }
            
            Section("Phone Number") {
                TextField("Phone Number (with country code)", text: $phoneNumber)
                    .textFieldStyle(.roundedBorder)
                    .help("Example: +1234567890")
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingAuthSheet) {
            AuthSheetView(
                client: mtProtoClient,
                phoneNumber: $phoneNumber,
                verificationCode: $verificationCode,
                twoFAPassword: $twoFAPassword,
                authError: $authError,
                onDismiss: {
                    showingAuthSheet = false
                }
            )
        }
    }
    
    private var authStatusText: String {
        switch mtProtoClient.authState {
        case .unauthorized:
            return "Not authenticated"
        case .awaitingCode:
            return "Waiting for verification code"
        case .awaitingPassword:
            return "Waiting for 2FA password"
        case .authorized:
            return "Authenticated ✓"
        }
    }
    
    private var authButtonLabel: String {
        mtProtoClient.authState == .authorized ? "Logout" : "Authenticate"
    }
    
    private var canAuthenticate: Bool {
        apiId != 0 && !apiHash.isEmpty && forumChatId != 0 && !phoneNumber.isEmpty
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        Task {
            do {
                let success = try await mtProtoClient.testConnection()
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = success
                }
            } catch {
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = false
                    self.authError = error.localizedDescription
                }
            }
        }
    }
}

struct AuthSheetView: View {
    @ObservedObject var client: MTProtoClient
    @Binding var phoneNumber: String
    @Binding var verificationCode: String
    @Binding var twoFAPassword: String
    @Binding var authError: String?
    var onDismiss: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                switch client.authState {
                case .unauthorized:
                    Section("Step 1: Phone Number") {
                        TextField("Phone Number", text: $phoneNumber)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.phonePad)
                        
                        Text("Enter your phone number with country code (e.g., +1234567890)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                case .awaitingCode:
                    Section("Step 2: Verification Code") {
                        TextField("Code", text: $verificationCode)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        
                        Text("Enter the verification code sent to your Telegram app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                case .awaitingPassword:
                    Section("Step 3: Two-Factor Authentication") {
                        SecureField("2FA Password", text: $twoFAPassword)
                            .textFieldStyle(.roundedBorder)
                        
                        Text("Enter your cloud password if you have 2FA enabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                case .authorized:
                    Section {
                        Label("Successfully authenticated!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                
                if let error = authError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Telegram Authentication")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionButtonLabel) {
                        Task {
                            await handleAuthAction()
                        }
                    }
                    .disabled(!canProceed)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .frame(width: 450, height: 350)
    }
    
    private var actionButtonLabel: String {
        switch client.authState {
        case .unauthorized:
            return "Send Code"
        case .awaitingCode:
            return "Verify Code"
        case .awaitingPassword:
            return "Submit Password"
        case .authorized:
            return "Done"
        }
    }
    
    private var canProceed: Bool {
        switch client.authState {
        case .unauthorized:
            return !phoneNumber.isEmpty
        case .awaitingCode:
            return !verificationCode.isEmpty
        case .awaitingPassword:
            return !twoFAPassword.isEmpty
        case .authorized:
            return true
        }
    }
    
    private func handleAuthAction() async {
        authError = nil
        
        do {
            switch client.authState {
            case .unauthorized:
                try await client.authenticate(phoneNumber: phoneNumber)
                
            case .awaitingCode:
                try await client.submitCode(verificationCode)
                if client.authState == .authorized {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        onDismiss()
                    }
                }
                
            case .awaitingPassword:
                try await client.submitPassword(twoFAPassword)
                if client.authState == .authorized {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        onDismiss()
                    }
                }
                
            case .authorized:
                onDismiss()
            }
        } catch {
            authError = error.localizedDescription
        }
    }
}