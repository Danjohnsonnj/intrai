//
//  IntelligenceService.swift
//  intrai
//

import Foundation
import Combine
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

enum IntelligenceError: LocalizedError {
    case emptyPrompt
    case unavailableModel(String)
    case generationCancelled
    case generationTimeout
    case generationStalled
    case circuitOpen

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "The prompt is empty."
        case let .unavailableModel(reason):
            return reason
        case .generationCancelled:
            return "Generation cancelled."
        case .generationTimeout:
            return "Response timed out. Tap retry to try again."
        case .generationStalled:
            return "Response stalled. Tap retry to try again."
        case .circuitOpen:
            return "Model is unavailable. Please restart the app to try again."
        }
    }
}

protocol ChatResponding {
    func streamResponse(systemPromptSnapshot: String, transcript: String) -> AsyncThrowingStream<String, Error>
}

struct LocalFirstChatResponder: ChatResponding {
    // Uses session.streamResponse(to:) for true token-by-token streaming.
    // Each element yielded is a cumulative snapshot of the response so far (not a delta).
    // The startup watchdog in IntelligenceService is the primary safety net for hangs.
    func streamResponse(systemPromptSnapshot: String, transcript: String) -> AsyncThrowingStream<String, Error> {
#if canImport(FoundationModels)
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let innerTask = Task.detached(priority: .userInitiated) {
                do {
                    let model = SystemLanguageModel.default
                    switch model.availability {
                    case .unavailable(let reason):
                        continuation.finish(throwing: IntelligenceError.unavailableModel("Apple Intelligence unavailable: \(reason)."))
                        return
                    case .available: break
                    }

                    let session = LanguageModelSession(instructions: systemPromptSnapshot)
                    let responseStream = session.streamResponse(to: transcript)
                    for try await snapshot in responseStream {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                innerTask.cancel()
            }
        }
#else
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: IntelligenceError.unavailableModel("FoundationModels is unavailable in this build target."))
        }
#endif
    }
}

/// Thread-safe context shared between the generation task and the mid-stream stall watchdog.
/// The watchdog reads fragment timestamps and cancels the task without ever hopping to MainActor,
/// so a FoundationModels hang that holds the actor cannot prevent auto-recovery.
private final class WatchdogContext: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _lastFragmentAt: Date?
    nonisolated(unsafe) private var _isActive = true
    nonisolated(unsafe) private var _isStalled = false

    nonisolated func recordFragment() {
        lock.lock(); defer { lock.unlock() }
        _lastFragmentAt = Date()
    }

    nonisolated func deactivate() {
        lock.lock(); defer { lock.unlock() }
        _isActive = false
    }

    nonisolated func markStalled() {
        lock.lock(); defer { lock.unlock() }
        _isStalled = true
        _isActive = false
    }

    nonisolated var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isActive
    }

    nonisolated var isStalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isStalled
    }

    /// Returns elapsed ms since last fragment, or nil if no fragment has arrived yet.
    nonisolated func elapsedMsSinceLastFragment() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let t = _lastFragmentAt else { return nil }
        return Date().timeIntervalSince(t) * 1000
    }
}

@MainActor
final class IntelligenceService: ObservableObject {
    @Published private(set) var generatingSessionIDs: Set<UUID> = []
    @Published private(set) var errorsBySessionID: [UUID: String] = [:]
    @Published private(set) var contextProgressBySessionID: [UUID: Double] = [:]

    private var lastFailedPromptBySessionID: [UUID: String] = [:]
    private var activeTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var pendingCancellationSessionIDs: Set<UUID> = []
    private var generationStampsBySessionID: [UUID: UUID] = [:]
    // PHASE 3: Stamps for which the 15-second watchdog fired before the first fragment arrived.
    // Used in the catch block to surface a timeout error instead of a generic cancel message.
    private var timedOutStamps: Set<UUID> = []
    // PHASE 3: Stamps for which at least one fragment has been received.
    // The watchdog checks this to avoid timing out a generation that is already streaming.
    private var firstFragmentReceivedStamps: Set<UUID> = []
    private var midStreamStalledStamps: Set<UUID> = []
    private var midStreamWatchdogArmedStamps: Set<UUID> = []
    private var sendStartedAtByStamp: [UUID: Date] = [:]
    private var fragmentCountByStamp: [UUID: Int] = [:]
    private var lastFragmentTimestampByStamp: [UUID: Date] = [:]
    private var midStreamWatchdogTickCountByStamp: [UUID: Int] = [:]
    // Actual adaptive watchdog duration used for each stamp — logged at check time.
    private var watchdogSecondsByStamp: [UUID: Double] = [:]

