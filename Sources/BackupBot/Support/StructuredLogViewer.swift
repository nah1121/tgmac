import SwiftUI
import os

/// Structured logging viewer integrated into Settings.
///
/// Provides a searchable, filterable view of the app's structured log output.
/// Entries are captured from the unified logging system (os_log) and displayed
/// with color-coded severity levels, category badges, and timestamp details.
///
/// ## Features
/// - **Severity filtering**: Error, Warning, Info, Debug
/// - **Category filtering**: SyncEngine, Chunker, MTProto, FileMonitor, UI
/// - **Full-text search**: Search across all log message content
/// - **Auto-refresh**: Optional live-updating log stream
/// - **Export**: Save filtered entries to a `.log` file
/// - **Clear**: Purge in-memory log entries
struct StructuredLogViewer: View {
    @State private var logEntries: [StructuredLogEntry] = []
    @State private var isLoading = false
    @State private var selectedCategory: LogCategory = .all
    @State private var selectedSeverity: LogSeverity = .all
    @State private var searchText = ""
    @State private var autoRefresh = false
    @State private var refreshTimer: Timer?
    @State private var selectedEntry: StructuredLogEntry?
    @State private var showingDetail = false
    @State private var isExporting = false

    // MARK: - Types

    enum LogCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case syncEngine = "SyncEngine"
        case chunker = "Chunker"
        case mtproto = "MTProto"
        case fileMonitor = "FileMonitor"
        case keychain = "Keychain"
        case secureBookmark = "SecureBookmark"
        case ui = "UI"

        var id: String { rawValue }

        var displayName: String { rawValue }

        var systemImage: String {
            switch self {
            case .all:           "list.bullet"
            case .syncEngine:    "arrow.triangle.2.circlepath"
            case .chunker:       "doc.zip"
            case .mtproto:       "paperplane"
            case .fileMonitor:   "eye"
            case .keychain:      "key"
            case .secureBookmark:"bookmark"
            case .ui:            "macwindow"
            }
        }

        var color: Color {
            switch self {
            case .all:           .gray
            case .syncEngine:    .blue
            case .chunker:       .orange
            case .mtproto:       .purple
            case .fileMonitor:   .green
            case .keychain:      .yellow
            case .secureBookmark:.teal
            case .ui:            .cyan
            }
        }

