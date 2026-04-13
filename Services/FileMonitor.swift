import Foundation
import OSLog

struct FileInventoryResult {
    let records: [FileRecord]
    let totalBytes: Int64
    let fileCount: Int
}

@MainActor
final class FileMonitor {
    private let logger = Logger(subsystem: "com.backupbot.app", category: "FileMonitor")
    private let fileManager = FileManager.default
    
    func inventory(for folder: SyncFolder) -> FileInventoryResult {
        guard let url = folder.resolvedURL else {
            logger.error("Unable to resolve bookmark for folder \(folder.displayName, privacy: .public)")
            return FileInventoryResult(records: [], totalBytes: 0, fileCount: 0)
        }
        
        var records: [FileRecord] = []
        var total: Int64 = 0
        var count = 0
        
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                   values.isRegularFile == true,
                   let fileSize = values.fileSize {
                    let relative = fileURL.path.replacingOccurrences(of: url.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let record = FileRecord(
                        relativePath: relative,
                        sizeBytes: Int64(fileSize),
                        modifiedAt: values.contentModificationDate ?? Date(),
                        syncFolder: folder
                    )
                    records.append(record)
                    total += Int64(fileSize)
                    count += 1
                }
            }
        }
        
        folder.lastEventId = UInt64(Date().timeIntervalSince1970)
        return FileInventoryResult(records: records, totalBytes: total, fileCount: count)
    }
}
