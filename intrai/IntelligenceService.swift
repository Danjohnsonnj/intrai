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
    case contextFullBlocked

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
        case .contextFullBlocked:
            return "This chat is near the model's context limit. Trim or start a new chat to continue."
        }
    }
}

protocol ChatResponding {
    /// Returns the full assistant response as a single String. No streaming.
    /// `maxResponseTokens` bounds the output so a runaway generation loop inside
    /// FoundationModels cannot produce an unbounded response (the primary hang
    /// hypothesis from 0.2.109 diagnostics).
    func generateResponse(
        systemPromptSnapshot: String,
        transcript: String,
        maxResponseTokens: Int
    ) async throws -> String
}

struct LocalFirstChatResponder: ChatResponding {
    // Non-streaming generation via LanguageModelSession.respond(to:options:).
    // A fresh session is created for every call — no prewarm, no cache, no reuse.
    // Wrapped in Task.detached so inference never inherits the MainActor executor
    // (the invariant established in commit 263b5da).
    //
    // The maxResponseTokens cap bounds runaway loops inside respond(to:); without
    // it, a single malformed prompt on iOS 26.4.1 can hang the framework for
    // minutes while it emits tokens the caller never sees.
    func generateResponse(
        systemPromptSnapshot: String,
        transcript: String,
        maxResponseTokens: Int
    ) async throws -> String {
#if canImport(FoundationModels)
        try await Task.detached(priority: .userInitiated) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .unavailable(let reason):
                throw IntelligenceError.unavailableModel("Apple Intelligence unavailable: \(reason).")
            case .available:
                break
            }
            let session = LanguageModelSession(instructions: systemPromptSnapshot)
            let options = GenerationOptions(maximumResponseTokens: maxResponseTokens)
            let response = try await session.respond(to: transcript, options: options)
            return response.content
        }.value
#else
        throw IntelligenceError.unavailableModel("FoundationModels is unavailable in this build target.")
#endif
    }
}

/// Cross-thread completion flag for the GCD deadline watchdog and for
/// autoname's continuation race (deadline vs. framework completion).
/// `tryMarkComplete()` provides an atomic check-and-set so exactly one side
/// of a race can resume the associated continuation.
///
/// Every member is `nonisolated` — the type is intentionally callable from
/// any context (MainActor, GCD queues, cooperative pool), since all state is
/// protected by NSLock. Without this, the `-default-isolation=MainActor` project
/// setting would isolate these methods to MainActor and block callers on a
/// MainActor that may be wedged inside a framework call.
nonisolated private final class GenerationCompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _isComplete = false

    init() {}

    func markComplete() {
        lock.lock(); defer { lock.unlock() }
        _isComplete = true
    }

    @discardableResult
    func tryMarkComplete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _isComplete { return false }
        _isComplete = true
        return true
    }

    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isComplete
    }
}

/// Lock-protected holder for the send watchdog's cancel target. The watchdog is
/// armed at `send_start` — before the generation Task exists — so the target
/// starts nil and is populated later when the Task is spawned. Reading and
/// writing are nonisolated so the GCD watchdog timers can cancel the Task
/// without hopping back to MainActor.
nonisolated private final class MutableCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _task: Task<Void, Never>?

    init() { _task = nil }

    func set(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        _task = task
    }

    var current: Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return _task
    }
}

@MainActor
final class IntelligenceService: ObservableObject {
    @Published private(set) var generatingSessionIDs: Set<UUID> = []
    @Published private(set) var errorsBySessionID: [UUID: String] = [:]
    @Published private(set) var contextProgressBySessionID: [UUID: Double] = [:]
    /// Sessions whose most recent send was rejected by the context-hang gate.
    /// The UI uses this to surface Trim / Start-new-chat actions instead of the
    /// generic Retry button.
    @Published private(set) var contextFullBlockedSessionIDs: Set<UUID> = []

    private var lastFailedPromptBySessionID: [UUID: String] = [:]
    private var activeTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var pendingCancellationSessionIDs: Set<UUID> = []
    private var generationStampsBySessionID: [UUID: UUID] = [:]
    private var sendStartedAtByStamp: [UUID: Date] = [:]
    // Fire-and-forget autoname tasks, tracked so we can cancel a previous autoname
    // before starting a new send (prevents two FoundationModels sessions from
    // racing on the same session).
    private var autonameTasksBySessionID: [UUID: Task<Void, Never>] = [:]

    // Per-stamp state the GCD deadline needs access to when firing force-recovery
    // on MainActor. Populated at send() start, cleared in the generation task's defer.
    // Keyed by stamp (not sessionID) so a force-recovery for an old stamp can never
    // read a newer send's context.
    private var modelContextByStamp: [UUID: ModelContext] = [:]
    private var promptByStamp: [UUID: String] = [:]

    // Retry governance — timeout streak, cooldown, and circuit breaker.
    // streak=1 → 5s floor + up-to-60s availability poll
    // streak=2 → 10s floor + up-to-60s availability poll
    // streak≥3 → circuit open (blocks retries for the app lifetime)
    private var timeoutStreakBySessionID: [UUID: Int] = [:]
    private var cooldownUntilBySessionID: [UUID: Date] = [:]
    private var circuitOpenedAt: Date? = nil
    @Published private(set) var retryBlockedBySessionID: [UUID: String] = [:]

    private let responder: ChatResponding

    // MARK: - GCD deadline configuration

