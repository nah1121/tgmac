import Foundation
import CryptoKit

struct TopicNameGenerator {
    func hashedTopicName(for folderPath: String, displayName: String) -> (title: String, pathHash: String) {
        let hash = SHA256.hash(data: Data(folderPath.utf8))
        let suffix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let base = displayName.replacingOccurrences(of: " ", with: "_")
        let truncated = base.prefix(110)
        let title = "\(truncated)-\(suffix)"
        return (String(title.prefix(128)), suffix)
    }
}
