//
//  Phase6Validation.swift
//  intrai
//

import Foundation
import SwiftData

private enum Phase6ValidationError: LocalizedError {
    case generationStillRunningAfterCancellation
    case unexpectedCancellationMessage(String?)
    case orphanedAssistantPlaceholder
    case generationStillRunningAfterFailure
    case unexpectedFailureMessage(String?)

    var errorDescription: String? {
        switch self {
        case .generationStillRunningAfterCancellation:
            return "Generation should end after cancellation"
        case let .unexpectedCancellationMessage(message):
            return "Expected cancellation message, got: \(message ?? "nil")"
        case .orphanedAssistantPlaceholder:
            return "Empty assistant placeholder should be removed on cancellation"
        case .generationStillRunningAfterFailure:
            return "Generation should end after failure"
        case let .unexpectedFailureMessage(message):
            return "Expected surfaced failure reason, got: \(message ?? "nil")"
        }
    }
}

private struct DelayedMockResponder: ChatResponding {
    func streamResponse(systemPromptSnapshot: String, transcript: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await Task.sleep(nanoseconds: 120_000_000)
                    continuation.yield("chunk1 ")
                    try await Task.sleep(nanoseconds: 120_000_000)
                    continuation.yield("chunk2")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private struct FailingMockResponder: ChatResponding {
    func streamResponse(systemPromptSnapshot: String, transcript: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: NSError(domain: "Phase6", code: 99, userInfo: [NSLocalizedDescriptionKey: "Simulated failure"]))
        }
    }
}

enum Phase6Validation {
    @MainActor
    static func run() async throws {
        let container = try! ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            UserMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let cancellationSession = ChatSession(title: "Cancellation", systemPromptSnapshot: "snapshot")
        context.insert(cancellationSession)

        let cancellableService = IntelligenceService(responder: DelayedMockResponder())
        let sendTask = Task {
            await cancellableService.send("Please respond", in: cancellationSession, modelContext: context)
        }

        try? await Task.sleep(nanoseconds: 40_000_000)
        cancellableService.cancelGeneration(in: cancellationSession)
        await sendTask.value

        if cancellableService.isGenerating(for: cancellationSession) {
            throw Phase6ValidationError.generationStillRunningAfterCancellation
        }

        let cancellationMessage = cancellableService.errorMessage(for: cancellationSession)
        if cancellationMessage != "Generation cancelled." {
            throw Phase6ValidationError.unexpectedCancellationMessage(cancellationMessage)
        }

        // Assistant placeholder should be removed; no empty-text assistant message should remain.
        let orphanedAssistant = cancellationSession.messages.first { $0.role == "assistant" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if orphanedAssistant != nil {
            throw Phase6ValidationError.orphanedAssistantPlaceholder
        }

        let failureSession = ChatSession(title: "Failure", systemPromptSnapshot: "snapshot")
        context.insert(failureSession)

        let failingService = IntelligenceService(responder: FailingMockResponder())
        await failingService.send("This will fail", in: failureSession, modelContext: context)

        if failingService.isGenerating(for: failureSession) {
            throw Phase6ValidationError.generationStillRunningAfterFailure
        }

        let failureMessage = failingService.errorMessage(for: failureSession)
        if failureMessage != "Simulated failure" {
            throw Phase6ValidationError.unexpectedFailureMessage(failureMessage)
        }
    }
}
