import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    @Published var apiId: String {
        didSet { persist() }
    }
    
    @Published var apiHash: String {
        didSet { persist() }
    }
    
    @Published var forumChatId: String {
        didSet { persist() }
    }
    
    @Published var passphrase: String {
        didSet { persist() }
    }
    
    @Published var defaultChunkSizeMB: Int {
        didSet { persist() }
    }
    
    private let defaults = UserDefaults.standard
    private let apiIdKey = "settings.apiId"
    private let apiHashKey = "settings.apiHash"
    private let chatIdKey = "settings.forumChatId"
    private let passphraseKey = "settings.passphrase"
    private let chunkSizeKey = "settings.chunkSize"
    
    private init() {
        self.apiId = defaults.string(forKey: apiIdKey) ?? ""
        self.apiHash = defaults.string(forKey: apiHashKey) ?? ""
        self.forumChatId = defaults.string(forKey: chatIdKey) ?? ""
        self.passphrase = defaults.string(forKey: passphraseKey) ?? ""
        let stored = defaults.integer(forKey: chunkSizeKey)
        self.defaultChunkSizeMB = stored == 0 ? 700 : stored
    }
    
    private func persist() {
        defaults.set(apiId, forKey: apiIdKey)
        defaults.set(apiHash, forKey: apiHashKey)
        defaults.set(forumChatId, forKey: chatIdKey)
        defaults.set(passphrase, forKey: passphraseKey)
        defaults.set(defaultChunkSizeMB, forKey: chunkSizeKey)
    }
}
