import os

extension Logger {
    // MARK: - Pre-defined Service Categories

    /// Logger for the sync engine subsystem.
    static let syncEngine = Logger(subsystem: "com.nah1121.BackupBot", category: "SyncEngine")

    /// Logger for the file chunking subsystem.
    static let chunker = Logger(subsystem: "com.nah1121.BackupBot", category: "Chunker")

    /// Logger for MTProto / Telegram API interactions.
    static let mtproto = Logger(subsystem: "com.nah1121.BackupBot", category: "MTProto")

    /// Logger for filesystem monitoring (FSEvents / DispatchSource).
    static let fileMonitor = Logger(subsystem: "com.nah1121.BackupBot", category: "FileMonitor")

    /// Logger for security-scoped bookmark management.
    static let secureBookmark = Logger(subsystem: "com.nah1121.BackupBot", category: "SecureBookmark")

    /// Logger for Keychain operations.
    static let keychain = Logger(subsystem: "com.nah1121.BackupBot", category: "Keychain")

    /// Logger for UI-layer events.
    static let ui = Logger(subsystem: "com.nah1121.BackupBot", category: "UI")

    // MARK: - Timed Operation Helper

    /// Executes a closure while measuring its wall-clock duration.
    ///
    /// Logs the operation name at `.info` level before and after execution,
    /// appending the elapsed time via ``ContinuousClock``.
    ///
    /// - Parameters:
    ///   - operation: A human-readable label for the operation (included in log messages).
    ///   - block: The synchronous closure whose duration is measured. Errors are re-thrown.
    /// - Returns: The value returned by `block`.
    /// - Throws: Any error thrown by `block`.
    func timedOperation<T>(_ operation: String, block: () throws -> T) rethrows -> T {
        self.info("Starting: \(operation)")
        let start = ContinuousClock.now
        let result = try block()
        let duration = ContinuousClock.now - start
        self.info("Completed: \(operation) in \(duration)")
        return result
    }
}
