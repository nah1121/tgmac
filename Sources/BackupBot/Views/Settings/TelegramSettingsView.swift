import SwiftUI

struct TelegramSettingsView: View {
    @Environment(MTProtoClientService.self) private var mtprotoClient

    // MARK: - Persisted Credentials

    @AppStorage("telegramApiID") private var apiIDString: String = ""
    @AppStorage("telegramApiHash") private var apiHash: String = ""
    @AppStorage("telegramForumChatID") private var forumChatIDString: String = ""
    @AppStorage("telegramPhoneNumber") private var phoneNumber: String = ""

    // MARK: - UI State

    @State private var authState: TelegramAuthState = .unauthenticated
    @State private var isConnected: Bool = false
    @State private var isConfiguring = false
    @State private var isTesting = false
    @State private var isConnecting = false
    @State private var showAuthSheet = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        Form {
            credentialsSection
            connectionSection
            actionsSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await refreshConnectionState()
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            Task { await refreshConnectionState() }
        }
        .sheet(isPresented: $showAuthSheet) {
            AuthFlowView()
        }
        .alert("Connection Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Credentials Section

    @ViewBuilder
    private var credentialsSection: some View {
        Section {
            HStack {
                TextField("API ID", text: $apiIDString)
                    .monospacedDigit()
                    .accessibilityLabel("Telegram API ID")
                    .help("Your Telegram API ID from my.telegram.org")
                Spacer()
                Image(systemName: "number.circle")
                    .foregroundStyle(.secondary)
                    .help("Integer value (e.g., 12345678)")
            }

            HStack {
                SecureField("API Hash", text: $apiHash)
                    .accessibilityLabel("Telegram API Hash")
                    .help("Your Telegram API Hash from my.telegram.org")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(apiHash, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy API Hash to clipboard")
            }

            HStack {
                TextField("Forum Chat ID", text: $forumChatIDString)
                    .monospacedDigit()
                    .accessibilityLabel("Telegram Forum Chat ID")
                    .help("The ID of your Telegram forum/supergroup chat")
                Spacer()
                Image(systemName: "number.circle")
                    .foregroundStyle(.secondary)
                    .help("Negative integer (e.g., -1001234567890)")
            }
        } header: {
            Label("API Credentials", systemImage: "key")
        } footer: {
            Text("Enter your Telegram Bot API credentials from my.telegram.org. These are stored securely in your Keychain.")
        }
    }

    // MARK: - Connection Section

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            // Connection Status
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .overlay {
                        if authState == .waitingForCode || authState == .waitingForPassword || isConnecting {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .fontWeight(.medium)
                    Text(statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)

            // Phone number (when authenticated)
            if authState == .authenticated || authState == .waitingForCode || authState == .waitingForPassword {
                HStack {
                    Image(systemName: "phone")
                        .foregroundStyle(.secondary)
                    if let masked = maskedPhoneNumber {
                        Text(masked)
                            .font(.body)
                    } else {
                        Text(phoneNumber)
                            .font(.body)
                    }
                    Spacer()
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Label("Connection Status", systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    // MARK: - Actions Section

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            // Save Configuration
            Button {
                saveConfiguration()
            } label: {
                HStack {
                    if isConfiguring {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Save Configuration")
                }
            }
            .disabled(isConfiguring || apiIDString.isEmpty || apiHash.isEmpty || forumChatIDString.isEmpty)
            .help("Save API credentials and connect to Telegram")

            // Connect / Disconnect
            if isConnected || authState == .authenticated {
                Button(role: .destructive) {
                    disconnect()
                } label: {
                    Label("Disconnect", systemImage: "power")
                }
                .help("Disconnect from Telegram")
            } else {
                Button {
                    connect()
                } label: {
                    HStack {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Label("Connect & Authenticate", systemImage: "paperplane.fill")
                    }
                }
                .disabled(isConnecting || apiIDString.isEmpty || apiHash.isEmpty)
                .help("Connect to Telegram and authenticate with your phone number")
            }

            // Test Connection
            if isConnected {
                Button {
                    testConnection()
                } label: {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting)
                .help("Verify the connection to Telegram is working")
            }

            // Restore Session
            if authState == .unauthenticated && !apiIDString.isEmpty {
                Button {
                    restoreSession()
                } label: {
                    Text("Restore Previous Session")
                }
                .help("Attempt to restore a previously authenticated session")
            }
        } header: {
            Label("Actions", systemImage: "bolt")
        }
    }

    // MARK: - Computed Properties

    private var statusColor: Color {
        if isConnecting || authState == .waitingForCode || authState == .waitingForPassword {
            return .yellow
        }
        switch authState {
        case .unauthenticated: return .secondary
        case .waitingForCode, .waitingForPassword: return .yellow
        case .authenticated: return .green
        case .error: return .red
        }
    }

    private var statusText: String {
        switch authState {
        case .unauthenticated: return "Disconnected"
        case .waitingForCode: return "Waiting for Code"
        case .waitingForPassword: return "Waiting for 2FA Password"
        case .authenticated: return "Connected"
        case .error(let message): return "Error"
        }
    }

    private var statusDescription: String {
        switch authState {
        case .unauthenticated:
            return "Enter your API credentials and connect to Telegram."
        case .waitingForCode:
            return "Enter the verification code sent to your Telegram app."
        case .waitingForPassword:
            return "Enter your two-factor authentication password."
        case .authenticated:
            return "Successfully authenticated with Telegram."
        case .error(let message):
            return message.isEmpty ? "An unknown error occurred." : message
        }
    }

    private var maskedPhoneNumber: String? {
        guard phoneNumber.count > 4 else { return nil }
        let prefix = String(phoneNumber.prefix(4))
        let suffix = String(phoneNumber.suffix(3))
        return "\(prefix)•••••\(suffix)"
    }

    // MARK: - Actions

    private func refreshConnectionState() async {
        authState = await mtprotoClient.authState
        isConnected = await mtprotoClient.isConnected
    }

    private func saveConfiguration() {
        guard let apiID = Int32(apiIDString), !apiIDString.isEmpty else {
            errorMessage = "API ID must be a valid integer."
            showError = true
            return
        }
        guard !apiHash.isEmpty else {
            errorMessage = "API Hash cannot be empty."
            showError = true
            return
        }
        guard let forumChatID = Int64(forumChatIDString), !forumChatIDString.isEmpty else {
            errorMessage = "Forum Chat ID must be a valid integer."
            showError = true
            return
        }

        isConfiguring = true
        Task {
            do {
                try await mtprotoClient.configure(apiID: apiID, apiHash: apiHash)
                await MainActor.run {
                    isConfiguring = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Configuration failed: \(error.localizedDescription)"
                    showError = true
                    isConfiguring = false
                }
            }
        }
    }

    private func connect() {
        isConnecting = true
        Task {
            do {
                // First save configuration if needed
                if let apiID = Int32(apiIDString), !apiHash.isEmpty {
                    try await mtprotoClient.configure(apiID: apiID, apiHash: apiHash)
                }

                // Try to restore session first
                let restored = await mtprotoClient.restoreSession()

                if restored {
                    await refreshConnectionState()
                    isConnecting = false
                } else {
                    // Need to authenticate
                    await MainActor.run {
                        showAuthSheet = true
                        isConnecting = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Connection failed: \(error.localizedDescription)"
                    showError = true
                    isConnecting = false
                }
            }
        }
    }

    private func disconnect() {
        mtprotoClient.disconnect()
        Task { await refreshConnectionState() }
    }

    private func restoreSession() {
        Task {
            let restored = await mtprotoClient.restoreSession()
            if !restored {
                await MainActor.run {
                    errorMessage = "Could not restore previous session. Please authenticate again."
                    showError = true
                }
            }
            await refreshConnectionState()
        }
    }

    private func testConnection() {
        isTesting = true
        Task {
            // A simple connectivity check: verify auth state is still valid
            try? await Task.sleep(for: .seconds(1))
            let stillConnected = await mtprotoClient.isConnected
            await MainActor.run {
                if !stillConnected {
                    errorMessage = "Connection test failed. The Telegram connection appears to be lost."
                    showError = true
                }
                isTesting = false
            }
        }
    }
}
