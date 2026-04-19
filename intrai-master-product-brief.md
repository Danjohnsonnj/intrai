Act as a Senior iOS Engineer. We are building *Intrai*, a private, local-first chatbot for iOS 26 and later.

This is Master Product and Technical Brief document. 

------------------------------
# 📑 Project Master Brief: "Intrai"

*Project Goal*: A private, multi-session chatbot using Apple Intelligence (Hybrid Local/Cloud).
*Target Platform*: iOS 26+ (Apple Silicon).
*License Tier*: Free Apple Developer Account (Personal Team).

------------------------------
## 1. Product Requirements

* Hybrid AI Orchestration: Use FoundationModels SDK to scale between NPU (on-device) and Private Cloud Compute (PCC) automatically.
* Multi-Chat Persistence: Concurrent, independent chat threads saved via SwiftData.
* The "Memory Snapshot": A global user-editable "Memory" and "System Prompt" are captured at the moment a chat is created and "baked into" that session's history.
* Markdown Portability: Chat bubbles must render Markdown; the entire chat must be exportable as a .md file.
* Local Privacy: All data is stored locally. Deleting a chat must purge all associated messages.

------------------------------
## 2. User Stories

The following user stories will be true when the project is completed. They are examples of the Intrai app's behavior, but not exhaustive or comprehensive.

   1. Concurrent Sessions: "I want separate chats for 'Work' and 'Personal' that I can switch between via a sidebar."
   2. Persistent Identity: "The AI should know I am a 'Swift Developer' because it's in my global Memory, even if I don't mention it in the current chat."
   3. Markdown Export: "I want to share my full conversation as a formatted document via the iOS Share Sheet."
   4. Secure Deletion: "I want to swipe-to-delete a chat and know that its data is gone."

------------------------------
## 3. Technical Implementation Plan

### Phase 1: Data Layer (SwiftData)

*Agent Instruction*: Implement these schemas. `ChatSession` holds the "snapshot" of the system's state at creation.

```swift
import SwiftDataimport Foundation
@Modelclass ChatSession {
    var id: UUID = UUID()
    var title: String = "New Chat"
    var createdAt: Date = Date()
    var systemPromptSnapshot: String // Combined Global Prompt + Memory at birth
    
    @Relationship(deleteRule: .cascade) 
    var messages: [ChatMessage] = []
    
    init(title: String = "New Chat", snapshot: String) {
        self.title = title
        self.systemPromptSnapshot = snapshot
    }
}
@Modelclass ChatMessage {
    var text: String
    var role: String // "user" or "assistant"
    var timestamp: Date = Date()
    
    init(text: String, role: String) {
        self.text = text
        self.role = role
    }
}
```

### Phase 2: AI Service (The Hybrid Engine)

*Agent Instruction*: Use the `FoundationModels` framework. Construct the prompt by prepending the `systemPromptSnapshot` to the chat history.

```swift
import FoundationModels 
@Observableclass IntelligenceService {
    func streamResponse(for session: ChatSession) async throws {
        let model = try await LanguageModel.load(identifier: .large)
        
        // Construct Context: Snapshot + History
        var context = "System Instructions: \(session.systemPromptSnapshot)\n\n"
        for msg in session.messages {
            context += "\(msg.role): \(msg.text)\n"
        }
        
        let assistantMsg = ChatMessage(text: "", role: "assistant")
        session.messages.append(assistantMsg)
        
        // Execute hybrid generation (On-device or PCC)
        let stream = model.generateText(for: context)
        for try await fragment in stream {
            assistantMsg.text += fragment
        }
    }
}
```

### Phase 3: UI Architecture (SwiftUI)

*Agent Instruction*: Use `NavigationSplitView` for a professional sidebar experience. Implement Markdown rendering for messages.

```swift
// Export Logic to be used in ShareSheetextension ChatSession {
    func toMarkdown() -> String {
        let header = "# \(title)\n*Created: \(createdAt.formatted())*\n\n"
        let body = messages.map { "**\($0.role.capitalized):** \($0.text)" }.joined(separator: "\n\n")
        return header + body
    }
}
```

The initial task: Initialize the project structure and create the `SwiftData` models as defined in our architecture. Use the "Intrai" naming convention throughout. 
