//
//  SnapshotBuilder.swift
//  intrai
//

import Foundation

struct SnapshotBuilder {
    static let defaultSystemPrompt = "You are a helpful private AI assistant."

    static func compose(systemPrompt: String, memoryFacts: String) -> String {
        let normalizedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFacts = memoryFacts.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = normalizedSystemPrompt.isEmpty ? defaultSystemPrompt : normalizedSystemPrompt

        guard !normalizedFacts.isEmpty else {
            return prompt
        }

        return prompt + "\n\nUser context:\n" + normalizedFacts
    }

    static func compose(from memory: UserMemory) -> String {
        compose(systemPrompt: memory.systemPrompt, memoryFacts: memory.facts)
    }
}
