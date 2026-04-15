import SwiftUI
import os

/// Diagnostics panel for viewing and exporting application logs.
/// Accessible from Settings > General > Diagnostics.
struct DiagnosticsView: View {
    @State private var logEntries: [LogEntry] = []
    @State private var isLoading = false
    @State private var selectedCategory: LogCategory = .all
    @State private var searchText = ""
    @State private var autoRefresh = false
    @State private var refreshTimer: Timer?

    enum LogCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case syncEngine = "SyncEngine"
        case chunker = "Chunker"
        case mtproto = "MTProto"
        case fileMonitor = "FileMonitor"
        case ui = "UI"

        var id: String { rawValue }

        var subsystemCategory: String? {
            switch self {
            case .all: nil
            case .syncEngine: "SyncEngine"
            case .chunker: "Chunker"
            case .mtproto: "MTProto"
            case .fileMonitor: "FileMonitor"
            case .ui: "UI"
            }
        }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: String
        let level: String
        let message: String
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Diagnostics")
                    .font(.headline)

                Spacer()

                Picker("Category", selection: $selectedCategory) {
                    ForEach(LogCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                TextField("Search logs...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Toggle("Auto", isOn: $autoRefresh)
                    .toggleStyle(.checkbox)
                    .help("Auto-refresh log entries")

                Button(action: { Task { await refreshLogs() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)

                Button(action: exportLogs) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export log entries to a text file")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Log entries list
            if isLoading && logEntries.isEmpty {
                Spacer()
                ProgressView("Loading log entries...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No Logs",
                    systemImage: "text.magnifyingglass",
                    description: Text("No log entries match your filter criteria.")
                )
            } else {
                ScrollViewReader { proxy in
                    List(filteredEntries) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                            .tag(entry.id)
                    }
                    .onChange(of: logEntries.count) { _, _ in
                        if let last = logEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Status bar
            HStack {
                Text("\(filteredEntries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if autoRefresh {
                    Text("Auto-refreshing")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
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
    }

    // MARK: - Filtering

    private var filteredEntries: [LogEntry] {
        var result = logEntries

        if selectedCategory != .all, let cat = selectedCategory.subsystemCategory {
            result = result.filter { $0.category == cat }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.message.localizedCaseInsensitiveContains(searchText) ||
                $0.category.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    // MARK: - Actions

    private func refreshLogs() async {
        isLoading = true
        defer { isLoading = false }

        // Use the `log` command to fetch recent entries from the unified logging system.
        // This requires the app to have the proper entitlements to read its own logs.
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

        let newEntries = lines.compactMap { line -> LogEntry? in
            guard !line.isEmpty else { return nil }

            // Parse log line format: timestamp [category] level message
            let components = line.components(separatedBy: " ", maxSplits: 4)
            guard components.count >= 4 else { return nil }

            let timestamp = formatter.date(from: components[0]) ?? Date()

            // Extract category from bracket notation
            var category = "Unknown"
            if let catStart = components[1].range(of: "["),
               let catEnd = components[1].range(of: "]") {
                category = String(components[1][catStart.upperBound..<catEnd.lowerBound])
            }

            let level = components.count > 2 ? components[2] : "default"
            let message = components.dropFirst(3).joined(separator: " ")

            return LogEntry(
                timestamp: timestamp,
                category: category,
                level: level,
                message: message
            )
        }

        // Append new entries (avoid duplicates by checking timestamp)
        let existingTimestamps = Set(logEntries.map { $0.timestamp })
        let uniqueNew = newEntries.filter { !existingTimestamps.contains($0.timestamp) }

        logEntries.append(contentsOf: uniqueNew)

        // Keep only the last 1000 entries to prevent unbounded memory growth
        if logEntries.count > 1000 {
            logEntries = Array(logEntries.suffix(1000))
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "backupbot-diagnostics-\(ISO8601DateFormatter().string(from: Date())).log"
        panel.allowedContentTypes = [.init(filenameExtension: "log")!]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let content = filteredEntries.map { entry in
                let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
                return "[\(timestamp)] [\(entry.category)] \(entry.level): \(entry.message)"
            }.joined(separator: "\n")

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                Logger.ui.info("Exported \(self.filteredEntries.count) log entries to \(url.path)")
            } catch {
                Logger.ui.error("Failed to export logs: \(error.localizedDescription)")
            }
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

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: DiagnosticsView.LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timestamp
            Text(entry.timestamp, style: .time)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            // Category badge
            Text(entry.category)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(categoryColor.opacity(0.15))
                .foregroundStyle(categoryColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 80, alignment: .leading)

            // Level indicator
            Circle()
                .fill(levelColor)
                .frame(width: 6, height: 6)
                .help(entry.level)

            // Message
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    private var categoryColor: Color {
        switch entry.category {
        case "SyncEngine": .blue
        case "Chunker": .orange
        case "MTProto": .purple
        case "FileMonitor": .green
        case "UI": .cyan
        default: .gray
        }
    }

    private var levelColor: Color {
        switch entry.level.lowercased() {
        case "error": .red
        case "warning", "warn": .orange
        case "info": .blue
        case "debug": .gray
        default: .secondary
        }
    }
}
