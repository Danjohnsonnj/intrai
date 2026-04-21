//
//  UserMemory.swift
//  intrai
//

import Foundation
import SwiftData

/// A persistent singleton that stores global user facts.
/// Only one instance should ever exist; use `UserMemory.fetch(from:)` to load or create it.
@Model
final class UserMemory {
    var facts: String
    var systemPrompt: String
    var updatedAt: Date

    init(facts: String = "", systemPrompt: String = SnapshotBuilder.defaultSystemPrompt) {
        self.facts = facts
        self.systemPrompt = systemPrompt
        self.updatedAt = Date()
    }

    func update(facts: String, systemPrompt: String) {
        self.facts = facts.normalizedWhitespace
        self.systemPrompt = systemPrompt.normalizedWhitespace
        self.updatedAt = Date()
    }

    /// Loads the existing singleton, or inserts a fresh one if none exists.
    static func fetch(from context: ModelContext) -> UserMemory {
        let descriptor = FetchDescriptor<UserMemory>()
        if let existing = try? context.fetch(descriptor), let first = existing.first {
            return first
        }
        let memory = UserMemory()
        context.insert(memory)
        return memory
    }
}

private extension String {
    /// Collapses runs of 3+ newlines to 2, and trims leading/trailing whitespace.
    var normalizedWhitespace: String {
        let collapsed = self.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
