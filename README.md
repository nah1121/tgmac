# Telegram Samsung Backup Bot (macOS)

SwiftUI macOS app that monitors Samsung Smart Switch backup folders, maps each folder to a Telegram forum topic, chunks and encrypts files, and uploads them through the Telegram User API. The app is designed for App Sandbox, using security-scoped bookmarks so folder access persists across launches.

## Status
- ✅ App shell, SwiftData models, and folder picker flow are complete
- ✅ Core services implemented: FileMonitor, Chunker (AES-GCM), MTProtoClient (mock), SyncEngine
- ✅ Security-scoped bookmarks with SecureBookmark utility
- ✅ Complete UI with folder list, progress tracking, and settings
- ✅ Telegram authentication flow with phone number verification
- ✅ Entitlements file for App Sandbox

## Features (implemented)
- Select Smart Switch backup folders via a sandbox-friendly folder picker that stores security-scoped bookmarks
- Map each folder to a Telegram forum topic with hash-aware name truncation
- Chunk and AES-GCM encrypt archives (<=700 MB) with manifests for resumable uploads
- Upload through the Telegram User API with retry/backoff handling for FloodWait
- Track per-folder and per-topic progress via SwiftData; support dry-run mode
- Real-time FSEvents monitoring with debouncing
- Complete Telegram authentication UI (phone → code → 2FA password)
- Settings for chunk size, auto-start, notifications, and API credentials

## Requirements
- macOS 14+ and Xcode 15+ with Swift 5.9.
- Telegram API ID and API Hash, plus the forum chat ID of the target group with topics enabled.
- App Sandbox entitlements for user-selected file access (security-scoped bookmarks) and network access.

## Project Structure
- `BackupBotApp.swift`: SwiftUI app entry point, model container setup, commands, settings tabs with Telegram auth UI
- `ContentView.swift`: Main UI with folder list, progress bars, detail view, and sync controls
- `AddFolderView.swift`: Smart Switch folder picker, bookmark storage, topic name generation, and folder statistics
- `Models/SyncFolder.swift`: SwiftData entity for tracked folders, progress helpers, and security-scoped URL resolution
- `Models/TopicMapping.swift`: Telegram topic metadata, upload progress tracking, and state management
- `Models/FileRecord.swift`: Per-file metadata including path, size, hash, chunk count, and upload status
- `Utilities/SecureBookmark.swift`: Thread-safe security-scoped bookmark persistence and resolution
- `Services/FileMonitor.swift`: FSEvents-based file monitoring with debouncing and event coalescing
- `Services/Chunker.swift`: AES-GCM encryption, SHA-256 hashing, and 700MB chunk creation with manifests
- `Services/MTProtoClient.swift`: Telegram MTProto client with authentication, topic management, and file uploads (mock implementation)
- `Services/SyncEngine.swift`: Orchestrates backup workflow: scanning, chunking, uploading with retry logic
- `BackupBot.entitlements`: App Sandbox entitlements for file access and network

## Usage (conceptual)
1) Open the project in Xcode 15+ on macOS 14+ and ensure sandbox entitlements include user-selected file read/write and outbound network access.  
2) Run the app and choose **Add Folder** to pick your Smart Switch backup directory; a security-scoped bookmark is saved.  
3) Go to Settings → Telegram tab, enter API ID, API Hash, Forum Chat ID, and phone number, then authenticate via the verification code flow.  
4) Start the backup to scan, chunk, and upload; use dry-run to validate the plan without uploading.  
5) Relaunching the app restores bookmarks so uploads can resume without reselecting folders.

## Notes and Next Steps
- Replace mock MTProtoClient with real telegram-ios library integration for production use
- Add per-chunk SHA-256 verification UI in folder detail view
- Implement upload history viewer with retry/cancel controls
- Add structured logging viewer in settings
- Consider parallel uploads (currently single-threaded per design)
- Add unit tests for Chunker encryption round-trip and manifest generation
- Add UI tests for folder add flow and authentication sequence
