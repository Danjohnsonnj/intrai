//
//  DiskFreezeLogger.swift
//  intrai
//

import Foundation

final class DiskFreezeLogger {
    static let shared = DiskFreezeLogger()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.johnsonation.intrai.disk-freeze-logger", qos: .utility)
    private let logFilePrefix = "freeze-breadcrumb"
    private let exportFilePrefix = "intrai-freeze-diagnostics"
    private let maxLogFileCount = 5
    private let maxLogFileSizeBytes = 2 * 1024 * 1024
    private let maxExportFileCount = 10
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let iso8601Formatter = ISO8601DateFormatter()

    private init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func persist(_ entry: FreezeLogEntry) {
        guard shouldPersist(entry.event) else { return }

        queue.async {
            do {
                try self.ensureDirectoriesExist()
                try self.rotateLogsIfNeeded()

                let persistentEntry: [String: Any] = [
                    "id": entry.id.uuidString,
                    "timestamp": DiskFreezeLogger.iso8601Formatter.string(from: entry.timestamp),
                    "event": entry.event,
                    "level": entry.level.rawValue,
                    "sessionID": entry.sessionID?.uuidString as Any,
                    "generationStamp": entry.generationStamp?.uuidString as Any,
                    "durationMs": entry.durationMs as Any,
                    "scenePhase": entry.scenePhase,
                    "memoryWarningCount": entry.memoryWarningCount,
                    "threadID": entry.threadID,
                    "isMainThread": entry.isMainThread,
                    "metadata": entry.metadata
                ]
                let data = try JSONSerialization.data(withJSONObject: persistentEntry, options: [])
                let line = data + Data([0x0A])
                let url = self.activeLogURL()

                if !self.fileManager.fileExists(atPath: url.path) {
                    self.fileManager.createFile(atPath: url.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                // Disk breadcrumbs are best-effort only; failures must not affect app behavior.
            }
        }
    }

    func flush() {
        queue.sync { }
    }

    func exportMerged(with memoryEntries: [FreezeLogEntry], metadata: [String: String]) throws -> URL {
        try queue.sync {
            try ensureDirectoriesExist()

            let diskEntries = try loadDiskEntries()
            var mergedByID: [UUID: FreezeLogEntry] = [:]

            for entry in diskEntries {
                mergedByID[entry.id] = entry
            }

            for entry in memoryEntries {
                mergedByID[entry.id] = entry
            }

            let mergedEntries = mergedByID.values.sorted { $0.timestamp < $1.timestamp }
            let export = PersistentFreezeLogExport(
                metadata: mergedMetadata(base: metadata, entryCount: mergedEntries.count),
                entries: mergedEntries.map { entry in
                    PersistentFreezeLogEntry(
                        id: entry.id,
                        timestamp: entry.timestamp,
                        event: entry.event,
                        level: entry.level.rawValue,
                        sessionID: entry.sessionID,
                        generationStamp: entry.generationStamp,
                        durationMs: entry.durationMs,
                        scenePhase: entry.scenePhase,
                        memoryWarningCount: entry.memoryWarningCount,
                        threadID: entry.threadID,
                        isMainThread: entry.isMainThread,
                        metadata: entry.metadata
                    )
                }
            )

            let prettyEncoder = JSONEncoder()
            prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            prettyEncoder.dateEncodingStrategy = .iso8601

            let data = try prettyEncoder.encode(export)
            let exportsDirectory = try exportsDirectoryURL()
            let fileName = "\(exportFilePrefix)-\(Int(Date().timeIntervalSince1970)).json"
            let url = exportsDirectory.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)

            try cleanupOldExports(in: exportsDirectory)

            return url
        }
    }

    private func shouldPersist(_ event: String) -> Bool {
        let persistedEvents: Set<String> = [
            "diagnostics_started",
            "scene_phase_changed",
            "memory_warning",
            "main_thread_stall",
            "send_start",
            "send_rejected_empty_prompt",
            "save_user_message_end",
            "save_user_message_failed",
            "transcript_build_start",
            "transcript_build_end",
            "context_progress_evaluated",
            "stream_initialized",
            "startup_watchdog_armed",
            "startup_watchdog_checked",
            "mid_stream_watchdog_spawned",
            "mid_stream_watchdog_armed",
            "mid_stream_watchdog_tick",
            "first_fragment_received",
            "fragment_sample",
            "mid_stream_stall_detected",
            "stream_completed",
            "save_assistant_message_end",
            "generation_timeout",
            "generation_stalled",
            "generation_cancelled",
            "generation_failed",
            "save_after_failure_failed",
            "watchdog_timeout_fired",
            "autoname_started",
            "autoname_skipped",
            "autoname_model_unavailable",
            "autoname_model_call_started",
            "autoname_model_call_detached_started",
            "autoname_model_call_finished",
            "autoname_model_call_failed",
            "autoname_finished",
            // Phase 1: Retry governance events
            "retry_cooldown_started",
            "retry_cooldown_ended",
            "retry_blocked_cooldown",
            "retry_blocked_circuit_open",
            "model_circuit_opened",
            "model_circuit_closed"
        ]
        return persistedEvents.contains(event)
    }

    private func mergedMetadata(base: [String: String], entryCount: Int) -> [String: String] {
        base.merging([
            "entryCount": String(entryCount),
            "persistedLogsIncluded": "true"
        ]) { _, newValue in newValue }
    }

    private func loadDiskEntries() throws -> [FreezeLogEntry] {
        let directory = try logsDirectoryURL()
        let files = try logFileURLs(in: directory)
        var entries: [FreezeLogEntry] = []

        for fileURL in files {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            for line in contents.split(separator: "\n") {
                guard !line.isEmpty else { continue }
                guard let data = line.data(using: .utf8) else { continue }
                guard let entry = try? decoder.decode(PersistentFreezeLogEntry.self, from: data) else { continue }
                entries.append(
                    FreezeLogEntry(
                        id: entry.id,
                        timestamp: entry.timestamp,
                        event: entry.event,
                        level: FreezeLogLevel(rawValue: entry.level) ?? .info,
                        sessionID: entry.sessionID,
                        generationStamp: entry.generationStamp,
                        durationMs: entry.durationMs,
                        scenePhase: entry.scenePhase,
                        memoryWarningCount: entry.memoryWarningCount,
                        threadID: entry.threadID,
                        isMainThread: entry.isMainThread,
                        metadata: entry.metadata
                    )
                )
            }
        }

        return entries
    }

    private func rotateLogsIfNeeded() throws {
        let activeURL = activeLogURL()
        guard fileManager.fileExists(atPath: activeURL.path) else { return }

        let attributes = try fileManager.attributesOfItem(atPath: activeURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize >= maxLogFileSizeBytes else { return }

        let directory = try logsDirectoryURL()
        let files = try logFileURLs(in: directory)
        let archiveFiles = files.filter { $0.lastPathComponent != activeURL.lastPathComponent }

        if archiveFiles.count >= (maxLogFileCount - 1), let oldest = archiveFiles.first {
            try? fileManager.removeItem(at: oldest)
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let archivedURL = directory.appendingPathComponent("\(logFilePrefix)-\(timestamp).jsonl")
        try fileManager.moveItem(at: activeURL, to: archivedURL)
    }

    private func logFileURLs(in directory: URL) throws -> [URL] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { $0.lastPathComponent.hasPrefix(logFilePrefix) && $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }
    }

    private func cleanupOldExports(in directory: URL) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let exportFiles = urls
            .filter { $0.lastPathComponent.hasPrefix(exportFilePrefix) && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }

        guard exportFiles.count > maxExportFileCount else { return }
        for url in exportFiles.prefix(exportFiles.count - maxExportFileCount) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func ensureDirectoriesExist() throws {
        _ = try logsDirectoryURL()
        _ = try exportsDirectoryURL()
    }

    private func baseDirectoryURL() throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("FreezeDiagnostics", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func logsDirectoryURL() throws -> URL {
        let directory = try baseDirectoryURL().appendingPathComponent("Logs", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func exportsDirectoryURL() throws -> URL {
        let directory = try baseDirectoryURL().appendingPathComponent("Exports", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func activeLogURL() -> URL {
        let directory = try? logsDirectoryURL()
        return (directory ?? fileManager.temporaryDirectory).appendingPathComponent("\(logFilePrefix)-active.jsonl")
    }
}