    // PHASE 1: Retry governance — timeout streak, cooldown, and circuit breaker.
    // streak=1 → 5s floor + up-to-60s availability poll
    // streak=2 → 10s floor + up-to-60s availability poll
    // streak≥3 → circuit open (blocks retries for the app lifetime)
    private var timeoutStreakBySessionID: [UUID: Int] = [:]
    private var cooldownUntilBySessionID: [UUID: Date] = [:]
    private var circuitOpenedAt: Date? = nil
    @Published private(set) var retryBlockedBySessionID: [UUID: String] = [:]

    private let responder: ChatResponding
#if canImport(FoundationModels)
    // Holds one prewarmed LanguageModelSession per ChatSession.id.
    // Populated by prewarm(for:); consumed once then cleared by send().
    // Each session is used for exactly one streamResponse call so its internal
    // transcript never accumulates state from multiple turns.
    private var prewarmSessionCache: [UUID: (systemPrompt: String, session: LanguageModelSession)] = [:]
#endif

    init(responder: ChatResponding) {
        self.responder = responder
    }

    init() {
        self.responder = LocalFirstChatResponder()
    }

    func isGenerating(for session: ChatSession) -> Bool {
        generatingSessionIDs.contains(session.id)
    }

    func errorMessage(for session: ChatSession) -> String? {
        errorsBySessionID[session.id]
    }

    func contextProgress(for session: ChatSession) -> Double {
        contextProgressBySessionID[session.id] ?? 0
    }

    /// Returns a human-readable reason the Retry button should be suppressed,
    /// or nil if retry is currently available.
    func retryBlockedReason(for session: ChatSession) -> String? {
        retryBlockedBySessionID[session.id]
    }

    /// Evaluates the current transcript and updates the per-session context
    /// progress ratio. Safe to call at any time on the main actor.
    func evaluateContextProgress(for session: ChatSession) {
        let systemPromptBudget = AIContextBuilder.estimatedTokens(forTranscript: session.systemPromptSnapshot)
        let transcript = AIContextBuilder.transcript(for: session, systemPromptBudget: systemPromptBudget)
        contextProgressBySessionID[session.id] = AIContextBuilder.contextFillRatio(forTranscript: transcript)
    }

