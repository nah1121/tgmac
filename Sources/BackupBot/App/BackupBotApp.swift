import SwiftUI
import SwiftData
import os

// MARK: - Main App Entry Point

@main
struct BackupBotApp: App {
    // Shared service instances (created once, injected into views)
    let chunker = ChunkerService()
    let mtprotoClient = MTProtoClientService()
    let fileMonitor = FileMonitorService()
    let syncEngine: SyncEngineService

    @Environment(\.scenePhase) private var scenePhase

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([SyncFolder.self, TopicMapping.self, FileRecord.self, UploadHistoryRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        let engine = SyncEngineService(
            chunker: chunker,
            mtprotoClient: mtprotoClient,
            fileMonitor: fileMonitor
        )
        self.syncEngine = engine

        // Configure encryption key on launch
        do {
            let encryptionKey = try KeychainHelper.getOrCreateEncryptionKey()
            Task {
                await chunker.configureEncryptionKey(encryptionKey)
            }
        } catch {
            Logger.syncEngine.error("Failed to configure encryption key: \(error.localizedDescription)")
        }

        // Restore secure bookmarks on launch
        SecureBookmark.shared.restoreAllBookmarks()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(chunker)
                .environment(mtprotoClient)
                .environment(syncEngine)
                .environment(fileMonitor)
                .frame(minWidth: 1000, minHeight: 700)
        }
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Remove default New File menu items — folders are added via UI
            }
            CommandGroup(replacing: .toolbar) {
                Button("Start Backup", systemImage: "play.fill") {
                    NotificationCenter.default.post(name: .startBackup, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Stop Backup", systemImage: "stop.fill") {
                    NotificationCenter.default.post(name: .stopBackup, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command])

                Divider()

                Button("Toggle Dry Run", systemImage: "eye") {
                    NotificationCenter.default.post(name: .toggleDryRun, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                SecureBookmark.shared.saveAllBookmarks()
            }
        }
        Settings {
            SettingsTab()
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let startBackup = Notification.Name("startBackup")
    static let stopBackup = Notification.Name("stopBackup")
    static let toggleDryRun = Notification.Name("toggleDryRun")
}

// MARK: - Settings Tab View

struct SettingsTab: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            TelegramSettingsView()
                .tabItem {
                    Label("Telegram", systemImage: "paperplane")
                }

            StructuredLogViewer()
                .tabItem {
                    Label("Logs", systemImage: "list.bullet.clipboard")
                }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
