import SwiftUI
import SwiftData
import OSLog

@main
struct BackupBotApp: App {
    private let logger = Logger(subsystem: "com.backupbot.app", category: "AppLifecycle")
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        SecureBookmark.shared.restoreAllBookmarks()
        logger.info("BackupBotApp initialized, restored secure bookmarks")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 700)
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    if newPhase == .background {
                        SecureBookmark.shared.saveAllBookmarks()
                        logger.debug("App entering background, saved secure bookmarks")
                    }
                }
        }
        .modelContainer(for: [SyncFolder.self, FileRecord.self, TopicMapping.self])
        .commands {
            CommandMenu("Backup") {
                Button("Start Backup") {
                    NotificationCenter.default.post(name: .init("StartBackup"), object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                
                Button("Stop Backup") {
                    NotificationCenter.default.post(name: .init("StopBackup"), object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command])
                
                Divider()
                
                Button("Toggle Dry Run") {
                    NotificationCenter.default.post(name: .init("ToggleDryRun"), object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                
                Divider()
                
                Button("Rescan Folders") {
                    NotificationCenter.default.post(name: .init("RescanFolders"), object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            
            CommandGroup(replacing: .appInfo) {
                Button("About Backup Bot") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: "Telegram Samsung Backup Bot\nVersion 1.0\n\nLocal-first backup utility for Samsung Smart Switch backups",
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 11),
                                    .foregroundColor: NSColor.secondaryLabelColor
                                ]
                            )
                        ]
                    )
                }
            }
        }
        
        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            TelegramSettingsView()
                .tabItem {
                    Label("Telegram", systemImage: "paperplane.fill")
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("Backup Bot Configuration")
                    .font(.headline)
                Text("Configure backup sources and chunking preferences in the main window")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

struct TelegramSettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("Telegram API Configuration")
                    .font(.headline)
                Text("Set your API ID, API Hash, and Forum Chat ID in the main interface")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}