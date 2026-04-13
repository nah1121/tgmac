import Foundation
import SwiftData
import OSLog
import Combine

enum SyncEngineError: LocalizedError {
    case authenticationFailed
    case networkUnavailable
    case floodWait(Int32)
    case uploadFailed(Error)
    case chunkingFailed