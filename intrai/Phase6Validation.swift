//
//  Phase6Validation.swift
//  intrai
//

import Foundation
import SwiftData

private enum Phase6ValidationError: LocalizedError {
    case generationStillRunningAfterCancellation
    case unexpectedCancellationMessage(String?)
    case assistantMessageCreatedAfterCancellation(Int)
    case orphanedAssistantPlaceholder
    case generationStillRunningAfterFailure
    case unexpectedFailureMessage(String?)

    var errorDescription: String? {
        switch self {
        case .generationStillRunningAfterCancellation:
            return "Generation should end after cancellation"
        case let .unexpectedCancellationMessage(message):
            return "Expected cancellation message, got: \(message ?? "nil")"
        case let .assistantMessageCreatedAfterCancellation(count):
            return "Expected no assistant messages after cancellation before response completed, found: \(count)"
        case .orphanedAssistantPlaceholder:
            return "Empty assistant placeholder should never exist under non-streaming responder"
        case .generationStillRunningAfterFailure:
            return "Generation should end after failure"
        case let .unexpectedFailureMessage(message):
            return "Expected surfaced failure reason, got: \(message ?? "nil")"
        }
    }
}

private struct SlowSuccessResponder: ChatResponding {
    let delayNanos: UInt64
    let response: String

    func generateResponse(
        systemPromptSnapshot: String,
        transcript: String,
        maxResponseTokens: Int
    ) async throws -> String {
        try await Task.sleep(nanoseconds: delayNanos)
        try Task.checkCancellation()
        return response
    }
}

private struct FailingMockResponder: ChatResponding {
    func generateResponse(
        systemPromptSnapshot: String,
        transcript: String,
        maxResponseTokens: Int
    ) async throws -> String {
        throw NSError(domain: "Phase6", code: 99, userInfo: [NSLocalizedDescriptionKey: "Simulated failure"])
    }
}

/// Returns a response whose estimated token count is well above the 95 % cap
/// warning threshold so the `generation_capped` log event is emitted.
private struct NearCapResponder: ChatResponding {
    func generateResponse(
        systemPromptSnapshot: String,
        transcript: String,
        maxResponseTokens: Int
    ) async throws -> String {
        // Pessimistic estimator: 3.2 chars/token → cap * 3.2 chars equals the
        // cap in tokens. Emit a string longer than the 95 % threshold so the
        // capped-response warning fires.
        let approxChars = Int(Double(maxResponseTokens) * 3.2 * 0.99)
        return String(repeating: "x", count: max(approxChars, 1))
    }
}

