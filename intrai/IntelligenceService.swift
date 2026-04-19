//
//  IntelligenceService.swift
//  intrai
//

import Foundation
import Combine
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

enum IntelligenceError: LocalizedError {
    case emptyPrompt
    case unavailableModel(String)

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "The prompt is empty."
        case let .unavailableModel(reason):
            return reason
        }
    }
}

protocol ChatResponding {
    func streamResponse(systemPromptSnapshot: String, transcript: String) -> AsyncThrowingStream<String, Error>
}

struct LocalFirstChatResponder: ChatResponding {
    func streamResponse(systemPromptSnapshot: String, transcript: String) -> AsyncThrowingStream<String, Error> {
#if canImport(FoundationModels)
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let model = SystemLanguageModel.default
                    switch model.availability {
                    case .available:
                        let session = LanguageModelSession(instructions: systemPromptSnapshot)
                        let response = try await session.respond(to: transcript)
                        let fullText = response.content

                        if fullText.isEmpty {
                            continuation.finish()
                            return
                        }

                        for token in fullText.split(separator: " ", omittingEmptySubsequences: false) {
                            continuation.yield(String(token) + " ")
                        }
                        continuation.finish()
                    case .unavailable(let reason):
                        continuation.finish(throwing: IntelligenceError.unavailableModel("Apple Intelligence unavailable: \(reason)."))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
#else
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: IntelligenceError.unavailableModel("FoundationModels is unavailable in this build target."))
        }
#endif
    }
}

@MainActor
final class IntelligenceService: ObservableObject {
    @Published private(set) var generatingSessionIDs: Set<UUID> = []
    @Published private(set) var errorsBySessionID: [UUID: String] = [:]

    private var lastFailedPromptBySessionID: [UUID: String] = [:]
    private let responder: ChatResponding

    init(responder: ChatResponding = LocalFirstChatResponder()) {
        self.responder = responder
    }

    func isGenerating(for session: ChatSession) -> Bool {
        generatingSessionIDs.contains(session.id)
    }

    func errorMessage(for session: ChatSession) -> String? {
        errorsBySessionID[session.id]
    }

    func send(_ rawPrompt: String, in session: ChatSession, modelContext: ModelContext) async {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            errorsBySessionID[session.id] = IntelligenceError.emptyPrompt.localizedDescription
            return
        }

        generatingSessionIDs.insert(session.id)
        errorsBySessionID[session.id] = nil

        let userMessage = ChatMessage(text: prompt, role: .user)
        session.messages.append(userMessage)

        let assistantMessage = ChatMessage(text: "", role: .assistant)
        session.messages.append(assistantMessage)

        do {
            try modelContext.save()

            let transcript = AIContextBuilder.transcript(for: session)
            let stream = responder.streamResponse(
                systemPromptSnapshot: session.systemPromptSnapshot,
                transcript: transcript
            )

            for try await fragment in stream {
                assistantMessage.text += fragment
            }

            if assistantMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                assistantMessage.text = "(No response generated.)"
            }

            try modelContext.save()
            lastFailedPromptBySessionID[session.id] = nil
        } catch {
            session.messages.removeAll { $0.id == assistantMessage.id }
            errorsBySessionID[session.id] = error.localizedDescription
            lastFailedPromptBySessionID[session.id] = prompt

            do {
                try modelContext.save()
            } catch {
                errorsBySessionID[session.id] = "Failed to save chat state: \(error.localizedDescription)"
            }
        }

        generatingSessionIDs.remove(session.id)
    }

    func retry(in session: ChatSession, modelContext: ModelContext) async {
        guard let prompt = lastFailedPromptBySessionID[session.id] else {
            return
        }
        await send(prompt, in: session, modelContext: modelContext)
    }
}
