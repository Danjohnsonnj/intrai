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
    private static let smallBudget: Double = 6_000
    private static let mediumBudget: Double = 14_000
    private static let highRiskStart: Double = 0.85 * mediumBudget

    static func transcript(for session: ChatSession, includeAssistantPlaceholders: Bool = false) -> String {
        var lines: [String] = []
        lines.reserveCapacity(session.messages.count)

        for message in session.orderedMessages {
            if !includeAssistantPlaceholders && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            lines.append("\(message.validatedRole.rawValue): \(message.text)")
        }

        return lines.joined(separator: "\n")
    }

    /// Estimates context-window risk for the given transcript using a blended
    /// token estimate biased toward the optimistic side to delay warnings.
    /// Candidate windows: 8k / 16k / 32k; ~2k headroom reserved for system
    /// prompt and response budget. Warn at 75 % of the 8k budget, 100 % of the
    /// 8k budget, and 85 % of the 14k budget respectively.
    static func contextRisk(forTranscript transcript: String) -> ContextWindowRisk {
        let t = estimatedTokens(forTranscript: transcript)

        if t < 0.75 * smallBudget {
            return .none
        } else if t < smallBudget {
            return .smallModelRisk
        } else if t < highRiskStart {
            return .likelyDegradation
        } else {
            return .highRisk
        }
    }

    static func contextFillRatio(forTranscript transcript: String) -> Double {
        let estimated = estimatedTokens(forTranscript: transcript)
        guard highRiskStart > 0 else { return 0 }
        return min(max(estimated / highRiskStart, 0), 1)
    }

    private static func estimatedTokens(forTranscript transcript: String) -> Double {
        let chars = Double(transcript.utf16.count)
        // Blended token estimate: 70 % optimistic (4.8 chars/token) + 30 % pessimistic (3.2 chars/token)
        let tOpt = chars / 4.8
        let tPes = chars / 3.2
        return 0.7 * tOpt + 0.3 * tPes
    }
}
