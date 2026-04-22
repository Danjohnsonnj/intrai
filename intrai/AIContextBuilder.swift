//
//  AIContextBuilder.swift
//  intrai
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum ContextWindowRisk {
    case none
    case smallModelRisk
    case likelyDegradation
    case highRisk
}

/// Lock-protected holder for model-reported runtime limits. We cache these at
/// launch (and on-demand) so the synchronous pruning / risk-banner paths can
/// read a real `contextSize` without awaiting the framework on every call.
///
/// All members are `nonisolated` so the holder can be read from any actor
/// context — the `-default-isolation=MainActor` project setting would otherwise
/// isolate reads to MainActor and block callers on a potentially wedged actor.
nonisolated final class ContextRuntimeLimits: @unchecked Sendable {
    static let shared = ContextRuntimeLimits()

    private let lock = NSLock()
    nonisolated(unsafe) private var _contextSize: Int
    nonisolated(unsafe) private var _instructionTokens: Int
    nonisolated(unsafe) private var _instructionSnapshot: String?
    nonisolated(unsafe) private var _loaded: Bool

    // Fallback values until loaded. iOS 26.4 default SystemLanguageModel
    // contextSize is 4,096; keeping the same value here means the UI and
    // pruning behave identically to the previous hardcoded constants on a
    // cold start before `loadRuntimeLimits` completes.
    private static let fallbackContextSize: Int = 4_096

    private init() {
        _contextSize = Self.fallbackContextSize
        _instructionTokens = 0
        _instructionSnapshot = nil
        _loaded = false
    }

    var contextSize: Int {
        lock.lock(); defer { lock.unlock() }
        return _contextSize
    }

    var instructionTokens: Int {
        lock.lock(); defer { lock.unlock() }
        return _instructionTokens
    }

    var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return _loaded
    }

    /// Hang threshold in tokens: 49 % of contextSize. At the default 4,096 this
    /// yields 2,007 — slightly tighter than the previous hardcoded 2,000 and
    /// scales automatically if Apple ships a larger context window.
    var hangThresholdTokens: Int {
        Int((Double(contextSize) * 0.49).rounded(.down))
    }

    /// Soft pruning target: 85 % of contextSize (4,096 → 3,481). Matches the
    /// previous 3,500 hard-limit while scaling with future models.
    var hardLimitTokens: Int {
        Int((Double(contextSize) * 0.854).rounded(.down))
    }

    fileprivate func store(contextSize: Int, instructionTokens: Int, instructionSnapshot: String?) {
        lock.lock(); defer { lock.unlock() }
        _contextSize = contextSize
        _instructionTokens = instructionTokens
        _instructionSnapshot = instructionSnapshot
        _loaded = true
    }

    fileprivate func cachedInstructionTokens(for snapshot: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard _instructionSnapshot == snapshot, _loaded else { return nil }
        return _instructionTokens
    }
}

struct AIContextBuilder {
    // Risk tiers as fractions of tokenHardLimit, aligned with the hang threshold.
    // Red fires BEFORE the hang zone (hangThresholdTokens / hardLimitTokens ≈ 0.574
    // at contextSize 4,096) so users see the warning while they still have
    // room to keep chatting.
    private static let yellowThreshold: Double = 0.40
    private static let orangeThreshold: Double = 0.55
    private static let redThreshold: Double    = 0.70

    // MARK: - Runtime limits passthroughs

    /// The live hang threshold (tokens). Reads from `ContextRuntimeLimits.shared`
    /// so a future larger contextSize is picked up without a code change.
    static var tokenHangThreshold: Double {
        Double(ContextRuntimeLimits.shared.hangThresholdTokens)
    }

    /// The live soft hard-limit (tokens) used for pruning target + risk-ratio denominator.
    private static var tokenHardLimit: Double {
        Double(ContextRuntimeLimits.shared.hardLimitTokens)
    }