    nonisolated private static let deadlineQueue = DispatchQueue(
        label: "com.johnsonation.intrai.generation-deadline",
        qos: .utility
    )
    /// Total wall-clock budget for a single send(), measured from `send_start`.
    /// Covers pre-flight (transcript build, gate) + generation.
    ///
    /// Hotfix 0.2.111: bumped from 20 → 25 s because the watchdog now arms
    /// *before* pre-flight (previously it only armed after `generation_started`),
    /// so it must absorb a few extra seconds of pre-flight work. The proactive
    /// wedge detector still fires after ~5 s of degraded heartbeat, so the
    /// typical wedge-to-recovery latency is unchanged; the absolute deadline
    /// is a pure backstop.
    nonisolated private static let generationDeadlineSeconds: Double = 25
    /// After the deadline fires task.cancel(), this is how long we wait for the
    /// cancellation to propagate and the task to clean up before force-recovering
    /// the UI. One second is sufficient because clean unwinds finish in < 1 s
    /// or never — if cancel doesn't propagate quickly the framework is wedged.
    nonisolated private static let graceAfterCancelSeconds: Double = 1
    /// How long we wait after scheduling the MainActor force-recovery hop
    /// before concluding MainActor is permanently wedged and aborting the
    /// process. This is strictly larger than any realistic MainActor hop on a
    /// healthy app (< 100 ms) but small enough that a wedged app terminates
    /// promptly instead of stranding the user.
    nonisolated private static let mainActorWedgeAbortSeconds: Double = 2
    /// Proactive wedge detection. Once the main-thread heartbeat reports an
    /// unbroken degraded window at or beyond this duration *during an active
    /// generation*, we trigger the same cancel → grace → force-recover → abort
    /// pipeline instead of waiting for the 20 s absolute deadline. This
    /// typically drops wedge-to-cancel latency from ~20 s to ~6–7 s, which is
    /// the only user-visible freeze window we can still shorten.
    ///
    /// TODO: revisit all three wedge thresholds (`mainActorWedgeAbortSeconds`,
    /// this value, and the grace period) after the first TestFlight pass with
    /// proactive detection enabled — the goal is to raise the abort window if
    /// proactive detection proves to be a reliable leading indicator.
    nonisolated private static let proactiveWedgeThresholdMs: Double = 5_000
    /// How often the proactive wedge monitor polls the heartbeat degraded
    /// duration. 1 s is cheap (single nonisolated lock read) and aligned with
    /// the heartbeat period.
    nonisolated private static let proactiveWedgePollIntervalSeconds: Double = 1
    /// Budget for autoname (title generation). Autoname is a 1-turn, ~10-token
    /// completion; 25 s is very generous. A hung autoname becomes invisible
    /// (fire-and-forget) rather than blocking the UI, but we still drop it so
    /// orphaned sessions don't pile up.
    nonisolated private static let autonameDeadlineSeconds: Double = 25

    // MARK: - Response length caps
    //
    // SystemLanguageModel.default.contextSize is 4,096 tokens on iOS 26.4. We
    // reserve roughly half for the response so instructions + transcript also
    // fit comfortably. Without this cap, diagnostics show respond(to:) can
    // enter a runaway generation loop on certain prompts and wedge the
    // MainActor indefinitely (0.2.109 intrai-freeze-diagnostics-1776793076).
    nonisolated private static let defaultMaxResponseTokens: Int = 2_048
    /// Autoname is a single short title; 32 tokens is ~4× typical output.
    nonisolated private static let autonameMaxResponseTokens: Int = 32
    /// When the actual response's estimated tokens exceed this fraction of the
    /// cap, we emit `generation_capped` so we can correlate truncation with
    /// user-reported quality issues.
    private static let generationCappedWarnFraction: Double = 0.95

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

    /// Returns true when the most recent send was rejected by the pre-flight
    /// context-hang gate. The UI uses this to swap the Retry button for Trim
    /// and Start-new-chat actions.
    func isContextFullBlocked(for session: ChatSession) -> Bool {
        contextFullBlockedSessionIDs.contains(session.id)
    }

    /// Returns a human-readable reason the Retry button should be suppressed,
    /// or nil if retry is currently available.
    func retryBlockedReason(for session: ChatSession) -> String? {
        retryBlockedBySessionID[session.id]
    }

