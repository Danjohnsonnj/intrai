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

/// Cross-thread bookkeeping for heartbeat scheduled/ran pairing. The GCD timer
/// hands out heartbeat IDs + sentAt timestamps; the MainActor hop reports when
/// (or whether) the matching ID arrives. Access is NSLock-protected so both
/// sides can mutate safely without a MainActor hop.
nonisolated private final class HeartbeatPairingState: @unchecked Sendable {
    struct ScheduleDecision {
        let shouldPersist: Bool
        let degraded: Bool
    }

    private let lock = NSLock()
    private var tickCounter: Int = 0
    private var pendingID: UUID? = nil
    private var pendingSentAt: Date? = nil
    private var degraded: Bool = false
    /// Timestamp of the first unacknowledged scheduled tick that caused the
    /// degraded flag to flip true. Used to compute MainActor wedge duration
    /// from a nonisolated caller (proactive wedge detection).
    private var degradedSince: Date? = nil

    /// Every 5th tick under healthy operation. On a wedge, the previous
    /// scheduled entry remains unpaired; after 2 s we escalate to every-tick
    /// persistence so the on-disk record clearly bounds the wedge duration.
    func registerTick(hbID: UUID, sentAt: Date) -> ScheduleDecision {
        lock.lock(); defer { lock.unlock() }
        tickCounter &+= 1

        if let pendingAt = pendingSentAt, sentAt.timeIntervalSince(pendingAt) > 2 {
            if !degraded {
                degraded = true
                // Start the wedge clock from the last tick we *would* have
                // acknowledged if MainActor had been responsive.
                degradedSince = pendingAt
            }
        }

        let shouldPersist = degraded || (tickCounter % 5 == 0)
        if shouldPersist {
            pendingID = hbID
            pendingSentAt = sentAt
        }
        return ScheduleDecision(shouldPersist: shouldPersist, degraded: degraded)
    }

    /// Returns true iff this ID matches the last persisted scheduled entry.
    /// Only in that case should the MainActor hop persist `heartbeat_ran` (to
    /// keep pair accounting intact).
    func acknowledgeRun(hbID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pendingID == hbID else { return false }
        pendingID = nil
        pendingSentAt = nil
        degraded = false
        degradedSince = nil
        return true
    }

    /// Milliseconds the MainActor has been unresponsive. Zero when healthy.
    /// Safe to call from any thread — lock-protected.
    var degradedDurationMs: Double {
        lock.lock(); defer { lock.unlock() }
        guard let since = degradedSince else { return 0 }
        return Date().timeIntervalSince(since) * 1000
    }
}

@MainActor
final class FreezeLogger {
    static let shared = FreezeLogger()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "intrai", category: "freeze-diagnostics")
    private let maxEntries = 1000
    private var entries: [FreezeLogEntry] = []
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastStallLogAt = Date.distantPast
    nonisolated private let pairingState = HeartbeatPairingState()

    /// Milliseconds of current unbroken MainActor wedge, or 0 if healthy.
    /// Nonisolated so the IntelligenceService proactive wedge detector can poll
    /// it from a GCD timer without a MainActor hop.
    nonisolated var degradedHeartbeatDurationMs: Double {
        pairingState.degradedDurationMs
    }

    /// Events for which the disk log is flushed synchronously after persist so
    /// they survive a force-quit that may follow within seconds.
    private static let criticalEvents: Set<String> = [
        "generation_timeout",
        "generation_stalled",
        "generation_failed",
        "generation_deadline_fired",
        "generation_grace_expired",
        "force_recovered_from_stall",
        "force_recovery_skipped_stale",
        "force_recovery_unreachable_mainactor",
        "send_blocked_context_full",
        "autoname_deadline_fired",
        "autoname_result_dropped_after_deadline",
        "autoname_cancelled_by_new_send",
        "main_thread_stall",
        // Phase 4 — early wedge detection, native context-window error,
        // post-abort banner. These need to survive force-quit that may
        // follow within seconds of the event being recorded.
        "generation_early_cancel_wedge_detected",
        "generation_exceeded_context_window",
        "abort_recovery_banner_shown",
        "generation_capped",
        // Phase 4 hotfix (0.2.111) — the watchdog now fires before
        // `generation_started` when pre-flight itself wedges.
        "preflight_hang_detected"
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
        let pairingState = self.pairingState

        timer.setEventHandler { [weak self] in
            let sentAt = Date()
            let hbID = UUID()
            let decision = pairingState.registerTick(hbID: hbID, sentAt: sentAt)

            // Heartbeat scheduled is persisted from the GCD thread so it survives
            // a MainActor wedge — unpaired entries on disk prove the wedge.
            if decision.shouldPersist {
                DiskFreezeLogger.shared.persistDirect(
                    event: "heartbeat_scheduled",
                    level: decision.degraded ? .warning : .info,
                    sessionID: nil,
                    generationStamp: nil,
                    durationMs: nil,
                    metadata: [
                        "heartbeatID": hbID.uuidString,
                        "sentAtEpochMs": String(Int(sentAt.timeIntervalSince1970 * 1000)),
                        "degraded": decision.degraded ? "true" : "false"
                    ]
                )
            }

            Task { @MainActor in
                guard let self else { return }

                let lag = Date().timeIntervalSince(sentAt)

                if pairingState.acknowledgeRun(hbID: hbID) {
                    DiskFreezeLogger.shared.persistDirect(
                        event: "heartbeat_ran",
                        level: .info,
                        sessionID: nil,
                        generationStamp: nil,
                        durationMs: lag * 1000,
                        metadata: [
                            "heartbeatID": hbID.uuidString
                        ]
                    )
                }

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
