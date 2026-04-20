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
    case generationTimeout

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "The prompt is empty."
        case let .unavailableModel(reason):
            return reason
        case .generationCancelled:
            return "Generation cancelled."
        case .generationTimeout:
            return "Response timed out. Tap retry to try again."
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
            // PHASE 2 FIX: Task.detached so LanguageModelSession.respond() does NOT inherit
            // main-actor execution context and cannot block the UI thread during cold-start
            // or post-background-resume model loading.
            let innerTask = Task.detached {
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
            continuation.onTermination = { _ in
                innerTask.cancel()
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
    private var pendingCancellationSessionIDs: Set<UUID> = []
    private var generationStampsBySessionID: [UUID: UUID] = [:]
    // PHASE 3: Stamps for which the 15-second watchdog fired before the first fragment arrived.
    // Used in the catch block to surface a timeout error instead of a generic cancel message.
    private var timedOutStamps: Set<UUID> = []
    // PHASE 3: Stamps for which at least one fragment has been received.
    // The watchdog checks this to avoid timing out a generation that is already streaming.
    private var firstFragmentReceivedStamps: Set<UUID> = []
    private let responder: ChatResponding

    init(responder: ChatResponding) {
        self.responder = responder
    }

    init() {
        self.responder = LocalFirstChatResponder()
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

        cancelActiveGenerationIfAny(in: session)
        pendingCancellationSessionIDs.remove(session.id)

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
        let stamp = UUID()
        generationStampsBySessionID[sessionID] = stamp
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            var assistantMessage: ChatMessage?

            defer {
                // Only clean up shared state if we are still the active generation.
                // A newer send() may have already overwritten these entries.
                if self.generationStampsBySessionID[sessionID] == stamp {
                    self.generatingSessionIDs.remove(sessionID)
                    self.activeTasksBySessionID[sessionID] = nil
                    self.generationStampsBySessionID.removeValue(forKey: sessionID)
                }
                self.pendingCancellationSessionIDs.remove(sessionID)
                self.firstFragmentReceivedStamps.remove(stamp)
            }

            do {
                for try await fragment in stream {
                    if self.firstFragmentReceivedStamps.insert(stamp).inserted {
                        // Mark that a fragment arrived so the watchdog will not fire.
                    }

                    if self.pendingCancellationSessionIDs.contains(sessionID) {
                        throw CancellationError()
                    }

                    try Task.checkCancellation()

                    if assistantMessage == nil,
                       self.isDisplayableFragment(fragment) {
                        let message = ChatMessage(text: "", role: .assistant)
                        session.messages.append(message)
                        assistantMessage = message
                    }

                    assistantMessage?.text += fragment
                }

                if self.pendingCancellationSessionIDs.contains(sessionID) || Task.isCancelled {
                    throw CancellationError()
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
                await self.autoNameIfNeeded(session: session, firstUserText: prompt, modelContext: modelContext)
            } catch is CancellationError {
                if let assistantMessage {
                    session.messages.removeAll { $0.id == assistantMessage.id }
                }
                // PHASE 3: Distinguish watchdog timeout from user-initiated cancel.
                if self.timedOutStamps.remove(stamp) != nil {
                    self.errorsBySessionID[sessionID] = IntelligenceError.generationTimeout.localizedDescription
                } else {
                    self.errorsBySessionID[sessionID] = IntelligenceError.generationCancelled.localizedDescription
                }
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

        // PHASE 3: Watchdog — fires after 15 seconds if no fragment has arrived yet.
        // The stamp guard and firstFragmentReceivedStamps check ensure this is a no-op
        // for any generation that already completed or received at least one fragment.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self else { return }
            guard self.generationStampsBySessionID[sessionID] == stamp else { return }
            guard !self.firstFragmentReceivedStamps.contains(stamp) else { return }
            self.timedOutStamps.insert(stamp)
            self.activeTasksBySessionID[sessionID]?.cancel()
        }

        activeTasksBySessionID[sessionID] = task
        if pendingCancellationSessionIDs.remove(sessionID) != nil {
            task.cancel()
        }
    }

    func retry(in session: ChatSession, modelContext: ModelContext) async {
        guard let prompt = lastFailedPromptBySessionID[session.id] else {
            return
        }
        await send(prompt, in: session, modelContext: modelContext)
    }

    func cancelGeneration(in session: ChatSession) {
        pendingCancellationSessionIDs.insert(session.id)

        if let task = activeTasksBySessionID[session.id] {
            task.cancel()
            return
        }

        if generatingSessionIDs.contains(session.id) {
            pendingCancellationSessionIDs.insert(session.id)
        }
    }

    private func cancelActiveGenerationIfAny(in session: ChatSession) {
        activeTasksBySessionID[session.id]?.cancel()
    }

    private func autoNameIfNeeded(session: ChatSession, firstUserText: String, modelContext: ModelContext) async {
        // Only rename sessions that still have the default title and have exactly
        // one user message + one assistant message (i.e. the very first exchange).
        guard session.title == "New Chat",
              session.messages.count == 2 else { return }

        let fallback = "✦ " + firstUserText
            .split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            .prefix(5)
            .joined(separator: " ")

#if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            session.title = fallback
            try? modelContext.save()
            return
        }

        let assistantText = session.messages
            .filter { $0.validatedRole == .assistant }
            .sorted { $0.timestamp < $1.timestamp }
            .first?.text ?? ""

        let systemInstruction = "Generate a title for this conversation in fewer than 6 words. Respond with the title only, no quotes or punctuation."
        let namingPrompt = "User: \(firstUserText)\nAssistant: \(assistantText)"

        do {
            let namingSession = LanguageModelSession(instructions: systemInstruction)
            let response = try await namingSession.respond(to: namingPrompt)
            let trimmed = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
            session.title = trimmed.isEmpty ? fallback : "✦ " + trimmed
        } catch {
            session.title = fallback
        }
        try? modelContext.save()
#else
        session.title = fallback
        try? modelContext.save()
#endif
    }

    private func isDisplayableFragment(_ fragment: String) -> Bool {
        !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func friendlyErrorText(from error: Error) -> String {
        if let intelligenceError = error as? IntelligenceError {
            return intelligenceError.localizedDescription
        }
        return error.localizedDescription
    }
}
