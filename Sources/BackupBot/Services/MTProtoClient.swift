// MTProtoClient.swift
// BackupBot (tgmac)
//
// Telegram MTProto client service for User API authentication, topic management,
// and encrypted file upload to forum topics.
//
// Generated as part of the tgmac implementation plan (Task 3b).
// Swift 5.9, macOS 14+

import Foundation
import CryptoKit
import os

// MARK: - Auth State Machine

/// Represents the current state of Telegram authentication.
/// Transitions: unauthenticated -> waitingForCode -> waitingForPassword -> authenticated
enum TelegramAuthState: Sendable, Equatable {
    /// No authentication attempt has been made
    case unauthenticated
    /// Phone number sent; waiting for the confirmation code (SMS / Telegram code)
    case waitingForCode
    /// Code verified; 2FA password required
    case waitingForPassword
    /// Fully authenticated; session is valid
    case authenticated
    /// An error occurred during authentication
    case error(String)
}

// MARK: - Upload Progress

/// Reports upload progress for a single chunk file.
struct TelegramUploadProgress: Sendable {
    /// The unique identifier of the chunk being uploaded
    let chunkDescriptorId: UUID
    /// Number of bytes sent so far
    let bytesSent: Int64
    /// Total byte count of the chunk
    let totalBytes: Int64
    /// Whether the upload has finished (successfully or not)
    let isComplete: Bool

    /// Fraction of upload completed (0.0 - 1.0)
    var fractionCompleted: Double {
        totalBytes > 0 ? Double(bytesSent) / Double(totalBytes) : 0
    }
}

// MARK: - Upload Job (Internal)

/// Internal bookkeeping for an in-flight upload.
private struct UploadJob: Sendable {
    let chunkDescriptorId: UUID
    let fileURL: URL
    let topicId: Int64
}

// MARK: - MTProto Transport Protocol

/// Abstracts the MTProto transport layer for communicating with Telegram servers.
///
/// The concrete implementation will be provided by extracting code from the
/// telegram-ios open-source client. For initial development, a placeholder
/// implementation using URLSession is provided below.
///
/// ## Integration Notes
/// The real MTProto transport needs:
/// - TCP connection with obfuscation (abridged / padded intermediate)
/// - TL serialization / deserialization of method calls
/// - Authorization key exchange (DH key generation)
/// - Session management with message IDs and sequence numbers
/// - Automatic reconnection and timeout handling
protocol MTProtoTransport: Sendable {
    /// Send a TL-serialized request and receive a TL-serialized response.
    ///
    /// - Parameters:
    ///   - method: The Telegram API method name (e.g., "auth.sendCode")
    ///   - params: Method-specific parameters as key-value pairs
    /// - Returns: TL-serialized response data
    func invoke(_ method: String, params: [String: Any]) async throws -> Data

    /// Upload a file part using the big-file upload method (``messages.uploadEncryptedFile`` / ``upload.saveBigFilePart``).
    ///
    /// - Parameters:
    ///   - fileId: The unique file identifier assigned by Telegram
    ///   - data: Raw bytes of this part (up to 1 MB)
    ///   - partIndex: Zero-based index of this part
    ///   - totalParts: Total number of parts in the file
    /// - Returns: `true` if the part was accepted
    func uploadBigFile(fileId: Int64, data: Data, partIndex: Int, totalParts: Int) async throws -> Bool

    /// Check whether the current session is still valid (e.g., authorized key exists and not revoked).
    func isSessionValid() async -> Bool
}

// MARK: - Placeholder Transport (URLSession-based, for development)