    /// Removes the oldest user/assistant exchanges until the transcript drops
    /// below the hang threshold, then automatically retries the blocked prompt
    /// (which is still saved as the last user message). Called by the
    /// "Trim oldest" UI action on `.contextFullBlocked`.
    ///
    /// Destructive: deleted messages cannot be recovered. Always preserves the
    /// most recent user message (the blocked prompt) so the retry has something
    /// to respond to.
    func trimOldestExchangesAndRetry(in session: ChatSession, modelContext: ModelContext) async {
        let sessionID = session.id
        let initialCount = session.messages.count
        var removed = 0

        // Preserve at minimum the last message (the user's blocked prompt).
        // Remove oldest until we're below the hang threshold or only the last
        // message remains.
        while session.messages.count > 1 {
            let systemPromptBudget = AIContextBuilder.estimatedTokens(forTranscript: session.systemPromptSnapshot)
            let transcript = AIContextBuilder.transcript(for: session, systemPromptBudget: systemPromptBudget)
            guard AIContextBuilder.wouldExceedHangThreshold(forTranscript: transcript) else { break }

            let ordered = session.orderedMessages
            guard let oldest = ordered.first else { break }
            if let index = session.messages.firstIndex(where: { $0.id == oldest.id }) {
                session.messages.remove(at: index)
                modelContext.delete(oldest)
                removed += 1
            } else {
                break
            }

            // If the new head is an assistant message, drop it too so we never
            // start mid-exchange.
            let newOrdered = session.orderedMessages
            if let head = newOrdered.first, head.validatedRole == .assistant, session.messages.count > 1 {
                if let index = session.messages.firstIndex(where: { $0.id == head.id }) {
                    session.messages.remove(at: index)
                    modelContext.delete(head)
                    removed += 1
                }
            }
        }

        try? modelContext.save()

        FreezeLogger.shared.log(
            "context_trim_user_action",
            level: .warning,
            sessionID: sessionID,
            metadata: [
                "removedMessages": String(removed),
                "initialMessages": String(initialCount),
                "remainingMessages": String(session.messages.count)
            ]
        )

        errorsBySessionID[sessionID] = nil
        retryBlockedBySessionID.removeValue(forKey: sessionID)
        contextFullBlockedSessionIDs.remove(sessionID)
        evaluateContextProgress(for: session)

        guard let blockedPrompt = lastFailedPromptBySessionID[sessionID] else { return }

        // The blocked prompt is the last user message on disk; remove it before
        // resending so send() doesn't double-append it.
        let ordered = session.orderedMessages
        if let last = ordered.last, last.validatedRole == .user, last.text == blockedPrompt {
            if let index = session.messages.firstIndex(where: { $0.id == last.id }) {
                session.messages.remove(at: index)
                modelContext.delete(last)
                try? modelContext.save()
            }
        }

        lastFailedPromptBySessionID.removeValue(forKey: sessionID)
        await send(blockedPrompt, in: session, modelContext: modelContext)
    }

    /// Creates a new session carrying forward only the blocked prompt, deletes
    /// the blocked prompt from the original session, and returns the new
    /// session so the UI can navigate to it. Does not auto-send — the user
    /// reviews the fresh chat then taps Send themselves.
    @discardableResult
    func startNewChatFromBlockedPrompt(in session: ChatSession, modelContext: ModelContext) -> ChatSession? {
        let sessionID = session.id
        guard let blockedPrompt = lastFailedPromptBySessionID[sessionID] else { return nil }

        let ordered = session.orderedMessages
        if let last = ordered.last, last.validatedRole == .user, last.text == blockedPrompt {
            if let index = session.messages.firstIndex(where: { $0.id == last.id }) {
                session.messages.remove(at: index)
                modelContext.delete(last)
            }
        }

        let newSession = ChatSession(
            title: "New Chat",
            systemPromptSnapshot: session.systemPromptSnapshot
        )
        modelContext.insert(newSession)
        let carriedMessage = ChatMessage(text: blockedPrompt, role: .user)
        newSession.messages.append(carriedMessage)
        try? modelContext.save()

        errorsBySessionID[sessionID] = nil
        retryBlockedBySessionID.removeValue(forKey: sessionID)
        contextFullBlockedSessionIDs.remove(sessionID)
        lastFailedPromptBySessionID.removeValue(forKey: sessionID)
        evaluateContextProgress(for: session)

        FreezeLogger.shared.log(
            "context_start_new_chat_user_action",
            level: .warning,
            sessionID: sessionID,
            metadata: [
                "newSessionID": newSession.id.uuidString,
                "carriedChars": String(blockedPrompt.utf16.count)
            ]
        )

        return newSession
    }

    /// Evaluates the current transcript and updates the per-session context
    /// progress ratio. Safe to call at any time on the main actor.
    func evaluateContextProgress(for session: ChatSession) {
        let systemPromptBudget = AIContextBuilder.estimatedTokens(forTranscript: session.systemPromptSnapshot)
        let transcript = AIContextBuilder.transcript(for: session, systemPromptBudget: systemPromptBudget)
        contextProgressBySessionID[session.id] = AIContextBuilder.contextFillRatio(forTranscript: transcript)
    }

