import Foundation
import os

// MARK: - Secure Bookmark Manager

/// Thread-safe singleton that manages security-scoped bookmarks for user-selected folders.
///
/// On macOS, apps running in the sandbox must store a security-scoped bookmark
/// (created via `URL.bookmarkData(options:includingResourceValuesForKeys:relativeTo:)`)
/// in order to re-access a user-selected folder across launches.
///
/// This helper persists bookmark `Data` blobs in a dedicated `UserDefaults` suite
/// keyed by each folder's `UUID`, and provides methods to resolve (re-gain access
/// to) bookmarks at app launch and check for staleness.
///
/// ```swift
/// // Store a bookmark immediately after the user selects a folder via NSOpenPanel
/// let bookmarkData = try url.bookmarkData(options: .withSecurityScope, ...)
/// SecureBookmark.shared.storeBookmark(id: folderID, data: bookmarkData)
///
/// // Restore access on app launch
/// SecureBookmark.shared.restoreAllBookmarks()
/// ```
final class SecureBookmark: @unchecked Sendable {

    // MARK: - Singleton

    /// Shared instance. Access from any thread; internal state is protected by `NSLock`.
    static let shared = SecureBookmark()

    // MARK: - Private Properties

    /// OSLog logger scoped to the bookmark subsystem.
    private let logger = Logger(subsystem: "com.nah1121.BackupBot", category: "SecureBookmark")

    /// UserDefaults suite used to persist bookmark data.
    private let suiteName = "com.nah1121.BackupBot.bookmarks"

    /// The underlying UserDefaults store.
    private let defaults: UserDefaults

    /// Serialises all read/write access to the defaults store.
    private let lock = NSLock()

    // MARK: - Initialisation

    /// Private initializer enforcing the singleton pattern.
    private init() {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        logger.info("SecureBookmark initialised with suite: \(self.suiteName)")
    }

    // MARK: - Public API

    /// Stores bookmark data for a given folder identifier.
    ///
    /// - Parameters:
    ///   - id: The `UUID` identifying the folder.
    ///   - data: The security-scoped bookmark `Data` blob.
    func storeBookmark(id: UUID, data: Data) {
        lock.lock()
        defer { lock.unlock() }

        let key = id.uuidString
        defaults.set(data, forKey: key)
        logger.info("Stored bookmark for \(key)")
    }

    /// Retrieves previously stored bookmark data.
    ///
    /// - Parameter id: The `UUID` identifying the folder.
    /// - Returns: The bookmark `Data`, or `nil` if no bookmark exists for this ID.
    func retrieveBookmark(id: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        let key = id.uuidString
        let data = defaults.data(forKey: key)
        if data == nil {
            logger.debug("No bookmark found for \(key)")
        }
        return data
    }

    /// Restores access to **all** stored security-scoped bookmarks.
    ///
    /// Should be called early during application launch (`applicationDidFinishLaunching`
    /// or `BackupBotApp.init`) so that the app can access previously selected folders.
    ///
    /// For each stored bookmark this method:
    /// 1. Resolves the bookmark data into a `URL`.
    /// 2. Calls `startAccessingSecurityScopedResource()` on the resolved URL.
    /// 3. Logs success or failure (stale bookmarks are logged as warnings).
    func restoreAllBookmarks() {
        lock.lock()
        defer { lock.unlock() }

        let ids = allBookmarkIDs()
        logger.info("Restoring \(ids.count) bookmark(s)")

        for id in ids {
            guard let data = defaults.data(forKey: id.uuidString) else { continue }

            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                if isStale {
                    logger.warning("Bookmark for \(id.uuidString) is stale – user must re-select the folder")
                    continue
                }

                let didStart = url.startAccessingSecurityScopedResource()
                if didStart {
                    logger.info("Restored access to \(url.path) (id: \(id.uuidString))")
                } else {
                    logger.warning("startAccessingSecurityScopedResource returned false for \(id.uuidString)")
                }
            } catch {
                logger.error("Failed to resolve bookmark for \(id.uuidString): \(error.localizedDescription)")
            }
        }
    }

    /// Persists any in-memory changes to the `UserDefaults` suite.
    ///
    /// Called when the app transitions to the background so no data is lost
    /// if the app is subsequently terminated by the system.
    func saveAllBookmarks() {
        lock.lock()
        defer { lock.unlock() }

        defaults.synchronize()
        let count = allBookmarkIDs().count
        logger.info("Saved \(count) bookmark(s) to persistent storage")
    }

    /// Removes the bookmark data associated with the given folder identifier.
    ///
    /// - Parameter id: The `UUID` identifying the folder to forget.
    func removeBookmark(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        let key = id.uuidString
        defaults.removeObject(forKey: key)
        logger.info("Removed bookmark for \(key)")
    }

    /// Returns the identifiers of all folders that have stored bookmarks.
    ///
    /// - Returns: An array of `UUID` values found in the defaults store.
    func allBookmarkIDs() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }

        return defaults.dictionaryRepresentation().keys.compactMap { key -> UUID? in
            // Only consider keys that look like UUIDs (to filter out any unrelated keys)
            UUID(uuidString: key)
        }
    }

    /// Checks whether the bookmark for the given folder has become stale.
    ///
    /// A bookmark is considered stale when `URL(resolvingBookmarkData:...)` sets
    /// `bookmarkDataIsStale` to `true`. Stale bookmarks can still be resolved,
    /// but the app should prompt the user to re-select the folder to obtain a
    /// fresh bookmark.
    ///
    /// - Parameter id: The `UUID` identifying the folder.
    /// - Returns: `true` if the bookmark is stale or cannot be resolved, `false` otherwise.
    func isBookmarkStale(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: id.uuidString) else {
            logger.debug("No bookmark to check for \(id.uuidString)")
            return true
        }

        var isStale = false
        do {
            _ = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            logger.error("Failed to resolve bookmark for staleness check (\(id.uuidString)): \(error.localizedDescription)")
            return true
        }

        if isStale {
            logger.warning("Bookmark for \(id.uuidString) is stale")
        }
        return isStale
    }
}
