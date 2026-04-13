import Foundation
import CryptoKit

final class KeyManager {
    static let shared = KeyManager()
    
    private let defaults = UserDefaults.standard
    private let saltKey = "encryption.salt"
    private let keyVersionKey = "encryption.key.version"
    
    private init() {
        if defaults.data(forKey: saltKey) == nil {
            defaults.set(UUID().uuidString.data(using: .utf8), forKey: saltKey)
        }
        if defaults.integer(forKey: keyVersionKey) == 0 {
            defaults.set(1, forKey: keyVersionKey)
        }
    }
    
    func currentKeyVersion() -> Int {
        let version = defaults.integer(forKey: keyVersionKey)
        return version == 0 ? 1 : version
    }
    
    func deriveKey(from passphrase: String) -> SymmetricKey {
        let salt = defaults.data(forKey: saltKey) ?? Data()
        let input = Data(passphrase.utf8) + salt
        let hash = SHA256.hash(data: input)
        return SymmetricKey(data: hash)
    }
}
