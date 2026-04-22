//
//  Phase23Validation.swift
//  intrai
//

import Foundation
import SwiftData

private struct MockResponder: ChatResponding {
    let response: String
    let shouldThrow: Bool

    func generateResponse(
        systemPromptSnapshot: String,
        transcript: String,
        maxResponseTokens: Int
    ) async throws -> String {
        if shouldThrow {
            throw NSError(domain: "MockResponder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock failure"])
        }
        return response
    }
}

/// Mirror of the SDK's `exceededContextWindowSize` case — we match on the
/// description string in `IntelligenceService.isExceededContextWindowError`
/// so this synthetic error exercises the same routing path.
private struct FakeExceededContextWindowError: Error, CustomStringConvertible {
    var description: String { "exceededContextWindowSize" }
}

private struct ContextExceedingResponder: ChatResponding {
    func generateResponse(
        systemPromptSnapshot: String,
        transcript: String,
        maxResponseTokens: Int
    ) async throws -> String {
        throw FakeExceededContextWindowError()
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

        let service = IntelligenceService(responder: MockResponder(response: "Hello world", shouldThrow: false))
        await service.send("Hi there", in: session, modelContext: context)

        assert(session.messages.count == 2, "Expected one user message and one assistant message")
        assert(session.messages.last?.text == "Hello world", "Expected full response persisted as assistant message")
        assert(service.errorMessage(for: session) == nil, "Expected no error on successful response")

        let transcript = AIContextBuilder.transcript(for: session)
        assert(transcript.contains("user: Hi there"), "Transcript should include user prompt")
        assert(transcript.contains("assistant: Hello world"), "Transcript should include assistant response")

        let failingService = IntelligenceService(responder: MockResponder(response: "", shouldThrow: true))
        await failingService.send("This should fail", in: session, modelContext: context)
        assert(failingService.errorMessage(for: session) != nil, "Expected error state for failed generation")
        assert(!failingService.isGenerating(for: session), "Service should exit generating state after failure")

        // Phase 1: wouldExceedHangThreshold gate.
        // A long transcript exceeding the 2 000-token threshold must be rejected
        // pre-flight with .contextFullBlocked before the responder is ever called.
        let gateSession = ChatSession(title: "Gate", systemPromptSnapshot: "snapshot")
        context.insert(gateSession)
        // Build ~10 000 chars of user/assistant history — well above the hang
        // threshold (2 000 tokens ≈ 8 000 chars) even after pruning because every
        // message is small enough that the pruner cannot drop below threshold
        // without deleting the most recent exchange.
        let longChunk = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
        for _ in 0..<20 {
            gateSession.messages.append(ChatMessage(text: longChunk, role: .user))
            gateSession.messages.append(ChatMessage(text: longChunk, role: .assistant))
        }

        let gateResponder = MockResponder(response: "should never run", shouldThrow: false)
        let gateService = IntelligenceService(responder: gateResponder)
        await gateService.send("overflow prompt", in: gateSession, modelContext: context)

        assert(gateService.isContextFullBlocked(for: gateSession), "Gate should flag context as blocked")
        assert(!gateService.isGenerating(for: gateSession), "Gate must short-circuit before generation")
        assert(
            gateService.errorMessage(for: gateSession) == IntelligenceError.contextFullBlocked.localizedDescription,
            "Gate should surface .contextFullBlocked error"
        )

        // Trim action must remove messages, clear the blocked state, and let
        // the subsequent retry reach the responder.
        await gateService.trimOldestExchangesAndRetry(in: gateSession, modelContext: context)
        assert(!gateService.isContextFullBlocked(for: gateSession), "Trim should clear blocked state")
        assert(gateSession.messages.last?.validatedRole == .assistant, "Retry should produce assistant reply after trim")

        // Phase 4.3: native exceededContextWindowSize error from the model must
        // route through the same Trim / Start-new-chat UI path the pre-flight
        // gate uses, so the user sees a remediation action instead of a
        // generic error message.
        let contextErrorSession = ChatSession(title: "CtxErr", systemPromptSnapshot: "snapshot")
        context.insert(contextErrorSession)
        let contextErrorService = IntelligenceService(responder: ContextExceedingResponder())
        await contextErrorService.send("try this", in: contextErrorSession, modelContext: context)
        assert(
            contextErrorService.isContextFullBlocked(for: contextErrorSession),
            "exceededContextWindowSize must route to blocked UI"
        )
        assert(
            contextErrorService.errorMessage(for: contextErrorSession) == IntelligenceError.contextFullBlocked.localizedDescription,
            "exceededContextWindowSize must surface .contextFullBlocked error"
        )
        assert(
            !contextErrorService.isGenerating(for: contextErrorSession),
            "Service should exit generating state after exceededContextWindowSize"
        )

        // Exercise the helper directly so future refactors don't silently
        // break string matching.
        assert(
            IntelligenceService.isExceededContextWindowError(FakeExceededContextWindowError()),
            "isExceededContextWindowError should match string-based errors"
        )
    }
}
