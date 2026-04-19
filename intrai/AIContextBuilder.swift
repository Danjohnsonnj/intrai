//
//  AIContextBuilder.swift
//  intrai
//

import Foundation

struct AIContextBuilder {
    static func transcript(for session: ChatSession, includeAssistantPlaceholders: Bool = false) -> String {
        let orderedMessages = session.messages.sorted { $0.timestamp < $1.timestamp }

        return orderedMessages
            .filter { includeAssistantPlaceholders || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.validatedRole.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }
}
