//
//  AIContextBuilder.swift
//  intrai
//

import Foundation

enum ContextWindowRisk {
    case none
    case smallModelRisk
    case likelyDegradation
    case highRisk
}

struct AIContextBuilder {
    // Actual documented limit for SystemLanguageModel.default is 4,096 tokens.
    // Reserve ~596 tokens for system prompt + response headroom → 3,500 token
    // hard pruning target. The prior constants (smallBudget 6k, mediumBudget 14k)
    // were ~3× too large and made the context progress bar nearly useless.
    private static let tokenHardLimit: Double = 3_500

    // Risk tiers as fractions of tokenHardLimit.
    private static let yellowThreshold: Double = 0.50   // 1,750 tokens
    private static let orangeThreshold: Double = 0.70   // 2,450 tokens
    private static let redThreshold: Double    = 0.80   // 2,800 tokens

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

        // Available transcript tokens = hard limit minus system-prompt headroom.
        // Floor at 500 to guarantee we always preserve at least one exchange.
        let availableBudget = max(tokenHardLimit - systemPromptBudget, 500)

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
