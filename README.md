# Telegram Samsung Backup Bot (macOS)

SwiftUI macOS app that monitors Samsung Smart Switch backup folders, maps each folder to a Telegram forum topic, chunks and encrypts files, and uploads them through the Telegram User API. The app is designed for App Sandbox, using security-scoped bookmarks so folder access persists across launches.

## Status
- App shell, SwiftData models, and folder picker flow are present.
- Core services for monitoring, chunking/encryption, MTProto uploads, and orchestration are scaffolded but still need full implementations.

## Features (intended)
- Select Smart Switch backup folders via a sandbox-friendly folder picker that stores security-scoped bookmarks.
- Map each folder to a Telegram forum topic with hash-aware name truncation.
- Chunk and AES-encrypt archives (<=700 MB) with manifests to support resumable uploads.
- Upload through the Telegram User API with retry/backoff handling for FloodWait.
- Track per-folder and per-topic progress via SwiftData; support dry-run mode.

## Requirements
- macOS 14+ and Xcode 15+ with Swift 5.9.
- Telegram API ID and API Hash, plus the forum chat ID of the target group with topics enabled.
- App Sandbox entitlements for user-selected file access (security-scoped bookmarks) and network access.

## Project Structure
- `BackupBotApp.swift`: SwiftUI app entry point, model container setup, commands, and settings tabs.
- `ContentView.swift`: placeholder for the main UI surface.
- `AddFolderView.swift`: Smart Switch folder picker, bookmark storage, and initial topic name generation.
- `Models/SyncFolder.swift`: SwiftData entity for tracked folders and progress helpers.
- `Models/TopicMapping.swift`: Telegram topic metadata and upload progress tracking.
- `Models/FileRecord.swift`: placeholder for per-file metadata.
- `Services/FileMonitor.swift`, `Services/Chunker.swift`, `Services/MTProtoClient.swift`, `Services/SyncEngine.swift`: service scaffolding for FSEvents monitoring, chunking/encryption, MTProto uploads, and orchestration.

## Usage (conceptual)
1) Open the project in Xcode 15+ on macOS 14+ and ensure sandbox entitlements include user-selected file read/write and outbound network access.  
2) Run the app and choose **Add Folder** to pick your Smart Switch backup directory; a security-scoped bookmark is saved.  
3) Provide Telegram API ID, API Hash, and the forum chat ID; confirm or adjust the topic name per folder.  
4) Start the backup to scan, chunk, and upload; use dry-run to validate the plan without uploading.  
5) Relaunching the app restores bookmarks so uploads can resume without reselecting folders.

## Notes and Next Steps
- Implement the service layers (file monitoring, chunker, MTProto client, sync engine) and add Swift unit/UI tests as they are built out.
- Consider per-chunk SHA-256 verification and a small status UI for history and error recovery.