enum Phase6Validation {
    @MainActor
    static func run() async throws {
        let container = try! ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            UserMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        // Scenario 1: cancel well before the slow responder returns.
        // Under non-streaming the assistant message is only appended after
        // respond(to:) completes, so no partial/empty assistant should exist.
        let earlyCancelSession = ChatSession(title: "Early Cancel", systemPromptSnapshot: "snapshot")
        context.insert(earlyCancelSession)

        let earlyCancelService = IntelligenceService(responder: SlowSuccessResponder(delayNanos: 2_000_000_000, response: "late response"))
        let earlyCancelSendTask = Task {
            await earlyCancelService.send("Cancel before response completes", in: earlyCancelSession, modelContext: context)
        }

        for _ in 0..<20 where !earlyCancelService.isGenerating(for: earlyCancelSession) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        earlyCancelService.cancelGeneration(in: earlyCancelSession)
        await earlyCancelSendTask.value

        let earlyCancelAssistantCount = earlyCancelSession.messages.filter { $0.role == "assistant" }.count
        if earlyCancelAssistantCount != 0 {
            throw Phase6ValidationError.assistantMessageCreatedAfterCancellation(earlyCancelAssistantCount)
        }

        // Scenario 2: cancel shortly after send start; expect cancellation error surfaced.
        let cancellationSession = ChatSession(title: "Cancellation", systemPromptSnapshot: "snapshot")
        context.insert(cancellationSession)

        let cancellableService = IntelligenceService(responder: SlowSuccessResponder(delayNanos: 500_000_000, response: "cancelled response"))
        let sendTask = Task {
            await cancellableService.send("Please respond", in: cancellationSession, modelContext: context)
        }

        try? await Task.sleep(nanoseconds: 40_000_000)
        cancellableService.cancelGeneration(in: cancellationSession)
        await sendTask.value

        if cancellableService.isGenerating(for: cancellationSession) {
            throw Phase6ValidationError.generationStillRunningAfterCancellation
        }

        let cancellationMessage = cancellableService.errorMessage(for: cancellationSession)
        if cancellationMessage != "Generation cancelled." {
            throw Phase6ValidationError.unexpectedCancellationMessage(cancellationMessage)
        }

        let orphanedAssistant = cancellationSession.messages.first { $0.role == "assistant" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if orphanedAssistant != nil {
            throw Phase6ValidationError.orphanedAssistantPlaceholder
        }

        // Scenario 3: responder throws; expect failure reason surfaced.
        let failureSession = ChatSession(title: "Failure", systemPromptSnapshot: "snapshot")
        context.insert(failureSession)

        let failingService = IntelligenceService(responder: FailingMockResponder())
        await failingService.send("This will fail", in: failureSession, modelContext: context)

        if failingService.isGenerating(for: failureSession) {
            throw Phase6ValidationError.generationStillRunningAfterFailure
        }

        let failureMessage = failingService.errorMessage(for: failureSession)
        if failureMessage != "Simulated failure" {
            throw Phase6ValidationError.unexpectedFailureMessage(failureMessage)
        }

        // Scenario 4 (Phase 1): Start-new-chat action moves the blocked prompt
        // into a fresh session and leaves the original without the prompt.
        let bigSession = ChatSession(title: "Big", systemPromptSnapshot: "snapshot")
        context.insert(bigSession)
        let chunk = String(repeating: "Sample history text. ", count: 50)
        for _ in 0..<15 {
            bigSession.messages.append(ChatMessage(text: chunk, role: .user))
            bigSession.messages.append(ChatMessage(text: chunk, role: .assistant))
        }

        let bigService = IntelligenceService(responder: SlowSuccessResponder(delayNanos: 10_000_000, response: "ok"))
        await bigService.send("will be blocked", in: bigSession, modelContext: context)
        if !bigService.isContextFullBlocked(for: bigSession) {
            throw Phase6ValidationError.unexpectedFailureMessage("Expected context-full gate to fire for large transcript")
        }

        let originalUserCount = bigSession.messages.filter { $0.validatedRole == .user }.count
        guard let newSession = bigService.startNewChatFromBlockedPrompt(in: bigSession, modelContext: context) else {
            throw Phase6ValidationError.unexpectedFailureMessage("startNewChatFromBlockedPrompt returned nil")
        }

        let finalUserCount = bigSession.messages.filter { $0.validatedRole == .user }.count
        if finalUserCount != originalUserCount - 1 {
            throw Phase6ValidationError.unexpectedFailureMessage("Expected blocked prompt removed from original session")
        }
        if newSession.messages.count != 1 || newSession.messages.first?.text != "will be blocked" {
            throw Phase6ValidationError.unexpectedFailureMessage("Expected blocked prompt carried to new session")
        }
        if bigService.isContextFullBlocked(for: bigSession) {
            throw Phase6ValidationError.unexpectedFailureMessage("Blocked state should clear after start-new-chat")
        }

        // Phase 4.1: responder that returns a near-cap-length response must
        // flow through send() without throwing and produce an assistant
        // message. The `generation_capped` log event firing is a side effect
        // we can't assert on directly, but this exercises the code path so
        // future regressions in the cap-accounting show up as crashes here.
        let cappedSession = ChatSession(title: "Capped", systemPromptSnapshot: "snapshot")
        context.insert(cappedSession)
        let cappedService = IntelligenceService(responder: NearCapResponder())
        await cappedService.send("please produce long output", in: cappedSession, modelContext: context)
        if cappedService.errorMessage(for: cappedSession) != nil {
            throw Phase6ValidationError.unexpectedFailureMessage("NearCapResponder should not fail")
        }
        if cappedSession.messages.last?.validatedRole != .assistant {
            throw Phase6ValidationError.unexpectedFailureMessage("Expected assistant reply from NearCapResponder")
        }

        // Phase 4.4: the nonisolated accessor used by the proactive wedge
        // detector must be safe to read at any time and return 0 when the
        // MainActor heartbeat is healthy (i.e. at validation-time, with no
        // active wedge).
        let degradedMs = FreezeLogger.shared.degradedHeartbeatDurationMs
        if degradedMs < 0 {
            throw Phase6ValidationError.unexpectedFailureMessage("degradedHeartbeatDurationMs should be non-negative")
        }

        // Phase 4.5: synthesize a disk-persisted abort entry and verify
        // `latestAbortRecoveryEntry()` returns it. We write through
        // `persistDirect` (nonisolated synchronous flush) so the entry is on
        // disk by the time the read-back runs.
        let syntheticAbortID = UUID()
        DiskFreezeLogger.shared.persistDirect(
            event: "force_recovery_unreachable_mainactor",
            level: .error,
            sessionID: nil,
            generationStamp: syntheticAbortID,
            durationMs: 2_000,
            metadata: ["abortReason": "phase6_validation_synthetic"]
        )
        let latestAbort = DiskFreezeLogger.shared.latestAbortRecoveryEntry()
        if latestAbort == nil {
            throw Phase6ValidationError.unexpectedFailureMessage("Expected latestAbortRecoveryEntry to find synthetic entry")
        }

        // Phase 4 hotfix (0.2.111): the unified watchdog arms at send_start
        // and disarms when the send completes. A fast-success send() must
        // emit both `send_watchdog_armed` and `send_watchdog_disarmed` and
        // MUST NOT emit `force_recovered_from_stall` (i.e. the watchdog does
        // not spuriously trip on healthy sends). Disarm is observed by the
        // wedge timer's 1 s tick, so we wait just over one poll interval
        // before reading back.
        let watchdogSession = ChatSession(title: "Watchdog", systemPromptSnapshot: "snapshot")
        context.insert(watchdogSession)
        let watchdogService = IntelligenceService(responder: SlowSuccessResponder(delayNanos: 200_000_000, response: "ok"))
        await watchdogService.send("quick", in: watchdogSession, modelContext: context)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if !DiskFreezeLogger.shared.hasPersistedEvent("send_watchdog_armed", sessionID: watchdogSession.id) {
            throw Phase6ValidationError.unexpectedFailureMessage("Expected send_watchdog_armed for fast-success send")
        }
        if !DiskFreezeLogger.shared.hasPersistedEvent("send_watchdog_disarmed", sessionID: watchdogSession.id) {
            throw Phase6ValidationError.unexpectedFailureMessage("Expected send_watchdog_disarmed for fast-success send")
        }
        if DiskFreezeLogger.shared.hasPersistedEvent("force_recovered_from_stall", sessionID: watchdogSession.id) {
            throw Phase6ValidationError.unexpectedFailureMessage("Watchdog must not trip on fast-success send")
        }
    }
}
