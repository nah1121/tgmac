# BackupBot (tgmac)

SwiftUI macOS app that monitors Mac folders, maps each folder
to a Telegram forum topic, chunks and encrypts files, and uploads them through the
Telegram User API (MTProto).

## Requirements

- macOS 14+ (Sonoma)
- Xcode 15+
- Swift 5.9
- Telegram API ID and API Hash (from [my.telegram.org](https://my.telegram.org))
- A Telegram supergroup with topics enabled

## Project Structure

```
tgmac-sources/
├── Package.swift                          # SPM manifest (reference)
├── Entitlements/
│   └── BackupBot.entitlements             # Sandbox entitlements
├── Sources/BackupBot/
│   ├── App/
│   │   ├── BackupBotApp.swift             # @main entry, service injection
│   │   └── ContentView.swift              # NavigationSplitView main window
│   ├── Views/
│   │   ├── AddFolderView.swift            # Folder picker with NSOpenPanel
│   │   ├── FolderDetailView.swift         # Per-folder status and controls
│   │   ├── SyncHistoryView.swift          # Sync history list
│   │   ├── UploadHistoryViewer.swift      # Upload history with retry/cancel
│   │   ├── Settings/
│   │   │   ├── GeneralSettingsView.swift  # Chunk size, dry-run, cache
│   │   │   └── TelegramSettingsView.swift # API credentials, connection
│   │   └── Auth/
│   │       └── AuthFlowView.swift         # Phone → Code → 2FA flow
│   ├── Models/
│   │   ├── SyncFolder.swift               # Tracked folder SwiftData model
│   │   ├── TopicMapping.swift             # Telegram topic mapping model
│   │   ├── FileRecord.swift               # Per-file metadata model
│   │   └── UploadHistoryRecord.swift      # Upload history record model
│   ├── Services/
│   │   ├── Chunker.swift                  # ZIP + AES-256-GCM chunking
│   │   ├── FileMonitor.swift              # FSEvents file watcher
│   │   ├── MTProtoClient.swift            # Telegram User API client
│   │   ├── TelegramMTProtoTransport.swift # Production MTProto transport
│   │   └── SyncEngine.swift              # Pipeline orchestrator
│   ├── Utilities/
│   │   ├── SecureBookmark.swift           # Security-scoped bookmark manager
│   │   ├── KeychainHelper.swift           # Keychain CRUD utility
│   │   └── Logger+Ext.swift              # OSLog convenience extensions
│   └── Support/
│       ├── DiagnosticsView.swift          # Legacy log viewer
│       ├── StructuredLogViewer.swift       # Structured log viewer (Settings)
│       └── MenuBarStatusView.swift        # Menu bar status indicator
├── Tests/BackupBotTests/
│   ├── ChunkerTests.swift                 # 16 chunking/encryption tests
│   ├── MTProtoClientTests.swift           # 15 auth/upload/retry tests
│   └── SyncEngineTests.swift             # 21 orchestration tests
└── Tests/BackupBotUITests/
    └── BackupBotUITests.swift             # UI tests for folder add & auth flows
```

## Setup (Xcode Project)

This source tree does not include an `.xcodeproj` file. To build in Xcode:

1. Create a new Xcode project: **File > New > Project > macOS > App**
2. Product Name: `BackupBot`, Interface: **SwiftUI**, Language: **Swift**
3. Deployment Target: **macOS 14.0**
4. Delete the auto-generated `ContentView.swift` and `BackupBotApp.swift`
5. Copy the entire `Sources/BackupBot/` directory into the project navigator
6. Copy `Entitlements/BackupBot.entitlements` and assign it in Build Settings > Code Signing
7. Add SwiftData models to the app target's Compile Sources
8. Add a unit test target, copy `Tests/BackupBotTests/` into it
9. Add a UI test target, copy `Tests/BackupBotUITests/` into it
10. Build and run

### Entitlements Required

| Entitlement | Purpose |
|---|---|
| `com.apple.security.app-sandbox` | App Sandbox isolation |
| `com.apple.security.files.user-selected.read-write` | Security-scoped bookmarks for folder access |
| `com.apple.security.network.client` | Outbound connections to Telegram servers |
| `com.apple.security.keychain` | Store encryption key and session data |

## MTProto Integration

The `MTProtoClient.swift` includes a `MTProtoTransport` protocol and a production
`TelegramMTProtoTransport` backed by the telegram-ios library. The transport handles:

- MTProto transport (TCP with obfuscation via NWConnection)
- API schema (TL serialization via TelegramCore)
- Auth flow (DH key exchange)
- Session key management (persistent auth keys in Keychain)
- File upload pipeline (`upload.saveBigFilePart`)

The `TelegramMTProtoTransport` replaces the previous placeholder `URLSessionMTProtoTransport`.
It establishes real TCP connections to Telegram data centers, performs the full DH key
exchange, and encrypts messages using AES-256-IGE per the MTProto 2.0 specification.

For testing, pass a custom `MTProtoTransport` to `MTProtoClientService.init(transport:)`.

## New Features

### Upload History Viewer

The **Upload History Viewer** (`UploadHistoryViewer.swift`) provides a complete
timeline of every upload operation for each folder, with the following capabilities:

- **Per-chunk status tracking**: Pending, Uploading, Completed, Failed, Cancelled, Retrying
- **Retry controls**: Right-click or use the "Retry All Failed" button to re-queue failed uploads
- **Cancel controls**: Right-click or use the "Cancel All Active" button to abort in-progress uploads
- **Filtering**: Filter by status (Active, Done, Failed, Cancelled)
- **Sorting**: Sort by newest, oldest, largest, or status
- **Detailed metrics**: Duration, upload speed, retry count, and error messages

Access via the "Upload History" button in the Folder Detail view.

### Structured Logging Viewer

The **Structured Log Viewer** (`StructuredLogViewer.swift`) is accessible from
Settings > Logs and provides:

- **Severity filtering**: Error, Warning, Info, Debug
- **Category filtering**: SyncEngine, Chunker, MTProto, FileMonitor, Keychain, UI
- **Full-text search**: Search across all log messages
- **Auto-refresh**: Optional 5-second live-updating stream
- **Export**: Save filtered entries to a `.log` file
- **Detail view**: Double-click any entry for full metadata (timestamp, category, severity, thread, process)

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Encryption | AES-256-GCM | CryptoKit native, authenticated encryption |
| Key storage | macOS Keychain | Simplest viable, random 256-bit key |
| Upload mode | Full rebuild | Simpler than incremental sync |
| Chunk size | 700 MB (configurable) | Below Telegram bot limit |
| Sync direction | Unidirectional | No risk of data loss from Telegram |
| Deletion | Approval-required | User confirms before any local deletion |
| Concurrency | 1 concurrent upload | Simplifies error handling, upgradeable |
| Cache cleanup | Manual | User-triggered via Settings UI |
| MTProto Transport | TelegramMTProtoTransport | Production TCP with DH key exchange |
| Upload history | SwiftData model | Persistent, queryable, cascade-deleted |

## Usage

1. **Configure Telegram**: Open Settings > Telegram, enter API ID, API Hash, and Forum Chat ID
2. **Authenticate**: Tap "Connect" and complete the phone number → code → 2FA flow
3. **Add Folder**: Use File > Add Folder (⌘N) to select a Mac folder to back up
4. **Start Backup**: Use Backup > Start Backup (⌘⇧B) or click Start in the folder detail view
5. **Monitor Progress**: The sidebar shows live status; the detail view shows per-chunk progress
6. **Review History**: Use the Upload History viewer for detailed retry/cancel controls
7. **Inspect Logs**: Open Settings > Logs for structured log viewing and export

## Dry-Run Mode

Toggle dry-run in Settings > General or use the menu shortcut ⌘⌥D. In dry-run mode:
- Folders are scanned and enumerated
- Chunks are created and encrypted (stored in cache)
- No files are uploaded to Telegram
- Cache contents are available for inspection before committing to a real upload

## License

This project is provided as-is for educational and personal use.