    func send(_ rawPrompt: String, in session: ChatSession, modelContext: ModelContext) async {
        // Yield to other pending tasks on the cooperative executor before starting heavy work.
        // Does not flush the run loop or guarantee UI frame rendering.
        await Task.yield()

        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = session.id

        guard !prompt.isEmpty else {
            errorsBySessionID[sessionID] = IntelligenceError.emptyPrompt.localizedDescription
            FreezeLogger.shared.log("send_rejected_empty_prompt", level: .warning, sessionID: sessionID)
            return
        }

        cancelActiveGenerationIfAny(in: session)
        pendingCancellationSessionIDs.remove(sessionID)

        generatingSessionIDs.insert(sessionID)
        errorsBySessionID[sessionID] = nil
        // Clear any stale cooldown message — a fresh send supersedes previous retry governance.
        retryBlockedBySessionID.removeValue(forKey: sessionID)

        let stamp = UUID()
        generationStampsBySessionID[sessionID] = stamp
        sendStartedAtByStamp[stamp] = Date()
        fragmentCountByStamp[stamp] = 0

        FreezeLogger.shared.log(
            "send_start",
            sessionID: sessionID,
            generationStamp: stamp,
            metadata: [
                "existingMessages": String(session.messages.count)
            ]
        )

        let userMessage = ChatMessage(text: prompt, role: .user)
        session.messages.append(userMessage)

        let saveUserStartedAt = Date()
        do {
            try modelContext.save()
            FreezeLogger.shared.log(
                "save_user_message_end",
                sessionID: sessionID,
                generationStamp: stamp,
                durationMs: Date().timeIntervalSince(saveUserStartedAt) * 1000
            )
        } catch {
            errorsBySessionID[sessionID] = "Failed to save chat state: \(error.localizedDescription)"
            generatingSessionIDs.remove(sessionID)
            generationStampsBySessionID.removeValue(forKey: sessionID)
            sendStartedAtByStamp.removeValue(forKey: stamp)
            fragmentCountByStamp.removeValue(forKey: stamp)
            FreezeLogger.shared.log(
                "save_user_message_failed",
                level: .error,
                sessionID: sessionID,
                generationStamp: stamp,
                durationMs: Date().timeIntervalSince(saveUserStartedAt) * 1000,
                metadata: ["error": String(describing: type(of: error))]
            )
            return
        }

        let transcriptStartedAt = Date()
        FreezeLogger.shared.log("transcript_build_start", sessionID: sessionID, generationStamp: stamp)
        let systemPromptBudget = AIContextBuilder.estimatedTokens(forTranscript: session.systemPromptSnapshot)
        let transcript = AIContextBuilder.transcript(for: session, systemPromptBudget: systemPromptBudget)
        FreezeLogger.shared.log(
            "transcript_build_end",
            sessionID: sessionID,
            generationStamp: stamp,
            durationMs: Date().timeIntervalSince(transcriptStartedAt) * 1000,
            metadata: [
                "chars": String(transcript.utf16.count),
                "messages": String(session.messages.count)
            ]
        )

        let contextEvalStartedAt = Date()
        contextProgressBySessionID[session.id] = AIContextBuilder.contextFillRatio(forTranscript: transcript)
        FreezeLogger.shared.log(
            "context_progress_evaluated",
            sessionID: sessionID,
            generationStamp: stamp,
            durationMs: Date().timeIntervalSince(contextEvalStartedAt) * 1000,
            metadata: [
                "fillRatio": String(format: "%.4f", contextProgress(for: session))
            ]
        )

        let systemPromptSnapshot = session.systemPromptSnapshot
#if canImport(FoundationModels)
        // Pop any prewarmed session for this conversation (use-once: each session is
        // consumed by exactly one streamResponse call to avoid transcript accumulation).
        let cachedLMSession: LanguageModelSession?
        if let cached = prewarmSessionCache[sessionID],
           cached.systemPrompt == systemPromptSnapshot {
            cachedLMSession = cached.session
        } else {
            cachedLMSession = nil
        }
        prewarmSessionCache.removeValue(forKey: sessionID)
        let stream: AsyncThrowingStream<String, Error> = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let innerTask = Task.detached(priority: .userInitiated) {
                do {
                    let model = SystemLanguageModel.default
                    switch model.availability {
                    case .unavailable(let reason):
                        continuation.finish(throwing: IntelligenceError.unavailableModel("Apple Intelligence unavailable: \(reason)."))
                        return
                    case .available: break
                    }
                    let lmSession = cachedLMSession ?? LanguageModelSession(instructions: systemPromptSnapshot)
                    let responseStream = lmSession.streamResponse(to: transcript)
                    // Fire-and-forget hop: FreezeLogger is @MainActor; inner task is detached.
                    Task { @MainActor in
                        FreezeLogger.shared.log("inner_stream_started", sessionID: sessionID, generationStamp: stamp)
                    }
                    for try await snapshot in responseStream {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        continuation.yield(snapshot.content)
                    }
                    Task { @MainActor in
                        FreezeLogger.shared.log("inner_stream_finished", sessionID: sessionID, generationStamp: stamp)
                    }
                    continuation.finish()
                } catch {
                    Task { @MainActor in
                        FreezeLogger.shared.log(
                            "inner_stream_error",
                            level: .error,
                            sessionID: sessionID,
                            generationStamp: stamp,
                            metadata: ["errorType": String(describing: type(of: error))]
                        )
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                innerTask.cancel()
            }
        }
#else
        let stream = responder.streamResponse(
            systemPromptSnapshot: systemPromptSnapshot,
            transcript: transcript
        )
#endif
        FreezeLogger.shared.log("stream_initialized", sessionID: sessionID, generationStamp: stamp)

        // WatchdogContext is created per-generation and shared with the mid-stream watchdog
        // closure. It provides thread-safe fragment timestamps so the watchdog never needs to
        // hop to MainActor — critical when FoundationModels holds the actor during a hang.
        let watchdogContext = WatchdogContext()
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            var assistantMessage: ChatMessage?

            defer {
                // Signal the watchdog to stop — prevents spurious stall detection after
                // the generation ends normally or via external cancel.
                watchdogContext.deactivate()
                // Only clean up shared state if we are still the active generation.
                // A newer send() may have already overwritten these entries.
                if self.generationStampsBySessionID[sessionID] == stamp {
                    self.generatingSessionIDs.remove(sessionID)
                    self.activeTasksBySessionID[sessionID] = nil
                    self.generationStampsBySessionID.removeValue(forKey: sessionID)
                }
                self.pendingCancellationSessionIDs.remove(sessionID)
                self.firstFragmentReceivedStamps.remove(stamp)
                self.midStreamStalledStamps.remove(stamp)
                self.midStreamWatchdogArmedStamps.remove(stamp)
                self.sendStartedAtByStamp.removeValue(forKey: stamp)
                self.fragmentCountByStamp.removeValue(forKey: stamp)
                self.lastFragmentTimestampByStamp.removeValue(forKey: stamp)
                self.midStreamWatchdogTickCountByStamp.removeValue(forKey: stamp)
                self.watchdogSecondsByStamp.removeValue(forKey: stamp)
            }

            do {
                // Throttle SwiftUI text writes to at most one per 250ms.
                // Every iteration still updates lastFragmentTimestampByStamp so the
                // mid-stream stall watchdog retains full timing accuracy.
                // latestFragment always holds the most recent snapshot so the post-loop
                // final commit guarantees the complete text is always persisted.
                var lastUIUpdateAt: Date = .distantPast
                var latestFragment: String = ""
                var uiUpdateCount = 0

                for try await fragment in stream {
                    // Sleep 1ms per iteration to genuinely release the main actor.
                    // Task.yield() re-enqueues at the same .userInitiated priority and
                    // Apple's docs explicitly state it is not starvation-safe at high
                    // priority. A 1ms timer suspension lets the CFRunLoop, SwiftUI
                    // render pass, and lower-priority watchdog tasks run between fragments.
                    try await Task.sleep(for: .milliseconds(1))

                    if self.firstFragmentReceivedStamps.insert(stamp).inserted {
                        let firstTokenLatencyMs = self.sendStartedAtByStamp[stamp].map {
                            Date().timeIntervalSince($0) * 1000
                        }
                        FreezeLogger.shared.log(
                            "first_fragment_received",
                            sessionID: sessionID,
                            generationStamp: stamp,
                            durationMs: firstTokenLatencyMs
                        )
                        if let ms = firstTokenLatencyMs {
                            self.recordFirstTokenLatency(ms)
                        }
                    }

                    let updatedFragmentCount = (self.fragmentCountByStamp[stamp] ?? 0) + 1
                    self.fragmentCountByStamp[stamp] = updatedFragmentCount
                    self.lastFragmentTimestampByStamp[stamp] = Date()
                    watchdogContext.recordFragment()  // thread-safe mirror for off-MainActor watchdog
                    if updatedFragmentCount.isMultiple(of: 20) {
                        FreezeLogger.shared.log(
                            "fragment_sample",
                            sessionID: sessionID,
                            generationStamp: stamp,
                            metadata: ["count": String(updatedFragmentCount)]
                        )
                    }

                    if self.pendingCancellationSessionIDs.contains(sessionID) {
                        throw CancellationError()
                    }

                    try Task.checkCancellation()

                    if assistantMessage == nil,
                       self.isDisplayableFragment(fragment) {
                        let message = ChatMessage(text: "", role: .assistant)
                        session.messages.append(message)
                        assistantMessage = message
                    }

                    // Fragments are cumulative snapshots — replace, never append.
                    // Throttled to 250ms to prevent O(n²) SwiftUI text layout pressure
                    // on the main thread; the final commit below guarantees complete text.
                    latestFragment = fragment
                    let now = Date()
                    if now.timeIntervalSince(lastUIUpdateAt) >= 0.25 {
                        assistantMessage?.text = fragment
                        lastUIUpdateAt = now
                        uiUpdateCount += 1
                    }
                }

                // Commit the final complete snapshot regardless of where the throttle
                // gate last opened — ensures display and persistence always match.
                if let msg = assistantMessage, !latestFragment.isEmpty {
                    msg.text = latestFragment
                }

                if self.pendingCancellationSessionIDs.contains(sessionID) || Task.isCancelled {
                    throw CancellationError()
                }

                if assistantMessage == nil {
                    let message = ChatMessage(text: "(No response generated.)", role: .assistant)
                    session.messages.append(message)
                    assistantMessage = message
                } else if assistantMessage?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    assistantMessage?.text = "(No response generated.)"
                }

                FreezeLogger.shared.log(
                    "stream_completed",
                    sessionID: sessionID,
                    generationStamp: stamp,
                    durationMs: self.sendStartedAtByStamp[stamp].map { Date().timeIntervalSince($0) * 1000 },
                    metadata: [
                        "fragments": String(self.fragmentCountByStamp[stamp] ?? 0),
                        "uiUpdates": String(uiUpdateCount)
                    ]
                )

                let saveAssistantStartedAt = Date()
                try modelContext.save()
                FreezeLogger.shared.log(
                    "save_assistant_message_end",
                    sessionID: sessionID,
                    generationStamp: stamp,
                    durationMs: Date().timeIntervalSince(saveAssistantStartedAt) * 1000
                )
                self.lastFailedPromptBySessionID[sessionID] = nil
                // Successful generation resets the timeout streak and any pending cooldown for
                // this session so that a subsequent retry() is not silently blocked by a stale
                // cooldown deadline that predates the successful response.
                self.timeoutStreakBySessionID.removeValue(forKey: sessionID)
                self.cooldownUntilBySessionID.removeValue(forKey: sessionID)
                await self.autoNameIfNeeded(session: session, firstUserText: prompt, modelContext: modelContext)
            } catch is CancellationError {
                if let assistantMessage {
                    session.messages.removeAll { $0.id == assistantMessage.id }
                }
                // PHASE 3: Distinguish watchdog timeout from user-initiated cancel.
                if self.timedOutStamps.remove(stamp) != nil {
                    self.errorsBySessionID[sessionID] = IntelligenceError.generationTimeout.localizedDescription
                    FreezeLogger.shared.log(
                        "generation_timeout",
                        level: .warning,
                        sessionID: sessionID,
                        generationStamp: stamp
                    )
                    self.applyTimeoutGovernance(sessionID: sessionID, stamp: stamp)
                } else if watchdogContext.isStalled {
                    self.errorsBySessionID[sessionID] = IntelligenceError.generationStalled.localizedDescription
                    FreezeLogger.shared.log(
                        "generation_stalled",
                        level: .warning,
                        sessionID: sessionID,
                        generationStamp: stamp,
                        metadata: ["fragments": String(self.fragmentCountByStamp[stamp] ?? 0)]
                    )
                } else {
                    self.errorsBySessionID[sessionID] = IntelligenceError.generationCancelled.localizedDescription
                    FreezeLogger.shared.log(
                        "generation_cancelled",
                        level: .warning,
                        sessionID: sessionID,
                        generationStamp: stamp
                    )
                }
                self.lastFailedPromptBySessionID[sessionID] = prompt
                try? modelContext.save()
            } catch {
                if let assistantMessage {
                    session.messages.removeAll { $0.id == assistantMessage.id }
                }
                self.errorsBySessionID[sessionID] = self.friendlyErrorText(from: error)
                self.lastFailedPromptBySessionID[sessionID] = prompt
                // Responder-level hard timeout surfaces here as IntelligenceError.generationTimeout.
                if let ie = error as? IntelligenceError, case .generationTimeout = ie {
                    FreezeLogger.shared.log(
                        "generation_timeout",
                        level: .warning,
                        sessionID: sessionID,
                        generationStamp: stamp
                    )
                    self.applyTimeoutGovernance(sessionID: sessionID, stamp: stamp)
                } else {
                    FreezeLogger.shared.log(
                        "generation_failed",
                        level: .error,
                        sessionID: sessionID,
                        generationStamp: stamp,
                        metadata: ["error": String(describing: type(of: error))]
                    )
                }

                do {
                    try modelContext.save()
                } catch {
                    self.errorsBySessionID[sessionID] = "Failed to save chat state: \(error.localizedDescription)"
                    FreezeLogger.shared.log(
                        "save_after_failure_failed",
                        level: .error,
                        sessionID: sessionID,
                        generationStamp: stamp,
                        metadata: ["error": String(describing: type(of: error))]
                    )
                }
            } // end catch error
        }

