//
//  Phase5Validation.swift
//  intrai
//

import Foundation
import SwiftData

enum Phase5Validation {
    @MainActor
    static func run() {
        let container = try! ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            UserMemory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let session = ChatSession(title: "Export Test", systemPromptSnapshot: "snapshot")
        session.messages.append(ChatMessage(text: "Hello", role: .user))
        session.messages.append(ChatMessage(text: "Hi there", role: .assistant))
        context.insert(session)

        let markdown = ChatExport.markdown(for: session)
        assert(markdown.contains("# Export Test"), "Markdown should contain session title header")
        assert(markdown.contains("Date:"), "Markdown should contain a date field")
        assert(markdown.contains("### User"), "Markdown should contain user role heading")
        assert(markdown.contains("### Assistant"), "Markdown should contain assistant role heading")
        assert(markdown.contains("Hello"), "Markdown should include user message text")
        assert(markdown.contains("Hi there"), "Markdown should include assistant message text")

        let url = try! ChatExport.temporaryMarkdownFileURL(for: session)
        let fileContents = try! String(contentsOf: url, encoding: .utf8)
        assert(fileContents == markdown, "Exported file should match generated markdown")
    }
}