/// A **placeholder** MTProto transport backed by URLSession.
///
/// > **Important:** This implementation does NOT perform real MTProto communication.
/// It exists solely to allow compilation and basic integration testing while the
/// real transport layer is extracted from telegram-ios.
///
/// ## TODO: Real Transport Integration
/// 1. Extract `MTProto` context from `telegram-ios/Telegram-MTProto/Sources/`
/// 2. Wrap in a Swift async interface conforming to `MTProtoTransport`
/// 3. Handle DH key exchange, session creation, and TL serialization
/// 4. Replace this placeholder in `MTProtoClientService.init`
actor URLSessionMTProtoTransport: MTProtoTransport {

    /// Base URL for the Telegram Bot API (NOT used in real MTProto — kept as reference).
    /// Real MTProto uses TCP sockets to `149.154.167.40:443` (or similar DC addresses).
    private let apiBaseURL = "https://api.telegram.org"

    // MARK: - MTProtoTransport

    func invoke(_ method: String, params: [String: Any]) async throws -> Data {
        // TODO: Replace with real MTProto RPC invocation.
        // This would:
        //   1. Serialize `method` + `params` into a TL-constructor
        //   2. Wrap in an MTProto message with correct msg_id / seq_no
        //   3. Encrypt with the session's auth_key
        //   4. Send over the TCP obfuscated connection
        //   5. Await the response, decrypt, and return TL data
        logger.error("Placeholder transport: invoke(\(method)) called — not implemented")
        struct PlaceholderError: Error, LocalizedError {
            var errorDescription: String? { "Placeholder transport: real MTProto not yet integrated" }
        }
        throw PlaceholderError()
    }

    func uploadBigFile(fileId: Int64, data: Data, partIndex: Int, totalParts: Int) async throws -> Bool {
        // TODO: Replace with real MTProto `upload.saveBigFilePart` RPC.
        // This would:
        //   1. Call `upload.saveBigFilePart(file_id, file_part, file_total_parts, bytes)`
        //   2. Handle FLOOD_WAIT / FILE_MIGRATE errors at the transport level
        //   3. Report progress via the continuation
        logger.warning("Placeholder transport: uploadBigFile(id=\(fileId), part=\(partIndex)/\(totalParts)) — not implemented")
        struct PlaceholderError: Error, LocalizedError {
            var errorDescription: String? { "Placeholder transport: big file upload not yet implemented" }
        }
        throw PlaceholderError()
    }

    func isSessionValid() async -> Bool {
        // TODO: Check with the real MTProto session whether the auth key is still valid.
        // For now, always returns false (no real session).
        return false
    }

    // MARK: - Private

    private let logger = Logger.mtproto
}

// MARK: - MTProto Client Service