    func send(_ rawPrompt: String, in session: ChatSession, modelContext: ModelContext) async {
        await Task.yield()

        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = session.id

        guard !prompt.isEmpty else {
            errorsBySessionID[sessionID] = IntelligenceError.emptyPrompt.localizedDescription
            FreezeLogger.shared.log("send_rejected_empty_prompt", level: .warning, sessionID: sessionID)
            return
        }

        cancelActiveGenerationIfAny(in: session)
        cancelInFlightAutoname(sessionID: sessionID, reason: "new_send")
        pendingCancellationSessionIDs.remove(sessionID)

        generatingSessionIDs.insert(sessionID)
        errorsBySessionID[sessionID] = nil
        retryBlockedBySessionID.removeValue(forKey: sessionID)
        contextFullBlockedSessionIDs.remove(sessionID)

        let stamp = UUID()
        generationStampsBySessionID[sessionID] = stamp
        sendStartedAtByStamp[stamp] = Date()
        modelContextByStamp[stamp] = modelContext
        promptByStamp[stamp] = prompt

        FreezeLogger.shared.log(
            "send_start",
            sessionID: sessionID,
            generationStamp: stamp,
            metadata: [
                "existingMessages": String(session.messages.count)
            ]
        )

        // Arm the unified send watchdog *before* any potentially-hanging work
        // (transcript build, pre-flight gate, framework calls). Build 0.2.110
        // demonstrated that pre-flight could itself wedge the MainActor without
        // ever reaching `generation_started`, leaving the watchdog unarmed and
        // requiring a user force-quit. The watchdog now covers the entire send
        // path and cancels whatever Task is in `cancelTargetBox` (may be nil
        // during pre-flight — pre-flight hangs are recovered by the MainActor
        // force-recover + abort() path the same way MainActor wedges are).
        let sendComplete = GenerationCompletionSignal()
        let cancelTargetBox = MutableCancelBox()
        armSendWatchdog(
            sessionID: sessionID,
            stamp: stamp,
            signal: sendComplete,
            cancelTarget: cancelTargetBox
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
            cleanupStampState(sessionID: sessionID, stamp: stamp)
            FreezeLogger.shared.log(
                "save_user_message_failed",
                level: .error,
                sessionID: sessionID,
                generationStamp: stamp,
                durationMs: Date().timeIntervalSince(saveUserStartedAt) * 1000,
                metadata: ["error": String(describing: type(of: error))]
            )
            sendComplete.markComplete()
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

        // Pre-flight gate: refuse to call respond(to:) above the empirical hang
        // threshold. This keeps the user's saved prompt intact but short-circuits
        // the detached inference call, surfacing a .contextFullBlocked error the
        // UI handles with Trim / Start-new-chat actions.
        //
        // Hotfix 0.2.111: uses the synchronous char/token heuristic only. The
        // real-tokenizer variant (`tokenCount(for: Instructions(transcript))`)
        // was removed after 0.2.110 diagnostics showed the framework tokenizer
        // itself can wedge the MainActor, and the `withThrowingTaskGroup`
        // timeout race failed to unstick it. Losing real-token precision on the
        // gate is acceptable — the SDK's own `exceededContextWindowSize` error
        // is still routed back into the same UI path if the heuristic ever
        // under-counts.
        let gateBlocked = AIContextBuilder.wouldExceedHangThreshold(forTranscript: transcript)
        if gateBlocked {
            FreezeLogger.shared.log(
                "send_blocked_context_full",
                level: .warning,
                sessionID: sessionID,
                generationStamp: stamp,
                metadata: [
                    "transcriptChars": String(transcript.utf16.count),
                    "fillRatio": String(format: "%.4f", contextProgress(for: session)),
                    "messages": String(session.messages.count)
                ]
            )
            errorsBySessionID[sessionID] = IntelligenceError.contextFullBlocked.localizedDescription
            retryBlockedBySessionID[sessionID] = "Trim the conversation to continue."
            lastFailedPromptBySessionID[sessionID] = prompt
            contextFullBlockedSessionIDs.insert(sessionID)
            cleanupStampState(sessionID: sessionID, stamp: stamp)
            sendComplete.markComplete()
            return
        }

        let systemPromptSnapshot = session.systemPromptSnapshot
        let maxResponseTokens = Self.defaultMaxResponseTokens

        FreezeLogger.shared.log(
            "generation_started",
            sessionID: sessionID,
            generationStamp: stamp,
            metadata: ["maxResponseTokens": String(maxResponseTokens)]
        )
        FreezeLogger.shared.log(
            "generation_max_tokens",
            sessionID: sessionID,
            generationStamp: stamp,
            metadata: ["cap": String(maxResponseTokens)]
        )

        let task = Task { @MainActor [weak self] in
            guard let self else {
                sendComplete.markComplete()
                return
            }

            defer {
                // Signal the unified send watchdog that the Task finished so it
                // can skip force-recovery on the normal cancel/completion paths.
                sendComplete.markComplete()
                if self.generationStampsBySessionID[sessionID] == stamp {
                    self.generatingSessionIDs.remove(sessionID)
                    self.activeTasksBySessionID[sessionID] = nil
                    self.generationStampsBySessionID.removeValue(forKey: sessionID)
                }
                self.pendingCancellationSessionIDs.remove(sessionID)
                self.modelContextByStamp.removeValue(forKey: stamp)
                self.promptByStamp.removeValue(forKey: stamp)
                self.sendStartedAtByStamp.removeValue(forKey: stamp)
            }

            do {
                let responseText = try await self.responder.generateResponse(
                    systemPromptSnapshot: systemPromptSnapshot,
                    transcript: transcript,
                    maxResponseTokens: maxResponseTokens
                )

                if self.pendingCancellationSessionIDs.contains(sessionID) || Task.isCancelled {
                    throw CancellationError()
                }

                let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalText = trimmed.isEmpty ? "(No response generated.)" : responseText
                let assistantMessage = ChatMessage(text: finalText, role: .assistant)
                session.messages.append(assistantMessage)

                // Heuristic cap warning: estimate tokens from char count (pessimistic
                // ~3.2 chars/token). If we're near or over the configured cap, the
                // response was almost certainly truncated. Helps correlate quality
                // complaints with cap hits.
                let responseTokenEstimate = Double(responseText.utf16.count) / 3.2
                if responseTokenEstimate >= Double(maxResponseTokens) * Self.generationCappedWarnFraction {
                    FreezeLogger.shared.log(
                        "generation_capped",
                        level: .warning,
                        sessionID: sessionID,
                        generationStamp: stamp,
                        metadata: [
                            "cap": String(maxResponseTokens),
                            "estimatedTokens": String(Int(responseTokenEstimate)),
                            "chars": String(responseText.utf16.count)
                        ]
                    )
                }

                FreezeLogger.shared.log(
                    "generation_finished",
                    sessionID: sessionID,
                    generationStamp: stamp,
                    durationMs: self.sendStartedAtByStamp[stamp].map { Date().timeIntervalSince($0) * 1000 },
                    metadata: ["chars": String(responseText.utf16.count)]
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
                // Schedule autoname as a separate fire-and-forget task. It MUST NOT
                // be awaited inside this Task — a hung autoname would prevent the
                // defer below from clearing isGenerating and the UI would appear
                // frozen even though the user-visible response is already rendered.
                self.scheduleAutonameIfNeeded(session: session, firstUserText: prompt, modelContext: modelContext)
            } catch is CancellationError {
                self.errorsBySessionID[sessionID] = IntelligenceError.generationCancelled.localizedDescription
                self.lastFailedPromptBySessionID[sessionID] = prompt
                FreezeLogger.shared.log(
                    "generation_cancelled",
                    level: .warning,
                    sessionID: sessionID,
                    generationStamp: stamp
                )
                try? modelContext.save()
            } catch {
                // Route the SDK's native context-window error through the same
                // Trim / Start-new-chat UI path the pre-flight gate uses. This
                // catches cases where the real tokenizer (or our heuristic)
                // underestimated token count and the framework itself rejects
                // the prompt mid-call.
                if Self.isExceededContextWindowError(error) {
                    FreezeLogger.shared.log(
                        "generation_exceeded_context_window",
                        level: .warning,
                        sessionID: sessionID,
                        generationStamp: stamp,
                        metadata: ["error": String(describing: type(of: error))]
                    )
                    self.errorsBySessionID[sessionID] = IntelligenceError.contextFullBlocked.localizedDescription
                    self.retryBlockedBySessionID[sessionID] = "Trim the conversation to continue."
                    self.lastFailedPromptBySessionID[sessionID] = prompt
                    self.contextFullBlockedSessionIDs.insert(sessionID)
                    try? modelContext.save()
                    return
                }
                self.errorsBySessionID[sessionID] = self.friendlyErrorText(from: error)
                self.lastFailedPromptBySessionID[sessionID] = prompt
                FreezeLogger.shared.log(
                    "generation_failed",
                    level: .error,
                    sessionID: sessionID,
                    generationStamp: stamp,
                    metadata: ["error": String(describing: type(of: error))]
                )
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
            }
        }

        activeTasksBySessionID[sessionID] = task
        cancelTargetBox.set(task)
        if pendingCancellationSessionIDs.remove(sessionID) != nil {
            task.cancel()
        }
    }

    func retry(in session: ChatSession, modelContext: ModelContext) async {
        let sessionID = session.id
        guard let prompt = lastFailedPromptBySessionID[sessionID] else { return }

        if circuitOpenedAt != nil {
            FreezeLogger.shared.log("retry_blocked_circuit_open", level: .warning, sessionID: sessionID)
            return
        }

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

    /// Clears per-stamp state for an aborted generation that never reached the
    /// Task { @MainActor } coordinator (e.g. because user-message save failed).
    private func cleanupStampState(sessionID: UUID, stamp: UUID) {
        generatingSessionIDs.remove(sessionID)
        if generationStampsBySessionID[sessionID] == stamp {
            generationStampsBySessionID.removeValue(forKey: sessionID)
        }
        sendStartedAtByStamp.removeValue(forKey: stamp)
        modelContextByStamp.removeValue(forKey: stamp)
        promptByStamp.removeValue(forKey: stamp)
    }

    // MARK: - Send watchdog (GCD)

    /// Arms the unified send watchdog on an OS-managed queue that is not
    /// subject to the Swift cooperative thread pool or MainActor starvation.
    /// Called at `send_start` so it covers pre-flight (transcript build,
    /// context evaluation, gate check) *and* generation; build 0.2.110
    /// demonstrated pre-flight itself can wedge the MainActor without ever
    /// reaching `generation_started`.
    ///
    /// `cancelTarget` starts nil and is populated later when the generation
    /// Task is spawned. If the wedge detector fires before the Task exists,
    /// the recovery pipeline skips `task.cancel()` (nothing to cancel) and
    /// proceeds directly to the grace → force-recover → abort sequence; a
    /// framework-wedged MainActor is not cooperatively cancellable anyway,
    /// which is why the `abort()` backstop exists.
    private func armSendWatchdog(
        sessionID: UUID,
        stamp: UUID,
        signal: GenerationCompletionSignal,
        cancelTarget: MutableCancelBox
    ) {
        // Single-shot atomic guard: whichever of the two monitors (absolute
        // deadline or proactive wedge detector) fires first claims this and
        // triggers the shared recovery pipeline. The other monitor observes the
        // claim via `tryMarkComplete()` and exits quietly.
        let recoveryStarted = GenerationCompletionSignal()

        // Absolute deadline — backstop for the worst case.
        let deadlineTimer = DispatchSource.makeTimerSource(queue: Self.deadlineQueue)
        deadlineTimer.schedule(deadline: .now() + Self.generationDeadlineSeconds)

        // Proactive wedge detector — leading indicator via heartbeat-degraded
        // duration. Reading `degradedHeartbeatDurationMs` is a single lock acquire
        // with no MainActor hop, so this polling is safe even when MainActor is
        // wedged (which is exactly when we need it to fire). The same tick is
        // used to notice a clean completion and emit `send_watchdog_disarmed`.
        let wedgeTimer = DispatchSource.makeTimerSource(queue: Self.deadlineQueue)
        wedgeTimer.schedule(
            deadline: .now() + Self.proactiveWedgePollIntervalSeconds,
            repeating: .seconds(Int(Self.proactiveWedgePollIntervalSeconds))
        )

        DiskFreezeLogger.shared.persistDirect(
            event: "send_watchdog_armed",
            level: .info,
            sessionID: sessionID,
            generationStamp: stamp,
            durationMs: nil,
            metadata: [
                "deadlineSeconds": String(Int(Self.generationDeadlineSeconds)),
                "wedgeThresholdMs": String(Int(Self.proactiveWedgeThresholdMs))
            ]
        )

        deadlineTimer.setEventHandler { [weak self] in
            if signal.isComplete {
                deadlineTimer.cancel()
                wedgeTimer.cancel()
                return
            }
            guard recoveryStarted.tryMarkComplete() else {
                deadlineTimer.cancel()
                return
            }
            deadlineTimer.cancel()
            wedgeTimer.cancel()

            let hadCancelTarget = cancelTarget.current != nil
            DiskFreezeLogger.shared.persistDirect(
                event: "generation_deadline_fired",
                level: .warning,
                sessionID: sessionID,
                generationStamp: stamp,
                durationMs: Self.generationDeadlineSeconds * 1000,
                metadata: ["cancelTargetPresent": hadCancelTarget ? "true" : "false"]
            )
            if !hadCancelTarget {
                DiskFreezeLogger.shared.persistDirect(
                    event: "preflight_hang_detected",
                    level: .error,
                    sessionID: sessionID,
                    generationStamp: stamp,
                    durationMs: Self.generationDeadlineSeconds * 1000,
                    metadata: ["trigger": "absolute_deadline"]
                )
            }

            self?.runRecoveryPipeline(
                sessionID: sessionID,
                stamp: stamp,
                signal: signal,
                cancelTarget: cancelTarget
            )
        }

        wedgeTimer.setEventHandler { [weak self] in
            if signal.isComplete {
                wedgeTimer.cancel()
                deadlineTimer.cancel()
                DiskFreezeLogger.shared.persistDirect(
                    event: "send_watchdog_disarmed",
                    level: .info,
                    sessionID: sessionID,
                    generationStamp: stamp,
                    durationMs: nil,
                    metadata: ["reason": "send_complete"]
                )
                return
            }
            let wedgeMs = FreezeLogger.shared.degradedHeartbeatDurationMs
            guard wedgeMs >= Self.proactiveWedgeThresholdMs else { return }
            guard recoveryStarted.tryMarkComplete() else {
                wedgeTimer.cancel()
                return
            }
            wedgeTimer.cancel()
            deadlineTimer.cancel()

            let hadCancelTarget = cancelTarget.current != nil
            DiskFreezeLogger.shared.persistDirect(
                event: "generation_early_cancel_wedge_detected",
                level: .warning,
                sessionID: sessionID,
                generationStamp: stamp,
                durationMs: wedgeMs,
                metadata: [
                    "thresholdMs": String(Int(Self.proactiveWedgeThresholdMs)),
                    "deadlineSeconds": String(Int(Self.generationDeadlineSeconds)),
                    "cancelTargetPresent": hadCancelTarget ? "true" : "false"
                ]
            )
            if !hadCancelTarget {
                DiskFreezeLogger.shared.persistDirect(
                    event: "preflight_hang_detected",
                    level: .error,
                    sessionID: sessionID,
                    generationStamp: stamp,
                    durationMs: wedgeMs,
                    metadata: ["trigger": "proactive_wedge"]
                )
            }

            self?.runRecoveryPipeline(
                sessionID: sessionID,
                stamp: stamp,
                signal: signal,
                cancelTarget: cancelTarget
            )
        }

        deadlineTimer.resume()
        wedgeTimer.resume()
    }

    /// Shared recovery pipeline invoked from either the absolute deadline or
    /// the proactive wedge detector. Runs the task.cancel → grace → force-recover
    /// → abort sequence; entirely GCD-driven so it cannot be blocked by a
    /// MainActor wedge.
    nonisolated private func runRecoveryPipeline(
        sessionID: UUID,
        stamp: UUID,
        signal: GenerationCompletionSignal,
        cancelTarget: MutableCancelBox
    ) {
        cancelTarget.current?.cancel()

        let graceTimer = DispatchSource.makeTimerSource(queue: Self.deadlineQueue)
        graceTimer.schedule(deadline: .now() + Self.graceAfterCancelSeconds)
        graceTimer.setEventHandler { [weak self] in
            graceTimer.cancel()
            if signal.isComplete { return }

            DiskFreezeLogger.shared.persistDirect(
                event: "generation_grace_expired",
                level: .warning,
                sessionID: sessionID,
                generationStamp: stamp,
                durationMs: Self.graceAfterCancelSeconds * 1000,
                metadata: [:]
            )

            // Signal owned by the GCD pipeline. `forceRecoverStalledGeneration`
            // marks it complete as its first MainActor statement, so if this
            // flag is still false after `mainActorWedgeAbortSeconds` we have
            // proof the MainActor hop never ran — MainActor is wedged and
            // the app cannot recover in-process.
            let recoverySignal = GenerationCompletionSignal()

            Task { @MainActor [weak self] in
                self?.forceRecoverStalledGeneration(
                    sessionID: sessionID,
                    stamp: stamp,
                    recoverySignal: recoverySignal
                )
            }

            let abortTimer = DispatchSource.makeTimerSource(queue: Self.deadlineQueue)
            abortTimer.schedule(deadline: .now() + Self.mainActorWedgeAbortSeconds)
            abortTimer.setEventHandler {
                abortTimer.cancel()
                if recoverySignal.isComplete { return }

                DiskFreezeLogger.shared.persistDirect(
                    event: "force_recovery_unreachable_mainactor",
                    level: .error,
                    sessionID: sessionID,
                    generationStamp: stamp,
                    durationMs: Self.mainActorWedgeAbortSeconds * 1000,
                    metadata: [
                        "abortReason": "mainactor_wedged",
                        "generationDeadlineSeconds": String(Int(Self.generationDeadlineSeconds)),
                        "graceAfterCancelSeconds": String(Int(Self.graceAfterCancelSeconds))
                    ]
                )

                // Intentional hard termination. `abort()` generates a crash
                // report (Settings → Privacy → Analytics → Analytics Data),
                // giving us persistent evidence of MainActor wedges in the
                // wild. The app is already unusable at this point; the only
                // alternative is stranding the user indefinitely.
                abort()
            }
            abortTimer.resume()
        }
        graceTimer.resume()
    }

    // MARK: - Force recovery

    /// Last-resort UI unfreeze. Runs on MainActor; hop may be queued behind a busy
    /// MainActor, but the GCD disk breadcrumbs have already confirmed the stall
    /// regardless of whether this hop runs promptly.
    ///
    /// Stamp-guarded so a late recovery cannot clobber state owned by a newer
    /// generation that the user started after the UI unfroze.
    ///
    /// `recoverySignal` is marked complete as the very first statement so the
    /// GCD abort watchdog knows MainActor is reachable, even when the stamp
    /// guard early-returns. If this hop never runs, the abort watchdog fires
    /// `force_recovery_unreachable_mainactor` and terminates the process.
    private func forceRecoverStalledGeneration(
        sessionID: UUID,
        stamp: UUID,
        recoverySignal: GenerationCompletionSignal
    ) {
        recoverySignal.markComplete()

        guard generationStampsBySessionID[sessionID] == stamp else {
            FreezeLogger.shared.log(
                "force_recovery_skipped_stale",
                level: .warning,
                sessionID: sessionID,
                generationStamp: stamp
            )
            return
        }

        // Preserve whatever made it into SwiftData so far (the user message always,
        // plus anything the generation task had time to append before wedging).
        if let ctx = modelContextByStamp[stamp] {
            try? ctx.save()
        }

        errorsBySessionID[sessionID] = IntelligenceError.generationStalled.localizedDescription
        if let prompt = promptByStamp[stamp] {
            lastFailedPromptBySessionID[sessionID] = prompt
        }
        generatingSessionIDs.remove(sessionID)
        activeTasksBySessionID[sessionID] = nil
        generationStampsBySessionID.removeValue(forKey: sessionID)
        modelContextByStamp.removeValue(forKey: stamp)
        promptByStamp.removeValue(forKey: stamp)
        sendStartedAtByStamp.removeValue(forKey: stamp)

        // Feed the stall into existing retry governance so repeated stalls still
        // trip the circuit breaker and apply cooldown backoff.
        applyTimeoutGovernance(sessionID: sessionID, stamp: stamp)

        FreezeLogger.shared.log(
            "force_recovered_from_stall",
            level: .warning,
            sessionID: sessionID,
            generationStamp: stamp
        )
        // The orphaned Task.detached inference closure still holds its
        // LanguageModelSession. iOS reclaims it on process exit; otherwise it sits
        // idle until the framework eventually resumes (if it ever does) and its
        // return value is simply dropped.
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(minimumHoldSeconds))
            guard let self else { return }
            guard self.cooldownUntilBySessionID[sessionID] == cooldownUntil else { return }

#if canImport(FoundationModels)
            let cap = Date().addingTimeInterval(60)
            while Date() < cap {
                if case .available = SystemLanguageModel.default.availability { break }
                try? await Task.sleep(for: .seconds(2))
            }
#endif

            guard self.cooldownUntilBySessionID[sessionID] == cooldownUntil else { return }
            self.retryBlockedBySessionID.removeValue(forKey: sessionID)
            self.cooldownUntilBySessionID.removeValue(forKey: sessionID)
            FreezeLogger.shared.log("retry_cooldown_ended", sessionID: sessionID)
        }
    }

    // MARK: - Auto-naming

    /// Cancels any in-flight autoname task for the given session so we never
    /// have two FoundationModels sessions racing against each other when the
    /// user sends a new message.
    private func cancelInFlightAutoname(sessionID: UUID, reason: String) {
        guard let existing = autonameTasksBySessionID[sessionID] else { return }
        existing.cancel()
        autonameTasksBySessionID.removeValue(forKey: sessionID)
        FreezeLogger.shared.log(
            "autoname_cancelled_by_new_send",
            level: .warning,
            sessionID: sessionID,
            metadata: ["reason": reason]
        )
    }

    /// Launches autoname as a fire-and-forget MainActor task so a hung
    /// autoname never blocks the generation Task's `defer` from clearing
    /// `isGenerating`. Tracks the task so a subsequent send can cancel it.
    private func scheduleAutonameIfNeeded(session: ChatSession, firstUserText: String, modelContext: ModelContext) {
        let sessionID = session.id
        guard session.title == "New Chat",
              session.messages.count == 2 else {
            FreezeLogger.shared.log(
                "autoname_skipped",
                sessionID: sessionID,
                metadata: ["messages": String(session.messages.count)]
            )
            return
        }

        // Replace any prior autoname task (there shouldn't be one since autoname
        // only runs on the first exchange, but be defensive).
        autonameTasksBySessionID[sessionID]?.cancel()

        FreezeLogger.shared.log("autoname_scheduled", sessionID: sessionID)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.autonameTasksBySessionID[sessionID] != nil {
                    self.autonameTasksBySessionID.removeValue(forKey: sessionID)
                }
            }
            await self.runAutonameWithDeadline(
                session: session,
                firstUserText: firstUserText,
                modelContext: modelContext
            )
        }
        autonameTasksBySessionID[sessionID] = task
    }

    @MainActor
    private func runAutonameWithDeadline(session: ChatSession, firstUserText: String, modelContext: ModelContext) async {
        let sessionID = session.id
        FreezeLogger.shared.log("autoname_started", sessionID: sessionID)

        let fallback = "✦ " + firstUserText
            .split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            .prefix(5)
            .joined(separator: " ")

#if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            session.title = fallback
            try? modelContext.save()
            FreezeLogger.shared.log("autoname_model_unavailable", level: .warning, sessionID: sessionID)
            return
        }

        let assistantText = session.orderedMessages
            .filter { $0.validatedRole == .assistant }
            .first?.text ?? ""

        let systemInstruction = "Generate a title for this conversation in fewer than 6 words. Respond with the title only, no quotes or punctuation."
        let namingPrompt = "User: \(firstUserText)\nAssistant: \(assistantText)"

        do {
            let namingStartedAt = Date()
            FreezeLogger.shared.log("autoname_model_call_started", sessionID: sessionID)
            let responseText = try await Self.raceAutonameAgainstDeadline(
                systemInstruction: systemInstruction,
                namingPrompt: namingPrompt,
                sessionID: sessionID,
                deadline: Self.autonameDeadlineSeconds
            )
            let trimmed = responseText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
            session.title = trimmed.isEmpty ? fallback : "✦ " + trimmed
            FreezeLogger.shared.log(
                "autoname_model_call_finished",
                sessionID: sessionID,
                durationMs: Date().timeIntervalSince(namingStartedAt) * 1000
            )
        } catch is CancellationError {
            FreezeLogger.shared.log("autoname_cancelled", level: .warning, sessionID: sessionID)
            return
        } catch {
            session.title = fallback
            FreezeLogger.shared.log(
                "autoname_model_call_failed",
                level: .error,
                sessionID: sessionID,
                metadata: ["error": String(describing: type(of: error))]
            )
        }
        try? modelContext.save()
