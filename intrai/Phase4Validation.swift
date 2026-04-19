//
//  Phase4Validation.swift
//  intrai
//

import Foundation
import SwiftData

enum Phase4Validation {
    @MainActor
    static func run() {
        let container = try! ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            UserMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let memory = UserMemory.fetch(from: context)
        memory.update(
            facts: "Prefers concise answers.",
            systemPrompt: "You are Intrai, a private assistant."
        )

        let snapshot1 = SnapshotBuilder.compose(from: memory)
        let session = ChatSession(title: "S1", systemPromptSnapshot: snapshot1)
        context.insert(session)

        memory.update(
            facts: "Prefers long explanations.",
            systemPrompt: "You are Intrai, deeply detailed."
        )

        // Existing sessions keep their original snapshot until explicitly refreshed.
        assert(session.systemPromptSnapshot == snapshot1, "Session snapshot should remain immutable by default")

        let refreshedSnapshot = SnapshotBuilder.compose(from: memory)
        session.refreshSnapshot(refreshedSnapshot, reason: "User requested latest profile")

        assert(session.systemPromptSnapshot == refreshedSnapshot, "Expected refresh to apply latest global memory")
        assert(session.snapshotVersion == 2, "Expected snapshot version to increment")
        assert(session.lastSnapshotRefreshAt != nil, "Expected refresh timestamp to be recorded")
        assert(session.snapshotRefreshReason == "User requested latest profile", "Expected refresh reason to be recorded")

        let newSession = ChatSession(title: "S2", systemPromptSnapshot: SnapshotBuilder.compose(from: memory))
        assert(newSession.systemPromptSnapshot == refreshedSnapshot, "New sessions should use latest global memory snapshot")
    }
}