        // PHASE 4: Startup watchdog — detached timer so sleep is independent of main-actor scheduling.
        // After the sleep, checks and cancellation happen on MainActor to safely touch service state.
        let watchdogSeconds = adaptiveStartupWatchdogSeconds()
        watchdogSecondsByStamp[stamp] = watchdogSeconds
        FreezeLogger.shared.log("startup_watchdog_armed", sessionID: sessionID, generationStamp: stamp)
        Task.detached { [weak self] in
            do {
                try await Task.sleep(for: .seconds(watchdogSeconds))
            } catch {
                return
            }

            guard let self else { return }
            await self.handleStartupWatchdogCheck(sessionID: sessionID, stamp: stamp)
        }

        // PHASE 4: Mid-stream watchdog — operates entirely off-MainActor via WatchdogContext.
        // A FoundationModels hang that holds the MainActor executor cannot prevent cancellation:
        // WatchdogContext reads use NSLock (no actor hop required), and task.cancel() is safe
        // to call from any concurrency domain.
        // Worst-case detection: 7s stall threshold + 3s poll = 10s max.
        FreezeLogger.shared.log("mid_stream_watchdog_spawned", sessionID: sessionID, generationStamp: stamp)
        Task.detached { [task] in
            var tickCount = 0
            var hasArmed = false
            while true {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }

                guard watchdogContext.isActive else { return }
                tickCount += 1
                let currentTick = tickCount

                if currentTick.isMultiple(of: 3) {
                    let elapsedStr = watchdogContext.elapsedMsSinceLastFragment().map { String(Int($0)) } ?? "none"
                    Task { @MainActor in
                        FreezeLogger.shared.log(
                            "mid_stream_watchdog_tick",
                            sessionID: sessionID,
                            generationStamp: stamp,
                            metadata: ["tick": String(currentTick), "elapsedMsSinceFragment": elapsedStr]
                        )
                    }
                }

                guard let elapsed = watchdogContext.elapsedMsSinceLastFragment() else { continue }

                if !hasArmed {
                    hasArmed = true
                    Task { @MainActor in
                        FreezeLogger.shared.log("mid_stream_watchdog_armed", sessionID: sessionID, generationStamp: stamp)
                    }
                }

                guard elapsed >= 7_000 else { continue }

                // Stall confirmed — cancel immediately without any MainActor hop, then log best-effort.
                watchdogContext.markStalled()
                task.cancel()
                let capturedElapsed = elapsed
                Task { @MainActor in
                    FreezeLogger.shared.log(
                        "mid_stream_stall_detected",
                        level: .warning,
                        sessionID: sessionID,
                        generationStamp: stamp,
                        durationMs: capturedElapsed,
                        metadata: ["tick": String(currentTick)]
                    )
                }
                return
            }
        }

        activeTasksBySessionID[sessionID] = task
        if pendingCancellationSessionIDs.remove(sessionID) != nil {
            task.cancel()
        }
    }

    func retry(in session: ChatSession, modelContext: ModelContext) async {
        let sessionID = session.id
        guard let prompt = lastFailedPromptBySessionID[sessionID] else { return }

        // Circuit breaker: model has timed out too many times this launch — block retries.
        if circuitOpenedAt != nil {
            FreezeLogger.shared.log("retry_blocked_circuit_open", level: .warning, sessionID: sessionID)
            return
        }

        // Cooldown: enforce a backoff delay between consecutive timeout retries.
        if let cooldownUntil = cooldownUntilBySessionID[sessionID], Date() < cooldownUntil {
            let remaining = Int(cooldownUntil.timeIntervalSinceNow.rounded(.up))
            FreezeLogger.shared.log(
                "retry_blocked_cooldown",
                level: .warning,
                sessionID: sessionID,
                metadata: ["remainingSeconds": String(remaining)]
            )
            return
        }

        await send(prompt, in: session, modelContext: modelContext)
    }

    func cancelGeneration(in session: ChatSession) {
        pendingCancellationSessionIDs.insert(session.id)

        if let task = activeTasksBySessionID[session.id] {
            task.cancel()
            return
        }

        if generatingSessionIDs.contains(session.id) {
            pendingCancellationSessionIDs.insert(session.id)
        }
    }

    private func cancelActiveGenerationIfAny(in session: ChatSession) {
        activeTasksBySessionID[session.id]?.cancel()
    }

    private func handleStartupWatchdogCheck(sessionID: UUID, stamp: UUID) {
        guard generationStampsBySessionID[sessionID] == stamp else { return }

        let actualDurationMs = watchdogSecondsByStamp[stamp].map { $0 * 1000 }
        let firstFragmentSeen = firstFragmentReceivedStamps.contains(stamp)
        FreezeLogger.shared.log(
            "startup_watchdog_checked",
            sessionID: sessionID,
            generationStamp: stamp,
            durationMs: actualDurationMs,
            metadata: ["firstFragmentSeen": firstFragmentSeen ? "true" : "false"]
        )

        guard !firstFragmentSeen else { return }
        timedOutStamps.insert(stamp)
        FreezeLogger.shared.log(
            "watchdog_timeout_fired",
            level: .warning,
            sessionID: sessionID,
            generationStamp: stamp,
            durationMs: actualDurationMs
        )
        activeTasksBySessionID[sessionID]?.cancel()
    }

    private func handleMidStreamWatchdogPoll(sessionID: UUID, stamp: UUID) -> Bool {
        guard generationStampsBySessionID[sessionID] == stamp else { return false }

        let updatedTickCount = (midStreamWatchdogTickCountByStamp[stamp] ?? 0) + 1
        midStreamWatchdogTickCountByStamp[stamp] = updatedTickCount
        if updatedTickCount.isMultiple(of: 3) {
            let tickElapsedMs = lastFragmentTimestampByStamp[stamp].map { Date().timeIntervalSince($0) * 1000 }
            var tickMeta: [String: String] = ["tick": String(updatedTickCount)]
            if let ms = tickElapsedMs { tickMeta["elapsedMsSinceFragment"] = String(Int(ms)) }
            FreezeLogger.shared.log(
                "mid_stream_watchdog_tick",
                sessionID: sessionID,
                generationStamp: stamp,
                metadata: tickMeta
            )
        }

        guard firstFragmentReceivedStamps.contains(stamp) else { return true }

        if midStreamWatchdogArmedStamps.insert(stamp).inserted {
            FreezeLogger.shared.log(
                "mid_stream_watchdog_armed",
                sessionID: sessionID,
                generationStamp: stamp
            )
        }

        guard let lastFragmentAt = lastFragmentTimestampByStamp[stamp] else { return true }
        let elapsedMs = Date().timeIntervalSince(lastFragmentAt) * 1000
        // 7-second gap with no new fragments is a definitive mid-inference hang.
        // The previous 10s threshold gave up to 13s detection; 7s + 3s poll = 10s max.
        guard elapsedMs >= 7_000 else { return true }

        midStreamStalledStamps.insert(stamp)
        FreezeLogger.shared.log(
            "mid_stream_stall_detected",
            level: .warning,
            sessionID: sessionID,
            generationStamp: stamp,
            durationMs: elapsedMs,
            metadata: ["fragments": String(fragmentCountByStamp[stamp] ?? 0)]
        )
        activeTasksBySessionID[sessionID]?.cancel()
        return false
    }

    /// Escalates the timeout streak for a session and applies a cooldown or opens the circuit breaker.
    /// - streak 1 → 5s minimum floor + availability observation (60s cap)
    /// - streak 2 → 10s minimum floor + availability observation (60s cap)
    /// - streak ≥ 3 → circuit open (blocks retries for the app lifetime)
    private func applyTimeoutGovernance(sessionID: UUID, stamp: UUID) {
        let streak = (timeoutStreakBySessionID[sessionID] ?? 0) + 1
        timeoutStreakBySessionID[sessionID] = streak

        if streak >= 3 {
            guard circuitOpenedAt == nil else { return }
            circuitOpenedAt = Date()
            let msg = IntelligenceError.circuitOpen.localizedDescription
            retryBlockedBySessionID[sessionID] = msg
            FreezeLogger.shared.log(
                "model_circuit_opened",
                level: .error,
                sessionID: sessionID,
                generationStamp: stamp,
                metadata: ["streak": String(streak)]
            )
            return
        }

        // Minimum hold: 5s for streak 1, 10s for streak 2. After the floor,
        // observe availability until .available or the 60s cap expires.
        // cooldownUntil covers the full window (floor + cap) so retry()'s
        // cooldownUntilBySessionID gate remains valid throughout the wait.
        let minimumHoldSeconds: Double = streak == 1 ? 5 : 10
        let cooldownUntil = Date().addingTimeInterval(minimumHoldSeconds + 60)
        cooldownUntilBySessionID[sessionID] = cooldownUntil
        retryBlockedBySessionID[sessionID] = "Checking if model is ready\u{2026}"
        FreezeLogger.shared.log(
            "retry_cooldown_started",
            level: .warning,
            sessionID: sessionID,
            generationStamp: stamp,
            metadata: ["minimumHoldSeconds": String(Int(minimumHoldSeconds)), "streak": String(streak)]
        )
        // Phase A: unconditional minimum hold.
        // Phase B: observe availability; exit as soon as .available or 60s cap.
        // The deadline-equality guard prevents a stale task from clearing a newer cooldown.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(minimumHoldSeconds))
            guard let self else { return }
            guard self.cooldownUntilBySessionID[sessionID] == cooldownUntil else { return }

            let cap = Date().addingTimeInterval(60)
            while Date() < cap {
                if case .available = SystemLanguageModel.default.availability { break }
                try? await Task.sleep(for: .seconds(2))
            }

            guard self.cooldownUntilBySessionID[sessionID] == cooldownUntil else { return }
            self.retryBlockedBySessionID.removeValue(forKey: sessionID)
            self.cooldownUntilBySessionID.removeValue(forKey: sessionID)
            FreezeLogger.shared.log("retry_cooldown_ended", sessionID: sessionID)
        }
    }

    private func autoNameIfNeeded(session: ChatSession, firstUserText: String, modelContext: ModelContext) async {
        // Only rename sessions that still have the default title and have exactly
        // one user message + one assistant message (i.e. the very first exchange).
        guard session.title == "New Chat",
              session.messages.count == 2 else {
            FreezeLogger.shared.log(
                "autoname_skipped",
                sessionID: session.id,
                metadata: [
                    "messages": String(session.messages.count)
                ]
            )
            return
        }

        FreezeLogger.shared.log("autoname_started", sessionID: session.id)

        let fallback = "✦ " + firstUserText
            .split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            .prefix(5)
            .joined(separator: " ")

#if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            session.title = fallback
            try? modelContext.save()
            FreezeLogger.shared.log("autoname_model_unavailable", level: .warning, sessionID: session.id)
            return
        }

        let assistantText = session.orderedMessages
            .filter { $0.validatedRole == .assistant }
            .first?.text ?? ""
        let autonameSessionID = session.id

        let systemInstruction = "Generate a title for this conversation in fewer than 6 words. Respond with the title only, no quotes or punctuation."
        let namingPrompt = "User: \(firstUserText)\nAssistant: \(assistantText)"

        do {
            let namingStartedAt = Date()
            FreezeLogger.shared.log("autoname_model_call_started", sessionID: autonameSessionID)
            FreezeLogger.shared.log("autoname_model_call_detached_started", sessionID: autonameSessionID)
            let responseText = try await Task.detached(priority: .userInitiated) {
                let namingSession = LanguageModelSession(instructions: systemInstruction)
                let response = try await namingSession.respond(to: namingPrompt)
                return response.content
            }.value
            let trimmed = responseText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
            session.title = trimmed.isEmpty ? fallback : "✦ " + trimmed
            FreezeLogger.shared.log(
                "autoname_model_call_finished",
                sessionID: autonameSessionID,
                durationMs: Date().timeIntervalSince(namingStartedAt) * 1000
            )
        } catch {
            session.title = fallback
            FreezeLogger.shared.log(
                "autoname_model_call_failed",
                level: .error,
                sessionID: autonameSessionID,
                metadata: ["error": String(describing: type(of: error))]
            )
        }
        try? modelContext.save()
