import Foundation
import OSLog
import Combine

/// File change event types
enum FileChangeEvent: Equatable {
    case created(URL)
    case modified(URL)
    case deleted(URL)
    case moved(URL, URL)
    
    var url: URL {
        switch self {
        case .created(let url), .modified(let url), .deleted(let url):
            return url
        case .moved(_, let toURL):
            return toURL
        }
    }
}

/// Errors that can occur during file monitoring
enum FileMonitorError: LocalizedError {
    case streamCreationFailed
    case invalidPath
    case accessDenied
    
    var errorDescription: String? {
        switch self {
        case .streamCreationFailed:
            return "Failed to create FSEvents stream"
        case .invalidPath:
            return "Invalid folder path"
        case .accessDenied:
            return "Access denied to folder"
        }
    }
}

/// Service for monitoring file system changes using FSEvents
class FileMonitor: ObservableObject {
    private let logger = Logger(subsystem: "com.backupbot.app", category: "FileMonitor")
    
    @Published var recentEvents: [FileChangeEvent] = []
    
    private var eventStreams: [String: FSEventStreamRef] = [:]
    private var lastEventIds: [String: UInt64] = [:]
    private var debounceTimers: [String: Timer] = [:]
    private let debounceInterval: TimeInterval = 2.0 // 2 seconds debounce
    
    private let eventQueue = DispatchQueue(label: "com.backupbot.filemonitor.events")
    private var pendingEvents: [String: [FileChangeEvent]] = [:]
    
    /// Start monitoring a folder path
    func startMonitoring(path: URL, eventId: UInt64 = UInt64.max) async throws {
        guard path.isFileURL else {
            throw FileMonitorError.invalidPath
        }
        
        let pathKey = path.path
        
        if eventStreams[pathKey] != nil {
            logger.debug("Already monitoring: \(pathKey)")
            return
        }
        
        var callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds in
            guard let clientCallBackInfo = clientCallBackInfo else { return }
            
            let monitor = Unmanaged<FileMonitor>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            let flags = unsafeBitCast(eventFlags, to: NSArray.self)
            let ids = unsafeBitCast(eventIds, to: NSArray.self)
            
            for i in 0..<Int(numEvents) {
                guard let pathStr = paths[i] as? String else { continue }
                let url = URL(fileURLWithPath: pathStr)
                let flag = flags[i] as! NSNumber
                let eventId = ids[i] as! UInt64
                
                let event: FileChangeEvent
                
                if flag.uint32Value & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                    event = .created(url)
                } else if flag.uint32Value & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                    event = .deleted(url)
                } else if flag.uint32Value & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                    // For moves, we'd need to track both paths - simplified here
                    event = .moved(url, url)
                } else {
                    event = .modified(url)
                }
                
                monitor.handleEvent(event, for: pathKey, eventId: eventId)
            }
        }
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path.path] as CFArray,
            eventId == UInt64.max ? FSEventStreamEventIdSinceNow : FSEventStreamEventId(eventId),
            0.5, // latency
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagSkipHistory)
        )
        
        guard let streamRef = stream else {
            throw FileMonitorError.streamCreationFailed
        }
        
        FSEventStreamScheduleWithRunLoop(streamRef, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        
        if !FSEventStreamStart(streamRef) {
            FSEventStreamInvalidate(streamRef)
            FSEventStreamRelease(streamRef)
            throw FileMonitorError.streamCreationFailed
        }
        
        eventStreams[pathKey] = streamRef
        lastEventIds[pathKey] = eventId
        
        logger.info("Started monitoring: \(pathKey)")
    }
    
    private func handleEvent(_ event: FileChangeEvent, for pathKey: String, eventId: UInt64) {
        eventQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Update last event ID
            self.lastEventIds[pathKey] = eventId
            
            // Skip hidden files and common temporary files
            let fileName = event.url.lastPathComponent
            if fileName.hasPrefix(".") || fileName.hasPrefix("~") || fileName.hasSuffix(".tmp") {
                return
            }
            
            // Add to pending events
            if self.pendingEvents[pathKey] == nil {
                self.pendingEvents[pathKey] = []
            }
            self.pendingEvents[pathKey]?.append(event)
            
            // Debounce events
            self.debounceTimers[pathKey]?.invalidate()
            self.debounceTimers[pathKey] = Timer.scheduledTimer(withTimeInterval: self.debounceInterval, repeats: false) { [weak self] _ in
                self?.flushEvents(for: pathKey)
            }
        }
    }
    
    private func flushEvents(for pathKey: String) {
        eventQueue.async { [weak self] in
            guard let self = self, let events = self.pendingEvents[pathKey], !events.isEmpty else { return }
            
            DispatchQueue.main.async {
                self.recentEvents.append(contentsOf: events)
            }
            
            self.logger.debug("Flushed \(events.count) events for: \(pathKey)")
            self.pendingEvents[pathKey] = []
        }
    }
    
    /// Stop monitoring a folder
    func stopMonitoring(path: URL) {
        let pathKey = path.path
        
        if let stream = eventStreams[pathKey] {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStreams.removeValue(forKey: pathKey)
            logger.info("Stopped monitoring: \(pathKey)")
        }
        
        debounceTimers[pathKey]?.invalidate()
        debounceTimers.removeValue(forKey: pathKey)
        pendingEvents.removeValue(forKey: pathKey)
    }
    
    /// Stop all monitoring
    func stopAllMonitoring() {
        for pathKey in Array(eventStreams.keys) {
            if let stream = eventStreams[pathKey] {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
        eventStreams.removeAll()
        debounceTimers.values.forEach { $0.invalidate() }
        debounceTimers.removeAll()
        pendingEvents.removeAll()
        logger.info("Stopped all monitoring")
    }
    
    /// Rescan a folder and return initial inventory
    func rescan(path: URL) async throws -> [FileChangeEvent] {
        guard path.isFileURL else {
            throw FileMonitorError.invalidPath
        }
        
        let fm = FileManager.default
        var events: [FileChangeEvent] = []
        
        guard let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw FileMonitorError.accessDenied
        }
        
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == true {
                events.append(.created(fileURL))
            }
        }
        
        logger.info("Rescan found \(events.count) files in: \(path.path)")
        return events
    }
    
    /// Get the last event ID for a path
    func getLastEventId(for path: URL) -> UInt64 {
        lastEventIds[path.path] ?? UInt64.max
    }
}