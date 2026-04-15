import SwiftUI

struct AuthFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MTProtoClientService.self) private var mtprotoClient

    @AppStorage("telegramPhoneNumber") private var savedPhoneNumber: String = ""

    // MARK: - State

    @State private var step: AuthStep = .phoneNumber
    @State private var phoneNumber: String = ""
    @State private var confirmationCode: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isLoading: Bool = false
    @State private var codeTimer: Int = 0
    @State private var timerActive: Bool = false

    // MARK: - Steps

    enum AuthStep: Int, CaseIterable {
        case phoneNumber
        case confirmationCode
        case twoFactorPassword
        case success

        var title: String {
            switch self {
            case .phoneNumber: return "Enter Phone Number"
            case .confirmationCode: return "Enter Verification Code"
            case .twoFactorPassword: return "Enter 2FA Password"
            case .success: return "Connected!"
            }
        }

        var icon: String {
            switch self {
            case .phoneNumber: return "phone"
            case .confirmationCode: return "number"
            case .twoFactorPassword: return "lock"
            case .success: return "checkmark.circle.fill"
            }
        }

        var stepNumber: Int {
            switch self {
            case .phoneNumber: return 1
            case .confirmationCode: return 2
            case .twoFactorPassword: return 3
            case .success: return 4
            }
        }

        var totalSteps: Int {
            switch self {
            case .phoneNumber, .confirmationCode, .twoFactorPassword: return 3
            case .success: return 3
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 24) {
                    // Step Indicator
                    stepIndicator

                    // Step Content
                    stepContent

                    // Error Display
                    if let error = errorMessage {
                        errorView(error)
                    }
                }
                .padding(24)
            }

            Divider()

            // Footer Actions
            footerActions
                .padding()
        }
        .frame(width: 400, height: 380)
        .onChange(of: step) { _, newStep in
            // Reset error when changing steps
            errorMessage = nil
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if timerActive && codeTimer > 0 {
                codeTimer -= 1
                if codeTimer == 0 {
                    timerActive = false
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerView: some View {
        HStack {
            Image(systemName: step.icon)
                .font(.title2)
                .foregroundStyle(.accent)
            Text(step.title)
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            if step != .success {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
    }

    // MARK: - Step Indicator

    @ViewBuilder
    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(1...step.totalSteps, id: \.self) { index in
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(circleColor(for: index))
                            .frame(width: 28, height: 28)

                        if index < step.stepNumber || step == .success {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        } else if index == step.stepNumber && step != .success {
                            Text("\(index)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(stepLabel(for: index))
                        .font(.caption2)
                        .foregroundStyle(index <= step.stepNumber ? .primary : .secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if index < step.totalSteps {
                    Rectangle()
                        .fill(index < step.stepNumber ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func circleColor(for index: Int) -> Color {
        if step == .success {
            return .green
        }
        if index < step.stepNumber {
            return .accentColor
        } else if index == step.stepNumber {
            return .accentColor
        }
        return .gray.opacity(0.3)
    }

    private func stepLabel(for index: Int) -> String {
        switch index {
        case 1: return "Phone"
        case 2: return "Code"
        case 3: return "Password"
        default: return ""
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .phoneNumber:
            phoneStep
        case .confirmationCode:
            codeStep
        case .twoFactorPassword:
            passwordStep
        case .success:
            successView
        }
    }

    // MARK: - Phone Number Step

    @ViewBuilder
    private var phoneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter your phone number with country code")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("+")
                    .font(.title)
                    .foregroundStyle(.secondary)

                TextField("Phone Number", text: $phoneNumber)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
                    .monospacedDigit()
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .accessibilityLabel("Phone number with country code")
                    .onSubmit { submitPhoneNumber() }
            }

            Text("Example: 1234567890 for US numbers (include country code without +)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Code Step

    @ViewBuilder
    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the 6-digit verification code from your Telegram app")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                SecureField("Verification Code", text: $confirmationCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
                    .monospacedDigit()
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("6-digit verification code")
                    .onSubmit { submitCode() }

                if timerActive {
                    Text("\(codeTimer)s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 32)
                }
            }

            if let masked = maskedPhoneNumber {
                Text("Sent to: \(masked)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !timerActive && codeTimer == 0 && step == .confirmationCode {
                Button("Resend Code") {
                    resendCode()
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Password Step

    @ViewBuilder
    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
                Text("Your account has two-factor authentication enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .textContentType(.password)
                .accessibilityLabel("Two-factor authentication password")
                .onSubmit { submitPassword() }

            Text("Enter the password you set up in Telegram's privacy settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Success View

    @ViewBuilder
    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: step)

            Text("Successfully Connected")
                .font(.title2)
                .fontWeight(.bold)

            Text("Your Telegram account is now linked. You can close this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer Actions

    @ViewBuilder
    private var footerActions: some View {
        HStack {
            // Back button
            if step == .confirmationCode || step == .twoFactorPassword {
                Button {
                    goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Spacer()
            }

            Spacer()

            // Primary action
            switch step {
            case .phoneNumber:
                Button {
                    submitPhoneNumber()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Send Code")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(phoneNumber.count < 5 || isLoading)

            case .confirmationCode:
                Button {
                    submitCode()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Verify")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(confirmationCode.count < 4 || isLoading)

            case .twoFactorPassword:
                Button {
                    submitPassword()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Authenticate")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty || isLoading)

            case .success:
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Computed Properties

    private var maskedPhoneNumber: String? {
        guard phoneNumber.count > 4 else { return nil }
        let prefix = String(phoneNumber.prefix(4))
        let suffix = String(phoneNumber.suffix(3))
        return "+\(prefix)•••••\(suffix)"
    }

    // MARK: - Navigation

    private func goBack() {
        withAnimation(.easeInOut(duration: 0.25)) {
            switch step {
            case .confirmationCode:
                step = .phoneNumber
                confirmationCode = ""
            case .twoFactorPassword:
                step = .confirmationCode
                password = ""
            default:
                break
            }
        }
        errorMessage = nil
    }

    // MARK: - API Calls

    private func submitPhoneNumber() {
        let phone = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phone.count >= 5 else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await mtprotoClient.sendPhoneNumber(phone)
                savedPhoneNumber = phone

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        step = .confirmationCode
                    }
                    codeTimer = 120
                    timerActive = true
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to send code: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func submitCode() {
        let code = confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count >= 4 else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await mtprotoClient.verifyCode(code)

                // Check if we need 2FA password
                let currentAuthState = await mtprotoClient.authState
                if case .waitingForPassword = currentAuthState {
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            step = .twoFactorPassword
                        }
                        isLoading = false
                    }
                } else {
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            step = .success
                        }
                        isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    if let syncError = error as? SyncEngineError,
                       case .floodWait(let seconds) = syncError {
                        errorMessage = "Flood wait: Please wait \(seconds) seconds before trying again."
                    } else {
                        errorMessage = "Invalid code: \(error.localizedDescription)"
                    }
                    isLoading = false
                }
            }
        }
    }

    private func submitPassword() {
        guard !password.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await mtprotoClient.verifyPassword(password)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        step = .success
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Authentication failed: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func resendCode() {
        errorMessage = nil
        submitPhoneNumber()
    }
}