        var subsystemCategory: String? {
            switch self {
            case .all: nil
            default: rawValue
            }
        }
    }

    enum LogSeverity: String, CaseIterable, Identifiable {
        case all = "All"
        case error = "Error"
        case warning = "Warning"
        case info = "Info"
        case debug = "Debug"

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .all:    .gray
            case .error:  .red
            case .warning:.orange
            case .info:   .blue
            case .debug:  .secondary
            }
        }
    }

    struct StructuredLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: String
        let severity: String
        let message: String
        let subsystem: String
        let threadID: UInt64
        let processID: Int32

        var severityLevel: LogSeverity {
            switch severity.lowercased() {
            case "error":   return .error
            case "warning", "warn": return .warning
            case "info":    return .info
            case "debug":   return .debug
            default:        return .info
            }
        }

        var categoryEnum: LogCategory {
            LogCategory.allCases.first { $0.rawValue == category } ?? .all
        }

        var formattedTimestamp: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter.string(from: timestamp)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
            Divider()

            // Content area
            contentArea
            Divider()

            // Status bar
            statusBar
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await refreshLogs()
        }
        .onChange(of: autoRefresh) { _, newValue in
            if newValue {
                startAutoRefresh()
            } else {
                stopAutoRefresh()
            }
        }
        .onChange(of: selectedCategory) { _, _ in
            Task { await refreshLogs() }
        }
        .sheet(isPresented: $showingDetail) {
            if let entry = selectedEntry {
                LogEntryDetailSheet(entry: entry)
            }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            // Category picker
            Picker("Category", selection: $selectedCategory) {
                ForEach(LogCategory.allCases) { cat in
                    Label(cat.displayName, systemImage: cat.systemImage)
                        .tag(cat)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 150)

            // Severity picker
            Picker("Severity", selection: $selectedSeverity) {
                ForEach(LogSeverity.allCases) { sev in
                    HStack {
                        Circle().fill(sev.color).frame(width: 8, height: 8)
                        Text(sev.rawValue)
                    }
                    .tag(sev)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 250)

            // Search
            TextField("Search logs...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Spacer()

            // Auto-refresh toggle
            Toggle("Auto", isOn: $autoRefresh)
                .toggleStyle(.checkbox)
                .help("Auto-refresh log entries every 5 seconds")

            // Refresh button
            Button(action: { Task { await refreshLogs() } }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)

            // Clear button
            Button(action: clearLogs) {
                Label("Clear", systemImage: "trash")
            }
            .disabled(logEntries.isEmpty)

            // Export button
            Button(action: exportLogs) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(logEntries.isEmpty || isExporting)
            .help("Export filtered log entries to a file")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if isLoading && logEntries.isEmpty {
            Spacer()
            ProgressView("Loading log entries...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer()
        } else if filteredEntries.isEmpty {
            ContentUnavailableView(
                "No Log Entries",
                systemImage: "text.magnifyingglass",
                description: Text(logEntries.isEmpty
                    ? "Log entries will appear here once the app generates logs."
                    : "No entries match your current filter criteria."
                )
            )
        } else {
            ScrollViewReader { proxy in
                List(filteredEntries) { entry in
                    StructuredLogRow(entry: entry)
                        .id(entry.id)
                        .onTapGesture(count: 2) {
                            selectedEntry = entry
                            showingDetail = true
                        }
                }
                .listStyle(.plain)
                .onChange(of: logEntries.count) { _, _ in
                    if let last = filteredEntries.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Status Bar

    @ViewBuilder
    private var statusBar: some View {
        HStack {
            Text("\(filteredEntries.count) of \(logEntries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let firstEntry = logEntries.first {
                Text("From \(firstEntry.formattedTimestamp)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if autoRefresh {
                Label("Live", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if isExporting {
                ProgressView()
                    .controlSize(.small)
                Text("Exporting...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Filtering

    private var filteredEntries: [StructuredLogEntry] {
        var result = logEntries

        // Category filter
        if selectedCategory != .all, let cat = selectedCategory.subsystemCategory {
            result = result.filter { $0.category == cat }
        }

        // Severity filter
        if selectedSeverity != .all {
            result = result.filter { $0.severityLevel == selectedSeverity }
        }

        // Search filter
        if !searchText.isEmpty {
            result = result.filter {
                $0.message.localizedCaseInsensitiveContains(searchText) ||
                $0.category.localizedCaseInsensitiveContains(searchText) ||
                $0.subsystem.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    // MARK: - Actions

    private func refreshLogs() async {
        isLoading = true
        defer { isLoading = false }

        await MainActor.run {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "show",
                "--predicate", "subsystem == 'com.nah1121.BackupBot'",
                "--style", "compact",
                "--last", "5m"
            ]
            process.standardOutput = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    parseLogOutput(output)
                }
            } catch {
                Logger.ui.error("Failed to read logs: \(error.localizedDescription)")
            }
        }
    }

    private func parseLogOutput(_ output: String) {
        let lines = output.components(separatedBy: "\n")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"

        let newEntries = lines.compactMap { line -> StructuredLogEntry? in
            guard !line.isEmpty else { return nil }

            let components = line.components(separatedBy: " ", maxSplits: 4)
            guard components.count >= 4 else { return nil }

            let timestamp = formatter.date(from: components[0]) ?? Date()

            var category = "Unknown"
            if let catStart = components[1].range(of: "["),
               let catEnd = components[1].range(of: "]") {
                category = String(components[1][catStart.upperBound..<catEnd.lowerBound])
            }

            let severity = components.count > 2 ? components[2] : "default"
            let message = components.dropFirst(3).joined(separator: " ")

            return StructuredLogEntry(
                timestamp: timestamp,
                category: category,
                severity: severity,
                message: message,
                subsystem: "com.nah1121.BackupBot",
                threadID: 0,
                processID: ProcessInfo.processInfo.processIdentifier
            )
        }

        let existingTimestamps = Set(logEntries.map { $0.timestamp })
        let uniqueNew = newEntries.filter { !existingTimestamps.contains($0.timestamp) }

        logEntries.append(contentsOf: uniqueNew)

        // Keep only the last 2000 entries
        if logEntries.count > 2000 {
            logEntries = Array(logEntries.suffix(2000))
        }
    }

    private func clearLogs() {
        logEntries.removeAll()
    }

    private func exportLogs() {
        isExporting = true

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "backupbot-structured-log-\(ISO8601DateFormatter().string(from: Date())).log"
        panel.allowedContentTypes = [.init(filenameExtension: "log")!]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                isExporting = false
                return
            }

            let content = filteredEntries.map { entry in
                let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
                return "[\(timestamp)] [\(entry.category)] [\(entry.severity)] \(entry.message)"
            }.joined(separator: "\n")

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                Logger.ui.info("Exported \(self.filteredEntries.count) structured log entries to \(url.path)")
            } catch {
                Logger.ui.error("Failed to export structured logs: \(error.localizedDescription)")
            }

            isExporting = false
        }
    }

    // MARK: - Auto-Refresh

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { await self.refreshLogs() }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Structured Log Row

private struct StructuredLogRow: View {
    let entry: StructuredLogViewer.StructuredLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Severity indicator
            Circle()
                .fill(severityColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
                .help(entry.severity)

            // Timestamp
            Text(entry.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            // Category badge
            Text(entry.category)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(categoryColor.opacity(0.15))
                .foregroundStyle(categoryColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 90, alignment: .leading)

            // Message
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .foregroundStyle(messageColor)
        }
        .padding(.vertical, 3)
    }

    private var severityColor: Color {
        entry.severityLevel.color
    }

    private var categoryColor: Color {
        entry.categoryEnum.color
    }

    private var messageColor: Color {
        switch entry.severityLevel {
        case .error:   return .red
        case .warning: return .orange
        default:       return .primary
        }
    }
}

// MARK: - Log Entry Detail Sheet

private struct LogEntryDetailSheet: View {
    let entry: StructuredLogViewer.StructuredLogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Log Entry Detail")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            // Metadata
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Timestamp:")
                        .fontWeight(.medium)
                    Text(ISO8601DateFormatter().string(from: entry.timestamp))
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Category:")
                        .fontWeight(.medium)
                    Text(entry.category)
                }
                GridRow {
                    Text("Severity:")
                        .fontWeight(.medium)
                    HStack(spacing: 6) {
                        Circle().fill(entry.severityLevel.color).frame(width: 8, height: 8)
                        Text(entry.severity)
                    }
                }
                GridRow {
                    Text("Subsystem:")
                        .fontWeight(.medium)
                    Text(entry.subsystem)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Process ID:")
                        .fontWeight(.medium)
                    Text("\(entry.processID)")
                }
            }

            Divider()

            // Full message
            VStack(alignment: .leading, spacing: 8) {
                Text("Message:")
                    .fontWeight(.medium)
                ScrollView {
                    Text(entry.message)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()

            // Copy button
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.message, forType: .string)
                } label: {
                    Label("Copy Message", systemImage: "doc.on.doc")
                }
            }
        }
        .padding()
        .frame(width: 500, height: 420)
    }
}
