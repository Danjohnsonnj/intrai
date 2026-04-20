//
//  ChatSession.swift
//  intrai
//

import Foundation
import SwiftData

@Model
final class ChatSession {
    var id: UUID
    var title: String
    var createdAt: Date
    var systemPromptSnapshot: String
    var snapshotVersion: Int
    var lastSnapshotRefreshAt: Date?
    var snapshotRefreshReason: String?

    @Relationship(deleteRule: .cascade)
    var messages: [ChatMessage]

    init(title: String, systemPromptSnapshot: String) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.systemPromptSnapshot = systemPromptSnapshot
        self.snapshotVersion = 1
        self.lastSnapshotRefreshAt = nil
        self.snapshotRefreshReason = nil
        self.messages = []
    }

    func refreshSnapshot(_ newSnapshot: String, reason: String) {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            return
        }

        systemPromptSnapshot = newSnapshot
        snapshotVersion += 1
        lastSnapshotRefreshAt = Date()
        snapshotRefreshReason = trimmedReason
    }

    var orderedMessages: [ChatMessage] {
        messages.sorted { $0.timestamp < $1.timestamp }
    }
}
