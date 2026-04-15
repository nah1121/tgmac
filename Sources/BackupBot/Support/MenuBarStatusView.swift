import SwiftUI
import SwiftData

/// Menu bar extra that displays backup status when the app runs in the background.
/// Provides quick-access controls without opening the main window.
struct MenuBarStatusView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncEngineService.self) private var syncEngine
    @Query(filter: #Predicate<SyncFolder> { $0.isActive }, sort: \SyncFolder.createdAt)
    private var activeFolders: [SyncFolder]

    @State private var lastSyncSummary: String = "No backups yet"

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                activeFolders: activeFolders,
                syncEngine: syncEngine,
                lastSyncSummary: lastSyncSummary
            )
        } label: {
            Label("BackupBot", systemImage: menuBarIcon)
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// Dynamic icon based on overall sync state.
    private var menuBarIcon: String {
        if syncEngine.isSyncing {
            return "arrow.triangle.2.circlepath"
        }

        let hasError = activeFolders.contains { $0.syncStatus == .error }
        if hasError {
            return "exclamationmark.triangle.fill"
        }

        let allCompleted = activeFolders.allSatisfy { $0.syncStatus == .completed || $0.syncStatus == .pending }
        if allCompleted && !activeFolders.isEmpty {
            return "checkmark.circle.fill"
        }

        return "folder.badge.gearshape"
    }
}

// MARK: - Menu Bar Content

private struct MenuBarContent: View {
    let activeFolders: [SyncFolder]
    let syncEngine: SyncEngineService
    let lastSyncSummary: String

    var body: some View {
        // Status header
        VStack(alignment: .leading, spacing: 4) {
            Text("BackupBot")
                .font(.headline)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)

        Divider()

        // Folder list
        if activeFolders.isEmpty {
            Text("No folders configured")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(activeFolders) { folder in
                FolderMenuItem(folder: folder)
            }
        }

        Divider()

        // Quick actions
        Button(action: {
            Task { await syncEngine.syncAll(folders: activeFolders, modelContext: nil) }
        }) {
            Label("Start Backup All", systemImage: "play.fill")
        }
        .disabled(syncEngine.isSyncing || activeFolders.isEmpty)

        Button(action: {
            syncEngine.cancelAll()
        }) {
            Label("Stop All", systemImage: "stop.fill")
        }
        .disabled(!syncEngine.isSyncing)

        Divider()

        Button(action: { NSApp.activate(ignoringOtherApps: true) }) {
            Label("Open BackupBot", systemImage: "macwindow")
        }

        Button(action: { NSApp.terminate(nil) }) {
            Label("Quit BackupBot", systemImage: "power")
        }
    }

    private var statusText: String {
        if syncEngine.isSyncing {
            return "Backup in progress..."
        }
        let errors = activeFolders.filter { $0.syncStatus == .error }
        if !errors.isEmpty {
            return "\(errors.count) folder(s) with errors"
        }
        return "\(activeFolders.count) folder(s) monitored"
    }
}

// MARK: - Folder Menu Item

private struct FolderMenuItem: View {
    let folder: SyncFolder

    var body: some View {
        HStack {
            Image(systemName: folder.syncStatus.systemImage)
                .foregroundStyle(colorForStatus(folder.syncStatus))
                .frame(width: 16)

            VStack(alignment: .leading) {
                Text(folder.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func colorForStatus(_ status: SyncStatus) -> Color {
        switch status {
        case .pending: .secondary
        case .scanning: .blue
        case .chunking: .orange
        case .uploading: .cyan
        case .completed: .green
        case .error: .red
        case .paused: .yellow
        }
    }

    private var statusText: String {
        switch folder.syncStatus {
        case .pending:
            return "Ready"
        case .completed:
            return "Last synced: \(formattedDate(folder.lastSyncDate))"
        case .error:
            return folder.errorMessage ?? "Unknown error"
        case .uploading:
            return "Uploading: \(Int(folder.progress * 100))%"
        case .scanning:
            return "Scanning files..."
        case .chunking:
            return "Creating chunks..."
        case .paused:
            return "Paused"
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Notification Support

extension MenuBarStatusView {
    /// Post a user notification for a sync event.
    static func postNotification(title: String, body: String, isCritical: Bool = false) {
        let notification = UNUserNotification()
        notification.title = title
        notification.body = body
        notification.soundName = isCritical ? UNNotificationSound.defaultCritical : UNNotificationSound.default

        // UNUserNotificationCenter requires the user to grant permission.
        // The app should request notification permission on first launch.
        UNUserNotificationCenter.current().add(notification) { error in
            if let error {
                Logger.ui.error("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - UNUserNotification Shims
// These are placeholder types to allow compilation without importing UserNotifications.
// In the real Xcode project, import UserNotifications and use UNUserNotificationContent/UNNotificationRequest.

private final class UNUserNotification {
    var title: String = ""
    var body: String = ""
    var soundName: Any?
}

private final class UNNotificationSound {
    static let `default` = UNNotificationSound()
    static let defaultCritical = UNNotificationSound()
}

private final class UNUserNotificationCenter {
    static let current = UNUserNotificationCenter()

    func add(_ notification: UNUserNotification, completionHandler: ((Error?) -> Void)? = nil) {
        completionHandler?(nil)
    }
}
