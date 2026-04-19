//
//  Phase23Validation.swift
//  intrai
//

import Foundation
import SwiftData

private struct MockResponder: ChatResponding {
    let chunks: [String]
    let shouldThrow: Bool

    func streamResponse(systemPromptSnapshot: String, transcript: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if shouldThrow {
                continuation.finish(throwing: NSError(domain: "MockResponder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock failure"]))
                return
            }

            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

enum Phase23Validation {
    @MainActor
    static func run() async {
        let container = try! ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            UserMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let session = ChatSession(title: "Test", systemPromptSnapshot: "System snapshot")
        context.insert(session)

        let service = IntelligenceService(responder: MockResponder(chunks: ["Hello", " world"], shouldThrow: false))
        await service.send("Hi there", in: session, modelContext: context)

        assert(session.messages.count == 2, "Expected one user message and one assistant message")
        assert(session.messages.last?.text == "Hello world", "Expected streamed fragments to be combined")
        assert(service.errorMessage(for: session) == nil, "Expected no error on successful response")

        let transcript = AIContextBuilder.transcript(for: session)
        assert(transcript.contains("user: Hi there"), "Transcript should include user prompt")
        assert(transcript.contains("assistant: Hello world"), "Transcript should include assistant response")

        let failingService = IntelligenceService(responder: MockResponder(chunks: [], shouldThrow: true))
        await failingService.send("This should fail", in: session, modelContext: context)
        assert(failingService.errorMessage(for: session) != nil, "Expected error state for failed generation")
        assert(!failingService.isGenerating(for: session), "Service should exit generating state after failure")
    }
}