    /// Caches `SystemLanguageModel.default.contextSize` so the pruning and
    /// risk-banner thresholds scale automatically if Apple ships a larger
    /// context window.
    ///
    /// Hotfix 0.2.111: the framework-side token counting call
    /// (`tokenCount(for:)`) was removed from this path. Build 0.2.110
    /// diagnostics confirmed `tokenCount` can wedge the same way `respond(to:)`
    /// can, and the 3 s timeout race did not fire in the observed case. We
    /// keep `contextSize` (synchronous `Int` property read on the current SDK)
    /// because it cannot hang.
    @discardableResult
    static func loadRuntimeLimits() async -> Bool {
#if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            FreezeLogger.shared.log(
                "runtime_limits_unavailable",
                level: .warning,
                metadata: ["stage": "availability"]
            )
            return false
        }

        let start = Date()
        let ctxSize = model.contextSize
        ContextRuntimeLimits.shared.store(
            contextSize: ctxSize,
            instructionTokens: 0,
            instructionSnapshot: nil
        )
        FreezeLogger.shared.log(
            "runtime_limits_loaded",
            durationMs: Date().timeIntervalSince(start) * 1000,
            metadata: [
                "contextSize": String(ctxSize),
                "instructionTokens": "0",
                "hasSnapshot": "false"
            ]
        )
        return true
#else
        return false
#endif
    }

    /// Builds the transcript string, pruning the oldest user/assistant turn pairs
    /// until the estimated token count is within `tokenHardLimit - systemPromptBudget`. The most recent
    /// exchange is always preserved. Pruning is logged via FreezeLogger.
    static func transcript(
        for session: ChatSession,
        includeAssistantPlaceholders: Bool = false,
        systemPromptBudget: Double = 600
    ) -> String {
        var messages = session.orderedMessages.filter { msg in
            includeAssistantPlaceholders ||
            !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // Available transcript tokens = the tighter of (hard limit minus system-prompt
        // headroom) and the empirical hang threshold. The hang threshold protects us
        // from the FoundationModels instability zone; the hard-limit calculation
        // keeps a safety margin for the system prompt. Floor at 500 to guarantee we
        // always preserve at least one exchange.
        let availableBudget = max(
            min(tokenHardLimit - systemPromptBudget, tokenHangThreshold),
            500
        )

        // Prune oldest pairs while the estimated token count exceeds the available budget.
        // Always keep at least the most recent exchange (last 2 messages).
        let initialCount = messages.count
        while messages.count > 2 {
            let draft = buildTranscriptString(from: messages)
            guard estimatedTokens(forTranscript: draft) > availableBudget else { break }

            // Remove the oldest message; if the new head is an assistant turn, remove
            // that too so we never start the transcript mid-exchange.
            messages.removeFirst()
            if messages.first?.validatedRole == .assistant {
                messages.removeFirst()
            }
        }
        if messages.count < initialCount {
            FreezeLogger.shared.log(
                "transcript_pruned",
                metadata: [
                    "removedMessages": String(initialCount - messages.count),
                    "remainingMessages": String(messages.count)
                ]
            )
        }

        return buildTranscriptString(from: messages)
    }

    /// Returns the context-window risk level for the given transcript.
    static func contextRisk(forTranscript transcript: String) -> ContextWindowRisk {
        let ratio = contextFillRatio(forTranscript: transcript)
        if ratio < yellowThreshold { return .none }
        if ratio < orangeThreshold { return .smallModelRisk }
        if ratio < redThreshold    { return .likelyDegradation }
        return .highRisk
    }

    /// Returns a 0–1 fill ratio relative to `tokenHardLimit`.
    static func contextFillRatio(forTranscript transcript: String) -> Double {
        let estimated = estimatedTokens(forTranscript: transcript)
        return min(max(estimated / tokenHardLimit, 0), 1)
    }

    /// Returns true when the transcript's estimated token count is at or above
    /// `tokenHangThreshold`. Use this as a pre-send gate to avoid the
    /// FoundationModels large-prompt hang entirely.
    static func wouldExceedHangThreshold(forTranscript transcript: String) -> Bool {
        estimatedTokens(forTranscript: transcript) >= tokenHangThreshold
    }

    // MARK: - Private helpers

    private static func buildTranscriptString(from messages: [ChatMessage]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(messages.count)
        for message in messages {
            lines.append("\(message.validatedRole.rawValue): \(message.text)")
        }
        return lines.joined(separator: "\n")
    }

    static func estimatedTokens(forTranscript transcript: String) -> Double {
        let chars = Double(transcript.utf16.count)
        // Blended token estimate: 70 % optimistic (4.8 chars/token) + 30 % pessimistic (3.2 chars/token)
        let tOpt = chars / 4.8
        let tPes = chars / 3.2
        return 0.7 * tOpt + 0.3 * tPes
    }
}
