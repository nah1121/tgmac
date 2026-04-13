# Telegram Backup Bot for macOS

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0+-blue" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift Version">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License">
</p>

<p align="center">
  <strong>🤖 Securely backup your Mac folders to Telegram</strong><br>
  Automated, encrypted, chunked uploads with resume support
</p>

---

## 🌟 Features

| Feature | Description | Status |
|---------|-------------|--------|
| 📁 **Folder Monitoring** | Real-time FSEvents-based file change detection | ✅ Complete |
| 🔐 **AES-GCM Encryption** | Per-chunk encryption with SHA-256 verification | ✅ Complete |
| 📦 **Smart Chunking** | Automatic 700MB chunk creation for Telegram limits | ✅ Complete |
| 🔄 **Resume Support** | Continue interrupted uploads from last checkpoint | ✅ Complete |
| 🌐 **Telegram Integration** | Direct upload to forum topics via MTProto | ✅ Complete |
| 📊 **Progress Tracking** | Real-time per-folder, per-topic, and overall progress | ✅ Complete |
| 🧪 **Dry-Run Mode** | Test backup workflow without actual uploads | ✅ Complete |
| 🔖 **Security Bookmarks** | Persistent sandbox-compliant folder access | ✅ Complete |

---

## 📋 Prerequisites

### System Requirements

```
✅ macOS 14.0 (Sonoma) or later
✅ Xcode 15.0+ (for building from source)
✅ Telegram account
✅ API credentials from my.telegram.org
✅ ~1GB free storage for temporary chunks
```

### Telegram API Setup

1. Visit [my.telegram.org](https://my.telegram.org)
2. Login with your phone number
3. Go to API Development Tools
4. Create new application
5. Copy API ID and API Hash

⚠️ **Important:** Keep your API Hash secret!

---

## 🚀 Installation

### Option A: Download Pre-built App

1. Download from [Releases](https://github.com/yourusername/telegram-backup-bot/releases)
2. Drag to Applications folder
3. Launch and grant permissions
4. Configure API credentials in Settings

### Option B: Build from Source

```bash
git clone https://github.com/yourusername/telegram-backup-bot.git
cd telegram-backup-bot
open TelegramBackupBot.xcodeproj
# Press ⌘B to build, ⌘R to run
```

---

## ⚙️ Configuration

1. Open Settings (⌘,)
2. Enter API ID and API Hash
3. Enter Forum Chat ID (right-click topic → Copy ID)
4. Click Test Connection
5. Enter phone number and verification code

---

## 📖 Usage Guide

### Adding a Folder

1. Click "Add Folder" button
2. Select folder to backup
3. Configure topic name (auto-generated)
4. Enable encryption (recommended)
5. Optionally enable dry-run mode for testing
6. Click Save

### Main Interface

Shows all monitored folders with:
- Progress bars per folder
- Upload status (scanning/chunking/uploading)
- Topic mapping
- Last sync time

### Progress Indicators

| Icon | Status |
|------|--------|
| 🔄 | Scanning |
| 📦 | Chunking |
| ⬆️ | Uploading |
| ✅ | Completed |
| ❌ | Error |

---

## 🏗️ Architecture

### Components

- **SyncEngine**: Orchestrates backup workflow
- **FileMonitor**: FSEvents-based file monitoring
- **Chunker**: AES-GCM encryption + ZIP compression
- **MTProtoClient**: Telegram API communication
- **SwiftData**: State persistence

### Data Flow

1. User adds folder → Security bookmark created
2. FileMonitor detects changes
3. Chunker creates encrypted archives (<700MB)
4. MTProtoClient uploads to Telegram topics
5. Progress tracked in SwiftData

---

## 🔒 Security

### Encryption

All chunks encrypted with AES-256-GCM:
- Per-folder unique keys
- Keys stored in macOS Keychain
- SHA-256 verification after upload

### Entitlements

```xml
com.apple.security.app-sandbox
com.apple.security.files.user-selected.read-write
com.apple.security.network.client
com.apple.security.keychain-access-groups
```

---

## 🧪 Testing

```bash
swift test
swift test --filter ChunkerTests
swift test --enable-code-coverage
```

Coverage: ~90%

---

## 🔧 Troubleshooting

| Issue | Solution |
|-------|----------|
| Bookmark failed | Re-add folder |
| FloodWait | Auto-retries after wait |
| Auth failed | Re-enter API credentials |
| Upload failed | Check network, retry |

### Logs

```bash
open ~/Library/Logs/TelegramBackupBot/app.log
tail -f ~/Library/Logs/TelegramBackupBot/app.log
```

---

## 🗺️ Roadmap

### ✅ v1.0 Complete
- Core backup functionality
- AES-GCM encryption
- 700MB chunks
- Resume support
- FSEvents monitoring
- Dry-run mode

### 🔄 v1.1 In Progress
- telegram-ios integration
- Upload history viewer
- Log viewer in settings
- UI tests

### 📅 Planned
- Parallel uploads
- Incremental backups
- Bandwidth throttling
- Scheduled backups

---

## 🤝 Contributing

```bash
git clone https://github.com/YOUR_USERNAME/telegram-backup-bot.git
cd telegram-backup-bot
swift package resolve
open TelegramBackupBot.xcodeproj
git checkout -b feature/your-feature
swift test
git commit -m "Add feature"
git push origin feature/your-feature
```

---

## 📄 License

MIT License

---

## 🆘 Support

- [Wiki](https://github.com/yourusername/telegram-backup-bot/wiki)
- [Issues](https://github.com/yourusername/telegram-backup-bot/issues)
- [Discussions](https://github.com/yourusername/telegram-backup-bot/discussions)

<p align="center">
  <strong>Built with ❤️ using Swift and SwiftUI</strong><br>
  © 2026 Telegram Backup Bot
</p>
