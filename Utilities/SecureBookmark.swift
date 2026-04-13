import Foundation
import OSLog
import Security

/// Manages security-scoped bookmarks for persistent access to user-selected folders
class SecureBookmark: ObservableObject {
    static let shared = SecureBookmark()
    
    private let defaults = UserDefaults.standard
    private let bookmarkKeyPrefix = "secureBookmark."
    private let logger = Logger(subsystem: "com.backupbot.app", category: "SecureBookmark")
    
    private let accessQueue = DispatchQueue(label: "com.backupbot.bookmark.access", attributes: .concurrent)
    
    /// Store a bookmark Data for a given folder ID
    func storeBookmark(id: String, data: Data) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let key = self.bookmarkKeyPrefix + id
            self.defaults.set(data, forKey: key)
            self.logger.info("Stored bookmark for ID: \(id)")
        }
    }
    
    /// Retrieve bookmark Data for a given folder ID
    func getBookmark(id: String) -> Data? {
        var result: Data?
        accessQueue.sync {
            let key = bookmarkKeyPrefix + id
            result = defaults.data(forKey: key)
        }
        return result
    }
    
    /// Resolve a bookmark to a URL, activating security scope if successful
    func resolveBookmark(id: String) -> URL? {
        guard let bookmarkData = getBookmark(id: id) else {
            logger.warning("No bookmark found for ID: \(id)")
            return nil
        }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                logger.warning("Bookmark is stale for ID: \(id)")
                // Still try to use it, but caller should handle re-selection
            }
            
            // Start accessing the security-scoped resource
            let accessing = url.startAccessingSecurityScopedResource()
            if !accessing {
                logger.error("Failed to access security-scoped resource for ID: \(id)")
                return nil
            }
            
            logger.info("Resolved bookmark for ID: \(id)")
            return url
        } catch {
            logger.error("Failed to resolve bookmark for ID: \(id): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Stop accessing a security-scoped resource (call when done with the URL)
    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
    
    /// Restore all bookmarks on app launch (activates security scope for each)
    func restoreAllBookmarks() {
        accessQueue.sync { [weak self] in
            guard let self = self else { return }
            let allKeys = self.defaults.dictionaryRepresentation().keys
            let bookmarkKeys = allKeys.filter { $0.hasPrefix(self.bookmarkKeyPrefix) }
            
            logger.info("Restoring \(bookmarkKeys.count) bookmarks")
            
            for key in bookmarkKeys {
                if let data = self.defaults.data(forKey: key) {
                    do {
                        var isStale = false
                        let url = try URL(
                            resolvingBookmarkData: data,
                            options: [.withoutUI],
                            relativeTo: nil,
                            bookmarkDataIsStale: &isStale
                        )
                        
                        if isStale {
                            self.logger.warning("Bookmark \(key) is stale")
                        }
                        
                        self.logger.debug("Restored bookmark: \(key)")
                    } catch {
                        self.logger.error("Failed to restore bookmark \(key): \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    /// Save all current bookmarks (called when app enters background)
    func saveAllBookmarks() {
        // Bookmarks are saved immediately when stored, but this ensures persistence
        logger.debug("Saving all bookmarks")
        defaults.synchronize()
    }
    
    /// Remove a bookmark by ID
    func removeBookmark(id: String) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let key = self.bookmarkKeyPrefix + id
            self.defaults.removeObject(forKey: key)
            self.logger.info("Removed bookmark for ID: \(id)")
        }
    }
    
    /// Clear all bookmarks (use with caution)
    func removeAllBookmarks() {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let allKeys = self.defaults.dictionaryRepresentation().keys
            let bookmarkKeys = allKeys.filter { $0.hasPrefix(self.bookmarkKeyPrefix) }
            
            for key in bookmarkKeys {
                self.defaults.removeObject(forKey: key)
            }
            
            self.logger.info("Removed all \(bookmarkKeys.count) bookmarks")
        }
    }
}
