import Foundation
import Security
import os

// MARK: - Keychain Helper

/// Lightweight Keychain utility for persisting sensitive data such as the
/// AES-256 encryption key and Telegram session tokens.
///
/// All items are stored as `kSecClassGenericPassword` entries under a shared
/// service name and optional access group so the app and its extensions can
/// share the same keychain items.
enum KeychainHelper {

    // MARK: - Constants

    /// The Keychain service name used for all items managed by this helper.
    private static let serviceName = "com.nah1121.BackupBot"

    /// The Keychain access group for sharing items between app and extensions.
    private static let accessGroup = "com.nah1121.BackupBot.shared"

    /// OSLog logger scoped to the Keychain subsystem.
    static let logger = Logger(subsystem: "com.nah1121.BackupBot", category: "Keychain")

    /// Key used to store the AES-256 encryption key in the Keychain.
    private static let encryptionKeyIdentifier = "com.nah1121.BackupBot.encryptionKey"

    // MARK: - Encryption Key

    /// Generates a cryptographically random 256-bit symmetric key, stores it in
    /// the Keychain, and returns the raw key bytes.
    ///
    /// If a key already exists under the encryption key identifier it is
    /// overwritten with the newly generated key.
    ///
    /// - Returns: A 32-byte `Data` value containing the raw key material.
    /// - Throws: A ``KeychainError`` if the Keychain operation fails.
    @discardableResult
    static func generateAndStoreEncryptionKey() throws -> Data {
        let key = SymmetricKey(size: .bits256)
        let rawData = key.withUnsafeBytes { Data($0) }

        logger.info("Generated 256-bit encryption key (\(rawData.count) bytes)")

        // If a key already exists, delete it first to avoid duplicate-item errors.
        if exists(key: encryptionKeyIdentifier) {
            delete(key: encryptionKeyIdentifier)
        }

        try save(key: encryptionKeyIdentifier, data: rawData)
        logger.info("Stored encryption key in Keychain")

        return rawData
    }

    /// Returns the existing AES-256 encryption key, or generates and stores a
    /// new one if none is found.
    ///
    /// - Returns: A 32-byte `Data` value containing the raw key material.
    /// - Throws: A ``KeychainError`` if reading or generating the key fails.
    static func getOrCreateEncryptionKey() throws -> Data {
        if exists(key: encryptionKeyIdentifier) {
            return try load(key: encryptionKeyIdentifier)
        }
        return try generateAndStoreEncryptionKey()
    }

    // MARK: - Generic CRUD

    /// Stores arbitrary data in the Keychain under the given key.
    ///
    /// If an item with the same `key` already exists it is updated in place.
    ///
    /// - Parameters:
    ///   - key: A unique identifier for the Keychain item.
    ///   - data: The data to persist.
    /// - Throws: A ``KeychainError`` wrapping the underlying `OSStatus`.
    static func save(key: String, data: Data) throws {
        // Build the base query
        let baseQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:         serviceName,
            kSecAttrAccount as String:         key,
            kSecAttrAccessGroup as String:     accessGroup,
        ]

        // First try to update an existing item
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            logger.debug("Updated Keychain item for key: \(key)")
            return
        }

        if updateStatus == errSecItemNotFound {
            // Item does not exist yet – create it
            var addItemQuery = baseQuery
            addItemQuery[kSecValueData as String] = data

            // Request kSecAttrAccessible after first unlock so the keychain
            // item survives app restarts but is not accessible when the device
            // is locked (best balance of security and usability for a backup app).
            addItemQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(addItemQuery as CFDictionary, nil)

            guard addStatus == errSecSuccess else {
                logger.error("SecItemAdd failed for key '\(key)': \(addStatus)")
                throw KeychainError.unhandledError(status: addStatus)
            }

            logger.debug("Created Keychain item for key: \(key)")
            return
        }

        // Any other update error is fatal
        logger.error("SecItemUpdate failed for key '\(key)': \(updateStatus)")
        throw KeychainError.unhandledError(status: updateStatus)
    }

    /// Retrieves data previously stored under the given key.
    ///
    /// - Parameter key: The identifier used when the data was saved.
    /// - Returns: The stored `Data`.
    /// - Throws: ``KeychainError/itemNotFound`` if no item exists,
    ///           or ``KeychainError/unhandledError(status:)`` for other failures.
    static func load(key: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String:                  kSecClassGenericPassword,
            kSecAttrService as String:             serviceName,
            kSecAttrAccount as String:             key,
            kSecAttrAccessGroup as String:         accessGroup,
            kSecReturnData as String:              true,
            kSecMatchLimit as String:              kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                logger.error("Keychain returned non-Data result for key '\(key)'")
                throw KeychainError.unexpectedData
            }
            logger.debug("Loaded Keychain item for key: \(key)")
            return data
        case errSecItemNotFound:
            logger.debug("Keychain item not found for key: \(key)")
            throw KeychainError.itemNotFound
        default:
            logger.error("SecItemCopyMatching failed for key '\(key)': \(status)")
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Deletes the Keychain item associated with the given key.
    ///
    /// No error is thrown if the item does not exist.
    ///
    /// - Parameter key: The identifier of the item to delete.
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:     serviceName,
            kSecAttrAccount as String:     key,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            logger.debug("Deleted Keychain item for key: \(key)")
        } else if status != errSecItemNotFound {
            logger.warning("SecItemDelete failed for key '\(key)': \(status)")
        }
    }

    /// Checks whether a Keychain item exists for the given key.
    ///
    /// - Parameter key: The identifier to look up.
    /// - Returns: `true` if an item exists, `false` otherwise.
    static func exists(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:     serviceName,
            kSecAttrAccount as String:     key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String:      false,
            kSecMatchLimit as String:      kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}

// MARK: - Keychain Error

/// Errors that can arise from Keychain operations.
enum KeychainError: LocalizedError {
    /// The requested item was not found in the Keychain.
    case itemNotFound

    /// The Keychain returned data in an unexpected format.
    case unexpectedData

    /// An unhandled `OSStatus` was returned by a Security framework function.
    case unhandledError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Keychain item not found."
        case .unexpectedData:
            return "Keychain returned unexpected data format."
        case .unhandledError(let status):
            return "Keychain error (OSStatus \(status))."
        }
    }
}