#else
        session.title = fallback
        try? modelContext.save()
#endif

        FreezeLogger.shared.log("autoname_finished", sessionID: session.id)
    }

    private func isDisplayableFragment(_ fragment: String) -> Bool {
        !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func friendlyErrorText(from error: Error) -> String {
        if let intelligenceError = error as? IntelligenceError {
            return intelligenceError.localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: - Prewarm

    /// Fire-and-forget: caches model weights and KV-state for the current conversation
    /// prefix so the first real token arrives faster after the user sends.
    func prewarm(for session: ChatSession) {
#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return }
        let snapshot = session.systemPromptSnapshot
        let systemPromptBudget = AIContextBuilder.estimatedTokens(forTranscript: snapshot)
        let transcript = AIContextBuilder.transcript(for: session, systemPromptBudget: systemPromptBudget)
        let sessionID = session.id
        Task.detached(priority: .background) { [weak self] in
            let modelSession = LanguageModelSession(instructions: snapshot)
            modelSession.prewarm(promptPrefix: Prompt(transcript))
            // Cache the warmed session so the next send() for this conversation can
            // reuse it, bypassing cold-start main-thread initialization in FoundationModels.
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.prewarmSessionCache[sessionID] = (systemPrompt: snapshot, session: modelSession)
            }
        }
#endif
    }

    // MARK: - Adaptive Watchdog Helpers

    /// Records a successful first-token latency into a capped ring buffer (last 5 values).
    private func recordFirstTokenLatency(_ ms: Double) {
        var recent = UserDefaults.standard.array(forKey: "intrai.recentFirstTokenMs") as? [Double] ?? []
        recent.append(ms)
        if recent.count > 5 { recent.removeFirst(recent.count - 5) }
        UserDefaults.standard.set(recent, forKey: "intrai.recentFirstTokenMs")
    }

    /// Returns the adaptive startup watchdog duration in seconds.
    /// Uses p90 of recent first-token latencies × 1.5, clamped to [15, 25].
    /// Falls back to 15 s when no history exists (the old hardcoded value was 12 s,
    /// which fired too eagerly against the observed 13.5 s real-world first-token latency).
    private func adaptiveStartupWatchdogSeconds() -> Double {
        let recent = UserDefaults.standard.array(forKey: "intrai.recentFirstTokenMs") as? [Double] ?? []
        guard !recent.isEmpty else { return 15 }
        let sorted = recent.sorted()
        let idx = max(0, Int((Double(sorted.count - 1) * 0.9).rounded()))
        let p90ms = sorted[idx]
        return min(max(p90ms / 1000.0 * 1.5, 15), 25)
    }
}