#else
        session.title = fallback
        try? modelContext.save()
#endif

        FreezeLogger.shared.log("autoname_finished", sessionID: sessionID)
    }

#if canImport(FoundationModels)
    /// Races the autoname `respond(to:)` call against a GCD timer on a
    /// non-cooperative queue. Whichever side wins first resumes the
    /// continuation; the loser's result is discarded. Immune to cooperative
    /// thread-pool starvation on the timer path (the same property that lets
    /// the main generation deadline fire reliably).
    nonisolated private static func raceAutonameAgainstDeadline(
        systemInstruction: String,
        namingPrompt: String,
        sessionID: UUID,
        deadline: Double
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let signal = GenerationCompletionSignal()
            let maxTokens = Self.autonameMaxResponseTokens

            let timer = DispatchSource.makeTimerSource(queue: Self.deadlineQueue)
            timer.schedule(deadline: .now() + deadline)
            timer.setEventHandler {
                guard signal.tryMarkComplete() else { return }
                timer.cancel()
                DiskFreezeLogger.shared.persistDirect(
                    event: "autoname_deadline_fired",
                    level: .warning,
                    sessionID: sessionID,
                    generationStamp: nil,
                    durationMs: deadline * 1000,
                    metadata: ["maxTokens": String(maxTokens)]
                )
                continuation.resume(throwing: IntelligenceError.generationStalled)
            }
            timer.resume()

            Task.detached(priority: .userInitiated) {
                do {
                    let session = LanguageModelSession(instructions: systemInstruction)
                    let options = GenerationOptions(maximumResponseTokens: maxTokens)
                    let response = try await session.respond(to: namingPrompt, options: options)
                    guard signal.tryMarkComplete() else {
                        DiskFreezeLogger.shared.persistDirect(
                            event: "autoname_result_dropped_after_deadline",
                            level: .warning,
                            sessionID: sessionID,
                            generationStamp: nil,
                            durationMs: nil,
                            metadata: [:]
                        )
                        return
                    }
                    timer.cancel()
                    continuation.resume(returning: response.content)
                } catch {
                    guard signal.tryMarkComplete() else { return }
                    timer.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
#endif

    private func friendlyErrorText(from error: Error) -> String {
        if let intelligenceError = error as? IntelligenceError {
            return intelligenceError.localizedDescription
        }
        return error.localizedDescription
    }

    /// Detects the SDK's native context-window error without requiring
    /// validation mocks to import FoundationModels. We match both the typed
    /// enum case (when FoundationModels is available) and a loose string match
    /// against the error description / underlying type name so synthetic test
    /// errors can exercise the same routing.
    nonisolated static func isExceededContextWindowError(_ error: Error) -> Bool {
#if canImport(FoundationModels)
        if let genError = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = genError {
            return true
        }
#endif
        let typeName = String(describing: type(of: error))
        let description = String(describing: error)
        return typeName.contains("exceededContextWindowSize")
            || description.contains("exceededContextWindowSize")
            || description.contains("ExceededContextWindowSize")
    }
}
