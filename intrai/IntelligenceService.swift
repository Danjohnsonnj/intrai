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
    case generationCancelled

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "The prompt is empty."
        case let .unavailableModel(reason):
            return reason
        case .generationCancelled:
            return "Generation cancelled."
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
    private var activeTasksBySessionID: [UUID: Task<Void, Never>] = [:]
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

        cancelGeneration(in: session)

        generatingSessionIDs.insert(session.id)
        errorsBySessionID[session.id] = nil

        let userMessage = ChatMessage(text: prompt, role: .user)
        session.messages.append(userMessage)

        do {
            try modelContext.save()
        } catch {
            errorsBySessionID[session.id] = "Failed to save chat state: \(error.localizedDescription)"
            generatingSessionIDs.remove(session.id)
            return
        }

        let transcript = AIContextBuilder.transcript(for: session)
        let stream = responder.streamResponse(
            systemPromptSnapshot: session.systemPromptSnapshot,
            transcript: transcript
        )

        let sessionID = session.id
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            var assistantMessage: ChatMessage?

            defer {
                self.generatingSessionIDs.remove(sessionID)
                self.activeTasksBySessionID[sessionID] = nil
            }

            do {
                for try await fragment in stream {
                    try Task.checkCancellation()

                    if assistantMessage == nil,
                       !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let message = ChatMessage(text: "", role: .assistant)
                        session.messages.append(message)
                        assistantMessage = message
                    }

                    assistantMessage?.text += fragment
                }

                if assistantMessage == nil {
                    let message = ChatMessage(text: "(No response generated.)", role: .assistant)
                    session.messages.append(message)
                    assistantMessage = message
                } else if assistantMessage?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    assistantMessage?.text = "(No response generated.)"
                }

                try modelContext.save()
                self.lastFailedPromptBySessionID[sessionID] = nil
            } catch is CancellationError {
                if let assistantMessage {
                    session.messages.removeAll { $0.id == assistantMessage.id }
                }
                self.errorsBySessionID[sessionID] = IntelligenceError.generationCancelled.localizedDescription
                self.lastFailedPromptBySessionID[sessionID] = prompt
                try? modelContext.save()
            } catch {
                if let assistantMessage {
                    session.messages.removeAll { $0.id == assistantMessage.id }
                }
                self.errorsBySessionID[sessionID] = self.friendlyErrorText(from: error)
                self.lastFailedPromptBySessionID[sessionID] = prompt

                do {
                    try modelContext.save()
                } catch {
                    self.errorsBySessionID[sessionID] = "Failed to save chat state: \(error.localizedDescription)"
                }
            }
        }

        activeTasksBySessionID[sessionID] = task
        await task.value
    }

    func retry(in session: ChatSession, modelContext: ModelContext) async {
        guard let prompt = lastFailedPromptBySessionID[session.id] else {
            return
        }
        await send(prompt, in: session, modelContext: modelContext)
    }

    func cancelGeneration(in session: ChatSession) {
        activeTasksBySessionID[session.id]?.cancel()
    }

    private func friendlyErrorText(from error: Error) -> String {
        if let intelligenceError = error as? IntelligenceError {
            return intelligenceError.localizedDescription
        }
        return error.localizedDescription
    }
}
