import Foundation
import OSLog

final class SecureBookmark {
    static let shared = SecureBookmark()
    
    private let defaultsKey = "backupbot.secureBookmarks"
    private let logger = Logger(subsystem: "com.backupbot.app", category: "SecureBookmark")
    private var bookmarks: [String: Data] = [:]
    
    private init() {
        loadPersisted()
    }
    
    func restoreAllBookmarks() {
        for (id, data) in bookmarks {
            _ = resolveURL(for: id, bookmarkData: data)
        }
    }
    
    func saveAllBookmarks() {
        persist()
    }
    
    func storeBookmark(id: String, data: Data) {
        bookmarks[id] = data
        persist()
    }
    
    func bookmark(for id: String) -> Data? {
        bookmarks[id]
    }
    
    func removeBookmark(id: String) {
        bookmarks[id] = nil
        persist()
    }
    
    func resolveURL(for id: String) -> URL? {
        guard let data = bookmarks[id] else { return nil }
        return resolveURL(for: id, bookmarkData: data)
    }
    
    private func resolveURL(for id: String, bookmarkData: Data) -> URL? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                logger.error("Bookmark for \(id, privacy: .public) is stale")
                return nil
            }
            return url
        } catch {
            logger.error("Failed to resolve bookmark for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    private func loadPersisted() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? PropertyListDecoder().decode([String: Data].self, from: data) {
            bookmarks = stored
        }
    }
    
    private func persist() {
        if let data = try? PropertyListEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
