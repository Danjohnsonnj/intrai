//
//  DiskFreezeLogger.swift
//  intrai
//

import Foundation

final class DiskFreezeLogger {
    nonisolated static let shared = DiskFreezeLogger()

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

    /// Writes a diagnostic entry to disk from any thread without going through
    /// `FreezeLogger` (which is `@MainActor`). Used by the GCD generation
    /// deadline so stall breadcrumbs survive even if MainActor is wedged.
    ///
    /// Always flushes synchronously so the entry is durable by the time this
    /// call returns — callers should assume MainActor may be permanently stuck
    /// and the user may force-quit within milliseconds.
    nonisolated func persistDirect(
        event: String,
        level: FreezeLogLevel = .info,
        sessionID: UUID?,
        generationStamp: UUID?,
        durationMs: Double?,
        metadata: [String: String]
    ) {
        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)
        let entry = FreezeLogEntry(
            id: UUID(),
            timestamp: Date(),
            event: event,
            level: level,
            sessionID: sessionID,
            generationStamp: generationStamp,
            durationMs: durationMs,
            scenePhase: "unknown",
            memoryWarningCount: 0,
            threadID: threadID,
            isMainThread: Thread.isMainThread,
            metadata: metadata
        )
        persist(entry)
        flush()
    }

    /// Scans all persisted disk entries for the most recent
    /// `force_recovery_unreachable_mainactor` marker. Used by ContentView at
    /// launch to surface the post-abort relaunch banner. Returns nil if no such
    /// entry exists (happy path).
    ///
    /// Reads are queue-synchronized so an in-progress persist cannot produce a
    /// partial line we fail to parse.
    nonisolated func latestAbortRecoveryEntry() -> FreezeLogEntry? {
        queue.sync {
            guard let diskEntries = try? loadDiskEntries() else { return nil }
            return diskEntries
                .filter { $0.event == "force_recovery_unreachable_mainactor" }
                .max(by: { $0.timestamp < $1.timestamp })
        }
    }

    /// Returns true if at least one persisted entry matches the given event
    /// name and (if provided) sessionID. Queue-synchronized so a concurrent
    /// persist cannot race the read. Intended for validation scaffolding that
    /// needs to assert the unified send watchdog armed/disarmed a specific
    /// send().
    nonisolated func hasPersistedEvent(_ event: String, sessionID: UUID? = nil) -> Bool {
        queue.sync {
            guard let diskEntries = try? loadDiskEntries() else { return false }
            return diskEntries.contains { entry in
                guard entry.event == event else { return false }
                if let sessionID { return entry.sessionID == sessionID }
                return true
            }
        }
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
            "transcript_pruned",
            "context_progress_evaluated",
            // Non-streaming generation lifecycle (0.2.105+)
            "generation_started",
            "generation_finished",
            "generation_cancelled",
            "generation_failed",
            "generation_timeout",
            "generation_stalled",
            "generation_deadline_fired",
            "generation_grace_expired",
            "force_recovered_from_stall",
            "force_recovery_skipped_stale",
            "force_recovery_unreachable_mainactor",
            "send_blocked_context_full",
            "context_trim_user_action",
            "context_start_new_chat_user_action",
            "heartbeat_scheduled",
            "heartbeat_ran",
            "save_assistant_message_end",
            "save_after_failure_failed",
            "autoname_started",
            "autoname_skipped",
            "autoname_scheduled",
            "autoname_cancelled",
            "autoname_cancelled_by_new_send",
            "autoname_deadline_fired",
            "autoname_result_dropped_after_deadline",
            "autoname_model_unavailable",
            "autoname_model_call_started",
            "autoname_model_call_finished",
            "autoname_model_call_failed",
            "autoname_finished",
            // Retry governance events
            "retry_cooldown_started",
            "retry_cooldown_ended",
            "retry_blocked_cooldown",
            "retry_blocked_circuit_open",
            "model_circuit_opened",
            "model_circuit_closed",
            // Phase 4 — bounded generation, proactive wedge detection,
            // post-abort banner.
            "generation_max_tokens",
            "generation_capped",
            "generation_exceeded_context_window",
            "generation_early_cancel_wedge_detected",
            "abort_recovery_banner_shown",
            "runtime_limits_loaded",
            "runtime_limits_load_failed",
            "runtime_limits_unavailable",
            // Phase 4 hotfix (0.2.111) — unified send watchdog that arms at
            // send_start and covers pre-flight.
            "send_watchdog_armed",
            "send_watchdog_disarmed",
            "preflight_hang_detected"
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