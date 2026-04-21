//
//  FreezeLogger.swift
//  intrai
//

import Foundation
import OSLog
import Darwin

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class FreezeLogger {
    static let shared = FreezeLogger()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "intrai", category: "freeze-diagnostics")
    private let maxEntries = 1000
    private var entries: [FreezeLogEntry] = []
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastStallLogAt = Date.distantPast

    /// Events for which the disk log is flushed synchronously after persist so
    /// they survive a force-quit that may follow within seconds.
    private static let criticalEvents: Set<String> = [
        "mid_stream_stall_detected",
        "watchdog_timeout_fired",
        "generation_timeout",
        "generation_stalled",
        "inner_stream_error",
        "main_thread_stall",
        // Tick events are flushed immediately so per-poll elapsed times survive force-quit.
        // inner_stream_started flushed immediately so model-hang vs UI-lock is always on disk.
        "mid_stream_watchdog_tick",
        "inner_stream_started"
    ]

    private(set) var currentScenePhase = "unknown"
    private(set) var memoryWarningCount = 0

    var isEnabled: Bool {
#if DEBUG
        true
#else
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
#endif
    }

    private init() { }

    deinit {
        heartbeatTimer?.cancel()
    }

    func start() {
        guard isEnabled else { return }
        guard heartbeatTimer == nil else { return }

        log("diagnostics_started", metadata: [
            "maxEntries": String(maxEntries)
        ])

        startMainThreadHeartbeat()
    }

    func setScenePhase(_ phase: String) {
        guard isEnabled else { return }
        currentScenePhase = phase
        log("scene_phase_changed", metadata: ["scenePhase": phase])
    }

    func recordMemoryWarning() {
        guard isEnabled else { return }
        memoryWarningCount += 1
        log("memory_warning", level: .warning)
    }

    func log(
        _ event: String,
        level: FreezeLogLevel = .info,
        sessionID: UUID? = nil,
        generationStamp: UUID? = nil,
        durationMs: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        guard isEnabled else { return }

        let mergedMetadata = metadata.merging([
            "scenePhase": currentScenePhase
        ]) { _, newest in newest }

        let entry = FreezeLogEntry(
            id: UUID(),
            timestamp: Date(),
            event: event,
            level: level,
            sessionID: sessionID,
            generationStamp: generationStamp,
            durationMs: durationMs,
            scenePhase: currentScenePhase,
            memoryWarningCount: memoryWarningCount,
            threadID: currentThreadID(),
            isMainThread: Thread.isMainThread,
            metadata: mergedMetadata
        )

        append(entry)
        let isCritical = Self.criticalEvents.contains(entry.event)
        Task(priority: .utility) {
            DiskFreezeLogger.shared.persist(entry)
            // For critical events, flush immediately so the write survives a force-quit
            // that may follow within seconds of the stall/timeout being detected.
            if isCritical {
                DiskFreezeLogger.shared.flush()
            }
        }
        logger.log("[\(entry.level.rawValue)] \(entry.event, privacy: .public) sid=\(entry.sessionID?.uuidString ?? "-", privacy: .public) stamp=\(entry.generationStamp?.uuidString ?? "-", privacy: .public) durMs=\(entry.durationMs ?? -1, privacy: .public)")
    }

    func exportToTemporaryFile() async throws -> URL {
        guard isEnabled else {
            throw NSError(domain: "FreezeLogger", code: 1, userInfo: [NSLocalizedDescriptionKey: "Diagnostics are disabled for this build."])
        }

        let url = try DiskFreezeLogger.shared.exportMerged(with: entries, metadata: exportMetadata())

        log("diagnostics_exported", metadata: [
            "entries": String(entries.count),
            "fileName": url.lastPathComponent
        ])

        return url
    }

    func flushToDisk() {
        guard isEnabled else { return }
        Task(priority: .utility) {
            DiskFreezeLogger.shared.flush()
        }
    }

    private func append(_ entry: FreezeLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private func startMainThreadHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))

        timer.setEventHandler { [weak self] in
            let sentAt = Date()
            Task { @MainActor in
                guard let self else { return }

                let lag = Date().timeIntervalSince(sentAt)
                guard lag > 1.0 else { return }
                // 2-second cooldown: short enough to capture mid-stream stalls that
                // previously fell inside the 30-second blind window, long enough to
                // prevent duplicate log spam on back-to-back heartbeat ticks.
                guard Date().timeIntervalSince(self.lastStallLogAt) >= 2 else { return }

                self.lastStallLogAt = Date()
                self.log(
                    "main_thread_stall",
                    level: .warning,
                    durationMs: lag * 1000,
                    metadata: ["thresholdMs": "1000"]
                )
            }
        }

        timer.resume()
        heartbeatTimer = timer
    }

    private func currentThreadID() -> UInt64 {
        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)
        return threadID
    }

    private func exportMetadata() -> [String: String] {
        var metadata: [String: String] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildNumber": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "entryCount": String(entries.count),
            "scenePhase": currentScenePhase,
            "memoryWarningCount": String(memoryWarningCount)
        ]

#if canImport(UIKit)
        metadata["deviceModel"] = UIDevice.current.model
#endif

        return metadata
    }
}
