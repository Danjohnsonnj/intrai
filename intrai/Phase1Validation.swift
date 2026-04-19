//
//  Phase1Validation.swift
//  intrai
//

import Foundation
import SwiftData

enum Phase1Validation {
    static func assertSnapshotImmutabilityAndRefresh() {
        let memory = UserMemory(facts: "Swift Developer", systemPrompt: "Be concise")
        let initialSnapshot = SnapshotBuilder.compose(from: memory)
        let session = ChatSession(title: "Validation", systemPromptSnapshot: initialSnapshot)

        memory.update(facts: "iOS Engineer", systemPrompt: "Be detailed")

        assert(session.systemPromptSnapshot == initialSnapshot, "Session snapshot should remain immutable by default.")
        assert(session.snapshotVersion == 1, "New sessions should start at snapshot version 1.")

        let refreshedSnapshot = SnapshotBuilder.compose(from: memory)
        session.refreshSnapshot(refreshedSnapshot, reason: "User requested refresh")

        assert(session.systemPromptSnapshot == refreshedSnapshot, "Refresh should replace the session snapshot.")
        assert(session.snapshotVersion == 2, "Refresh should increment snapshot version.")
        assert(session.snapshotRefreshReason == "User requested refresh", "Refresh should persist reason metadata.")
        assert(session.lastSnapshotRefreshAt != nil, "Refresh should set refresh timestamp.")
    }

    static func assertRoleNormalization() {
        let user = ChatMessage(text: "hi", role: "USER")
        assert(user.role == ChatRole.user.rawValue, "Role normalization should coerce to lowercase enum value.")

        let assistant = ChatMessage(text: "hello", role: ChatRole.assistant)
        assert(assistant.validatedRole == .assistant, "Enum initializer should preserve valid role values.")

        let fallback = ChatMessage(text: "oops", role: "invalid")
        assert(fallback.validatedRole == .user, "Invalid roles should fall back to user.")
    }

    static func assertCascadeRelationship() {
        let container = try! ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            UserMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let session = ChatSession(title: "Cascade", systemPromptSnapshot: "prompt")
        let message = ChatMessage(text: "hello", role: .user)
        session.messages.append(message)
        context.insert(session)

        try! context.save()
        context.delete(session)
        try! context.save()

        let remaining = try! context.fetch(FetchDescriptor<ChatMessage>())
        assert(remaining.isEmpty, "Deleting session must cascade and remove related messages.")
    }
}