/// Manages the full Telegram User API lifecycle: authentication, session persistence,
/// forum topic management, and encrypted file upload.
///
/// Thread safety is guaranteed by actor isolation — all public methods are async
/// and serialize access to internal state.
///
/// ## Usage
/// ```swift
/// let client = MTProtoClientService()
/// await client.configure(apiID: 12345, apiHash: "abc…")
/// await client.sendPhoneNumber("+1_555_123_4567")
/// // ... user enters code ...
/// await client.verifyCode("12345")
/// let topicId = try await client.createTopic(title: "My Backup")
/// try await client.uploadFile(fileURL: url, toTopicId: topicId) { progress in
///     print("\(progress.fractionCompleted)")
/// }
/// ```
actor MTProtoClientService {

    // MARK: - Constants

    /// Maximum size of each file-upload part (1 MB). Telegram's limit for `saveBigFilePart`.
    private static let uploadPartSize = 1_024 * 1_024  // 1 MB

    /// Maximum number of retries for transient errors (FLOOD_WAIT, network).
    private static let maxRetries = 5

    /// Default timeout for single RPC calls (seconds).
    private static let rpcTimeout: TimeInterval = 60

    // MARK: - Logger

    private let logger = Logger.mtproto

    // MARK: - Keychain Keys

    private let sessionKey = "com.nah1121.BackupBot.telegramSession"

    // MARK: - Public State (read-only)

    /// Current authentication state machine value.
    private(set) var authState: TelegramAuthState = .unauthenticated

    /// Whether the transport connection is currently active.
    private(set) var isConnected: Bool = false

    // MARK: - Configuration (set from Settings)

    /// Telegram API ID (obtained from https://my.telegram.org).
    var apiID: Int32 = 0

    /// Telegram API hash (obtained from https://my.telegram.org).
    var apiHash: String = ""

    /// The forum supergroup chat ID used for creating / posting to topics.
    var forumChatID: Int64 = 0

    // MARK: - Private State

    /// The underlying MTProto transport (placeholder or real).
    private var transport: MTProtoTransport?

    /// Tracks active upload tasks keyed by chunk descriptor UUID.
    private var activeUploadTasks: [UUID: Task<Void, Error>] = [:]

    /// Phone hash returned by `auth.sendCode` — needed for `auth.signIn`.
    private var phoneCodeHash: String = ""

    /// The authenticated user's phone number (stored after successful auth).
    private var authenticatedPhone: String = ""

    // MARK: - Initialization

    /// Creates a new client with the specified or default transport.
    /// Call ``configure(apiID:apiHash:)`` before any API operations.
    ///
    /// When no transport is provided, the production `TelegramMTProtoTransport`
    /// is used. Pass a custom `MTProtoTransport` for testing or debugging.
    init(transport: MTProtoTransport? = nil) {
        if let transport {
            self.transport = transport
        } else {
            // Production: use the real telegram-ios MTProto transport.
            self.transport = TelegramMTProtoTransport()
        }
        logger.info("MTProtoClientService initialized with transport: \(type(of: self.transport!))")
    }

    // MARK: - Configuration

    /// Configures the client with Telegram API credentials and initializes the transport.
    ///
    /// - Parameters:
    ///   - apiID: Telegram API ID from my.telegram.org
    ///   - apiHash: Telegram API hash from my.telegram.org
    /// - Throws: `SyncEngineError.authenticationFailed` if credentials are invalid.
    func configure(apiID: Int32, apiHash: String) async throws {
        guard apiID > 0, !apiHash.isEmpty else {
            logger.error("Invalid API credentials: apiID=\(apiID), apiHash empty=\(apiHash.isEmpty)")
            authState = .error("Invalid API credentials")
            throw SyncEngineError.authenticationFailed
        }

        self.apiID = apiID
        self.apiHash = apiHash
        self.isConnected = true

        logger.info("MTProto client configured with apiID=\(apiID)")

        // If using TelegramMTProtoTransport, configure it with API credentials
        if let tgTransport = transport as? TelegramMTProtoTransport {
            let restored = await tgTransport.restoreSession()
            if restored {
                logger.info("Previous session restored successfully")
                authState = .authenticated
            } else {
                logger.info("No previous session found; starting fresh")
                authState = .unauthenticated
            }
        } else {
            // Attempt to restore a previously saved session.
            if await loadSession() {
                logger.info("Previous session restored successfully")
            } else {
                logger.info("No previous session found; starting fresh")
                authState = .unauthenticated
            }
        }
    }

    // MARK: - Authentication Flow

    /// Step 1: Send the user's phone number to Telegram.
    ///
    /// On success, transitions to ``TelegramAuthState/waitingForCode``.
    ///
    /// - Parameter phone: Phone number in international format (e.g., "+15551234567").
    /// - Throws: `SyncEngineError.networkUnavailable` if the request fails.
    func sendPhoneNumber(_ phone: String) async throws {
        guard isConnected, let transport else {
            logger.error("Cannot send phone number: not connected")
            throw SyncEngineError.networkUnavailable
        }

        try checkConfigured()

        logger.info("Sending phone number for authentication")

        // TODO: Real implementation:
        //   let response = try await transport.invoke("auth.sendCode", params: [
        //       "phone_number": phone,
        //       "api_id": apiID,
        //       "api_hash": apiHash,
        //       "settings": TLAuthSettings(...)
        //   ])
        //   Parse response to extract `phone_code_hash`
        //   self.phoneCodeHash = ...

        // Placeholder: simulate the flow
        self.phoneCodeHash = UUID().uuidString
        self.authenticatedPhone = phone
        authState = .waitingForCode

        logger.info("Phone number sent; waiting for confirmation code")
    }

    /// Step 2: Verify the confirmation code sent to the user's Telegram app or SMS.
    ///
    /// If 2FA is enabled, transitions to ``TelegramAuthState/waitingForPassword``.
    /// Otherwise, transitions to ``TelegramAuthState/authenticated``.
    ///
    /// - Parameter code: The 5-6 digit confirmation code.
    /// - Throws: `SyncEngineError.authenticationFailed` if the code is invalid.
    func verifyCode(_ code: String) async throws {
        guard authState == .waitingForCode else {
            logger.error("verifyCode called in invalid state: \(String(describing: authState))")
            throw SyncEngineError.authenticationFailed
        }

        guard !phoneCodeHash.isEmpty else {
            logger.error("verifyCode called without phoneCodeHash")
            authState = .error("Missing phone code hash")
            throw SyncEngineError.authenticationFailed
        }

        logger.info("Verifying confirmation code")

        // TODO: Real implementation:
        //   let response = try await transport.invoke("auth.signIn", params: [
        //       "phone_number": authenticatedPhone,
        //       "phone_code_hash": phoneCodeHash,
        //       "phone_code": code
        //   ])
        //   Check for `auth.authorization` vs `auth.passwordRequired`

        // Placeholder: simulate success
        // In real implementation, check if 2FA password is required.
        let passwordRequired = false  // TODO: parse from response

        if passwordRequired {
            authState = .waitingForPassword
            logger.info("Code verified; 2FA password required")
        } else {
            authState = .authenticated
            await saveSession()
            logger.info("Code verified; authenticated successfully")
        }
    }

    /// Step 3: Verify the 2FA password (if the account has two-factor auth enabled).
    ///
    /// On success, transitions to ``TelegramAuthState/authenticated``.
    ///
    /// - Parameter password: The user's 2FA password.
    /// - Throws: `SyncEngineError.authenticationFailed` if the password is incorrect.
    func verifyPassword(_ password: String) async throws {
        guard authState == .waitingForPassword else {
            logger.error("verifyPassword called in invalid state: \(String(describing: authState))")
            throw SyncEngineError.authenticationFailed
        }

        logger.info("Verifying 2FA password")

        // TODO: Real implementation:
        //   let response = try await transport.invoke("auth.checkPassword", params: [
        //       "password": SRPHash.compute(password: password, ...)  // SRP computation
        //   ])

        // Placeholder: simulate success
        authState = .authenticated
        await saveSession()
        logger.info("2FA password verified; authenticated successfully")
    }

    /// Attempts to restore a previously authenticated session from Keychain.
    ///
    /// - Returns: `true` if the session was successfully restored.
    func restoreSession() async -> Bool {
        let restored = await loadSession()
        if restored {
            logger.info("Session restored; state = authenticated")
        } else {
            logger.info("No session to restore")
        }
        return restored
    }

    /// Disconnects from Telegram and clears the session.
    func disconnect() {
        logger.info("Disconnecting MTProto client")

        // Cancel all active uploads
        cancelAllUploads()

        // Clear session
        clearSession()

        // Reset state
        authState = .unauthenticated
        isConnected = false
        phoneCodeHash = ""
        authenticatedPhone = ""

        logger.info("MTProto client disconnected")
    }

    // MARK: - Topic Management

    /// Creates a new forum topic in the configured supergroup.
    ///
    /// - Parameter title: The title for the new topic (typically the folder name).
    /// - Returns: The topic ID of the newly created topic.
    /// - Throws: Network or API errors if creation fails.
    func createTopic(title: String) async throws -> Int64 {
        try checkAuthenticated()
        try checkForumConfigured()
        guard let transport else {
            throw SyncEngineError.networkUnavailable
        }

        logger.info("Creating forum topic with title: \(title)")

        var retryCount = 0
        var lastError: Error?

        while retryCount < Self.maxRetries {
            do {
                // TODO: Real implementation:
                //   let response = try await transport.invoke("channels.createForumTopic", params: [
                //       "channel": InputChannel(channelId: forumChatID, accessHash: ...),
                //       "title": title,
                //       "random_id": Int64.random(in: Int64.min...Int64.max)
                //   ])
                //   Parse `Updates` to extract the created message / topic ID.
                //   The topic ID equals the top message ID.

                // Placeholder: generate a mock topic ID
                let topicId = Int64.random(in: 1...999_999)
                logger.info("Forum topic created with ID: \(topicId)")
                return topicId

            } catch let error as SyncEngineError {
                if case .floodWait(let seconds) = error {
                    retryCount += 1
                    logger.warning("FLOOD_WAIT on createTopic, retry \(retryCount)/\(Self.maxRetries), waiting \(seconds)s")
                    await handleFloodWait(seconds: seconds)
                    continue
                }
                throw error
            } catch {
                lastError = error
                retryCount += 1
                logger.error("createTopic failed (attempt \(retryCount)): \(error.localizedDescription)")
                if retryCount < Self.maxRetries {
                    // Exponential backoff
                    let delay = UInt64(pow(2.0, Double(retryCount))) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        throw SyncEngineError.uploadFailed(lastError ?? NSError(domain: "MTProtoClient", code: -1))
    }

    /// Retrieves information about an existing forum topic.
    ///
    /// - Parameter topicId: The forum topic ID.
    /// - Returns: A tuple of (title, messageCount).
    /// - Throws: Network or API errors.
    func getTopicInfo(topicId: Int64) async throws -> (title: String, messageCount: Int) {
        try checkAuthenticated()
        try checkForumConfigured()
        guard let transport else {
            throw SyncEngineError.networkUnavailable
        }

        logger.info("Getting topic info for topicId=\(topicId)")

        // TODO: Real implementation:
        //   let response = try await transport.invoke("channels.getForumTopics", params: [
        //       "channel": InputChannel(channelId: forumChatID, accessHash: ...),
        //       "top_msg_id": topicId
        //   ])
        //   Parse `ForumTopics` to extract title and message count.

        // Placeholder: return mock data
        return (title: "Topic \(topicId)", messageCount: 0)
    }

    // MARK: - File Upload

    /// Uploads an encrypted chunk file to a forum topic.
    ///
    /// The file is uploaded using the big-file method (`upload.saveBigFilePart`)
    /// with 1 MB parts. For v1, parts are uploaded sequentially (concurrency = 1).
    ///
    /// - Parameters:
    ///   - fileURL: URL of the encrypted file to upload.
    ///   - topicId: Forum topic ID to send the file to.
    ///   - progressHandler: Callback invoked with upload progress updates.
    /// - Returns: The message ID of the uploaded file message.
    /// - Throws: `SyncEngineError.uploadFailed` or `SyncEngineError.floodWait` on failure.
    @discardableResult
    func uploadFile(
        fileURL: URL,
        toTopicId topicId: Int64,
        progressHandler: @Sendable @escaping (TelegramUploadProgress) -> Void
    ) async throws -> Int {
        try checkAuthenticated()
        try checkForumConfigured()
        guard let transport else {
            throw SyncEngineError.networkUnavailable
        }

        // Read the file data
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            logger.error("Failed to read file at \(fileURL.path): \(error.localizedDescription)")
            throw SyncEngineError.uploadFailed(error)
        }

        let totalSize = Int64(fileData.count)
        let totalParts = max(1, (fileData.count + Self.uploadPartSize - 1) / Self.uploadPartSize)
        let chunkDescriptorId = UUID()

        logger.info("Starting upload: \(totalSize) bytes in \(totalParts) parts to topicId=\(topicId)")

        // Generate a file ID for this upload
        let fileId = Int64.random(in: 1...Int64.max)

        // Store the upload task for cancellation support
        let uploadTask = Task<Void, Error> {
            var bytesUploaded: Int64 = 0

            for partIndex in 0..<totalParts {
                // Check for cancellation
                try Task.checkCancellation()

                // Calculate byte range for this part
                let startOffset = partIndex * Self.uploadPartSize
                let endOffset = min(startOffset + Self.uploadPartSize, fileData.count)
                let partData = fileData[startOffset..<endOffset]

                // Upload this part with retry logic
                var retryCount = 0
                var partUploaded = false

                while !partUploaded && retryCount < Self.maxRetries {
                    do {
                        // TODO: Real implementation uses transport.uploadBigFile()
                        _ = try await transport.uploadBigFile(
                            fileId: fileId,
                            data: Data(partData),
                            partIndex: partIndex,
                            totalParts: totalParts
                        )
                        partUploaded = true
                    } catch let error as SyncEngineError {
                        if case .floodWait(let seconds) = error {
                            retryCount += 1
                            logger.warning("FLOOD_WAIT on part \(partIndex), retry \(retryCount)/\(Self.maxRetries), waiting \(seconds)s")
                            await handleFloodWait(seconds: seconds)
                            continue
                        }
                        throw error
                    } catch {
                        retryCount += 1
                        logger.error("Upload part \(partIndex) failed (attempt \(retryCount)): \(error.localizedDescription)")
                        if retryCount >= Self.maxRetries {
                            throw SyncEngineError.uploadFailed(error)
                        }
                        // Exponential backoff before retry
                        let delay = UInt64(pow(2.0, Double(retryCount))) * 1_000_000_000
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }

                // Update progress
                bytesUploaded = Int64(endOffset)
                let progress = TelegramUploadProgress(
                    chunkDescriptorId: chunkDescriptorId,
                    bytesSent: bytesUploaded,
                    totalBytes: totalSize,
                    isComplete: partIndex == totalParts - 1
                )
                progressHandler(progress)
            }

            // After all parts uploaded, send the file to the topic
            // TODO: Real implementation:
            //   let response = try await transport.invoke("messages.sendMedia", params: [
            //       "peer": InputPeerForum(forumTopicId: topicId),
            //       "media": InputMediaUploadedDocument(
            //           file: InputFileBig(id: fileId, parts: totalParts, name: fileURL.lastPathComponent),
            //           mime_type: "application/octet-stream",
            //           attributes: [DocumentAttributeFilename(fileURL.lastPathComponent)]
            //       ),
            //       "random_id": Int64.random(in: Int64.min...Int64.max),
            //       "message": ""
            //   ])
            //   Extract message ID from the `Updates` object.

            logger.info("Upload complete: \(totalSize) bytes sent to topicId=\(topicId)")

            // Return a mock message ID
            return Int.random(in: 1...Int.max)
        }

        // Track the task for cancellation
        activeUploadTasks[chunkDescriptorId] = uploadTask

        defer {
            activeUploadTasks.removeValue(forKey: chunkDescriptorId)
        }

        // Await the upload result
        return try await uploadTask.value
    }

    /// Cancels the upload associated with a specific chunk descriptor.
    ///
    /// - Parameter fileId: The UUID of the chunk descriptor whose upload should be cancelled.
    func cancelUpload(fileId: UUID) {
        guard let task = activeUploadTasks[fileId] else {
            logger.warning("cancelUpload: no active upload for fileId=\(fileId)")
            return
        }
        task.cancel()
        activeUploadTasks.removeValue(forKey: fileId)
        logger.info("Upload cancelled for fileId=\(fileId)")
    }

    /// Cancels all active uploads.
    func cancelAllUploads() {
        let count = activeUploadTasks.count
        for (fileId, task) in activeUploadTasks {
            task.cancel()
            logger.debug("Cancelled upload for fileId=\(fileId)")
        }
        activeUploadTasks.removeAll()
        if count > 0 {
            logger.info("Cancelled all \(count) active uploads")
        }
    }

    // MARK: - Session Persistence

    /// Saves the current session data to Keychain.
    private func saveSession() async {
        guard authState == .authenticated else {
            logger.warning("Attempted to save session while not authenticated")
            return
        }

        // TODO: In the real implementation, serialize the MTProto session:
        //   - Authorization key (auth_key)
        //   - Server salt
        //   - Session ID
        //   - User ID, DC info
        let sessionData: [String: Any] = [
            "phone": authenticatedPhone,
            "savedAt": Date().timeIntervalSince1970,
            "apiID": apiID
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: sessionData)
            try KeychainHelper.save(key: sessionKey, data: data)
            logger.info("Session saved to Keychain")
        } catch {
            logger.error("Failed to save session: \(error.localizedDescription)")
        }
    }

    /// Loads a previously saved session from Keychain.
    ///
    /// - Returns: `true` if a valid session was found and restored.
    private func loadSession() async -> Bool {
        do {
            guard let data = try KeychainHelper.load(key: sessionKey) else {
                logger.debug("No session data found in Keychain")
                return false
            }

            guard let session = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let _ = session["phone"] as? String else {
                logger.warning("Session data in Keychain is malformed")
                return false
            }

            // TODO: In the real implementation, restore the MTProto session:
            //   - Deserialize auth_key, server_salt, session_id
            //   - Validate the session with the server (e.g., `updates.getState`)
            //   - If invalid, clear and return false

            logger.info("Session loaded from Keychain")
            authState = .authenticated
            isConnected = true
            return true

        } catch {
            logger.error("Failed to load session: \(error.localizedDescription)")
            return false
        }
    }

    /// Clears the saved session from Keychain.
    private func clearSession() {
        // TODO: Also clear MTProto session data (auth_key, etc.)
        // For now, overwrite with empty data
        try? KeychainHelper.save(key: sessionKey, data: Data())
        logger.info("Session cleared from Keychain")
    }

    // MARK: - FLOOD_WAIT Handling

    /// Handles a FLOOD_WAIT error by sleeping for the specified duration.
    ///
    /// If the wait exceeds a reasonable threshold (5 minutes), this method
    /// truncates the wait to avoid indefinite blocking.
    ///
    /// - Parameter seconds: The number of seconds to wait.
    private func handleFloodWait(seconds: Int32) async {
        let clampedWait = min(seconds, 300)  // Cap at 5 minutes
        logger.info("FLOOD_WAIT: sleeping for \(clampedWait)s (original: \(seconds)s)")

        // Sleep in small increments to allow cancellation
        let totalNanos = UInt64(clampedWait) * 1_000_000_000
        let incrementNanos: UInt64 = 1_000_000_000  // 1 second increments
        var elapsed: UInt64 = 0

        while elapsed < totalNanos {
            try? await Task.sleep(nanoseconds: min(incrementNanos, totalNanos - elapsed))
            elapsed += incrementNanos
            try? Task.checkCancellation()
        }
    }

    // MARK: - Private Helpers

    /// Verifies that the client is configured with valid API credentials.
    private func checkConfigured() throws {
        guard apiID > 0, !apiHash.isEmpty else {
            logger.error("Client not configured: missing API credentials")
            throw SyncEngineError.authenticationFailed
        }
    }

    /// Verifies that the client is authenticated.
    private func checkAuthenticated() throws {
        guard authState == .authenticated else {
            logger.error("Operation requires authentication; current state: \(String(describing: authState))")
            throw SyncEngineError.authenticationFailed
        }
    }

    /// Verifies that a forum chat ID has been configured.
    private func checkForumConfigured() throws {
        guard forumChatID != 0 else {
            logger.error("Forum chat ID not configured")
            throw SyncEngineError.authenticationFailed
        }
    }
}
