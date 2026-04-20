# Intrai — Project Reference

## Overview

Intrai is a **private, local-first multi-session chatbot** for iOS 26+ that uses Apple's `FoundationModels` framework for on-device inference with automatic Private Cloud Compute (PCC) fallback. All data is stored locally via SwiftData — no accounts, no external API keys, no telemetry.

Users maintain multiple independent chat threads. Each thread has a "baked-in" snapshot of a global system prompt and user memory facts, captured at session creation time and immutable by default. This ensures the AI's persona and context remain stable across a session's lifetime.

---

## Current Status

All six MVP phases are complete and committed. Post-MVP improvements have also been shipped.

| Phase | Scope | Status |
|-------|-------|--------|
| 0 | Baseline & guardrails | ✅ Complete |
| 1 | Domain & persistence hardening | ✅ Complete |
| 2 | AI service vertical slice | ✅ Complete |
| 3 | Chat UI core | ✅ Complete |
| 4 | Memory & prompt management UX | ✅ Complete |
| 5 | Markdown export & sharing | ✅ Complete |
| 6 | Error handling, cancellation & stabilization | ✅ Complete |
| Post-MVP | Auto-naming, rename, MarkdownUI, clipboard export, Siri, input clear fix | ✅ Complete |

---

## Functional Capabilities

### Multi-Session Chat
- Create, rename (swipe-left or long-press title in chat view), and delete (swipe-right) sessions via a `NavigationSplitView` sidebar.
- Sessions are sorted reverse-chronologically.
- Deleting a session cascade-deletes all associated messages.

### Auto-Naming
- After the first user message and assistant response, `IntelligenceService.autoNameIfNeeded()` generates a concise title using a separate `LanguageModelSession`.
- The title is prefixed with `✦ `. Fallback (on model error) is `"✦ " + first 5 words of the user message`.
- Guard: only fires when `session.title == "New Chat" && session.messages.count == 2`.

### In-Chat Rename
- Long-pressing the `.principal` toolbar title in `ChatDetailView` presents a rename alert pre-filled with the current title.
- On save, `session.title` is updated directly and `modelContext.save()` is called.
- If the keyboard was focused before the rename, focus is restored after the alert dismisses.

### Streaming AI Responses
- `IntelligenceService` streams responses from `SystemLanguageModel.default` via `LanguageModelSession`.
- Responses stream token-by-token; progress is visible in the UI.
- Generation can be cancelled mid-stream from the Cancel button or by navigating away.
- Graceful fallback via `#if canImport(FoundationModels)` for simulator builds.

### Memory Snapshot System
- A global **System Prompt** and **User Memory facts** are edited in Memory Settings.
- `SnapshotBuilder` composes them into a single snapshot string at session creation.
- The snapshot is frozen into the session and used as the AI's `LanguageModelSession` instructions.
- Per-session refresh is an explicit user action: requires a non-empty reason, confirmed via a dialog.
- Refresh history tracked: `snapshotVersion`, `lastSnapshotRefreshAt`, `snapshotRefreshReason`.

### Markdown Rendering
- Assistant message bubbles render full block Markdown via [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) 2.4.1 (`MarkdownUI` product, SPM).
- Theme: `.gitHub` with `.primary` foreground and neutral code-block background for readability on coloured bubbles in light and dark mode.
- User messages remain plain `Text` (user input is never Markdown).
- Normal text selection is intentionally disabled on bubbles so long-press consistently opens the copy menu.

### Markdown Export
- `ChatExport.markdown(for:)` serializes a session to a structured Markdown string (title, date, messages with role headings).
- Tapping "Copy as Markdown" in the chat action menu writes the string to `UIPasteboard.general.string`. No file is created; no Share Sheet is shown.
- Long-pressing a user or assistant message bubble opens a native context menu with "Copy as Markdown" to copy only that message.
- Per-message copy uses `ChatExport.markdown(for: message)` and writes to `UIPasteboard.general.string`.

### Siri / App Intents
- `AskIntraiIntent` (`AppIntent`) is registered with `openAppWhenRun = true`.
- Trigger phrase: "Hey Siri, ask Intrai" — Siri follows up with "What would you like to ask Intrai?" for free-form input (Apple's `AppShortcutsProvider` only supports `AppEntity`/`AppEnum` in phrase interpolation, not raw `String`).
- `IntraiShortcuts` (`AppShortcutsProvider`) registers the intent in Settings › Siri & Search and the Shortcuts app automatically — no user setup required.
- `PendingIntentStore` is an `@Observable` singleton that holds the incoming question. `ContentView` observes it via `.onAppear` (cold-launch) and `.onChange` (foregrounded), then calls `addSession()` + `intelligenceService.send()`.

### Error Handling & Retry
- Typed `IntelligenceError` enum: `.emptyPrompt`, `.unavailableModel`, `.generationCancelled`.
- General errors are surfaced via `error.localizedDescription`.
- Failed prompts are stored per-session for one-tap retry.
- Cancellation removes the in-progress assistant message cleanly.

---

## Technical Design

### Architecture Pattern
SwiftUI + SwiftData + a `@MainActor` service layer. Views interact directly with an `@ObservedObject` `IntelligenceService` and the SwiftData `ModelContext`. No MVVM wrapper layer.

One external dependency: [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) 2.4.1, added via SPM (`MarkdownUI` product, iOS 15+ compatible).

### Source Files

| File | Role |
|------|------|
| `intraiApp.swift` | App entry point; configures `ModelContainer` with all three model types |
| `ChatSession.swift` | `@Model` — session identity, snapshot versioning, cascade delete relationship |
| `ChatMessage.swift` | `@Model` — message content, role as `String` with `ChatRole` enum validation |
| `UserMemory.swift` | `@Model` — singleton global memory; `fetch(from:)` load-or-create pattern |
| `SnapshotBuilder.swift` | Pure function — composes system prompt + memory facts into a snapshot string |
| `AIContextBuilder.swift` | Pure function — builds an ordered role-prefixed transcript from session messages |
| `IntelligenceService.swift` | `@MainActor ObservableObject` — generation lifecycle, task tracking, cancellation, retry, auto-naming |
| `PendingIntentStore.swift` | `@Observable` singleton — holds incoming Siri/App Intent question; observed by `ContentView` |
| `SiriIntents.swift` | `AskIntraiIntent` + `IntraiShortcuts` (`AppShortcutsProvider`) |
| `ContentView.swift` | Session list sidebar, `MemorySettingsView`, App Intent handler |
| `ChatDetailView.swift` | Message timeline, composer, long-press rename, bubble context menu (copy markdown), action menu (snapshot/full copy) |
| `ChatExport.swift` | Session and per-message markdown serialization |

### Data Models

**`ChatSession`**
```swift
var id: UUID
var title: String
var createdAt: Date
var systemPromptSnapshot: String     // Frozen at creation
var snapshotVersion: Int
var lastSnapshotRefreshAt: Date?
var snapshotRefreshReason: String?   // Pending removal
@Relationship(deleteRule: .cascade)
var messages: [ChatMessage]
```

**`ChatMessage`**
```swift
var id: UUID
var text: String
var role: String                     // "user" | "assistant"
var timestamp: Date
var validatedRole: ChatRole          // Computed; falls back to .user
```

**`UserMemory`** (singleton)
```swift
var facts: String
var systemPrompt: String
var updatedAt: Date
```

### AI Service Design

`IntelligenceService` is the single owner of all generation state:

```
generatingSessionIDs:       Set<UUID>           — which sessions have active generation
errorsBySessionID:          [UUID: String]       — last error per session
lastFailedPromptBySessionID:[UUID: String]       — enables retry
activeTasksBySessionID:     [UUID: Task<Void, Never>] — cancellation handles
```

The `ChatResponding` protocol abstracts the AI provider:
```swift
protocol ChatResponding {
    func streamResponse(systemPromptSnapshot: String, transcript: String)
        -> AsyncThrowingStream<String, Error>
}
```

`LocalFirstChatResponder` is the production implementation. Mock responders (`DelayedMockResponder`, `FailingMockResponder`) are used in validation files.

### Context Assembly Pipeline

```
UserMemory.systemPrompt + UserMemory.facts
         ↓  SnapshotBuilder.compose()
    ChatSession.systemPromptSnapshot          ← frozen at session creation
         ↓  used as LanguageModelSession(instructions:)
    AIContextBuilder.transcript(for:)         ← ordered role-prefixed message history
         ↓
    LocalFirstChatResponder.streamResponse()
```

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| `ChatMessage.role` stored as `String` | SwiftData requires primitive-compatible storage; `validatedRole` and `normalizeRole` provide type safety at the boundary |
| `ChatResponding` protocol | Decouples the AI provider from generation lifecycle logic; enables mock-based validation without `FoundationModels` |
| `#if canImport(FoundationModels)` guards | Project compiles and runs on simulators and CI targets that don't have the framework |
| Snapshot is immutable by default | Preserves the "persistent identity" contract — the AI you created the session with is the AI it uses throughout |
| Per-session refresh requires confirmation | Forces intentionality; refresh history tracked via `snapshotVersion` and `lastSnapshotRefreshAt` |
| `UserMemory` singleton via `fetch(from:)` | Avoids duplicating global state; safe to call from any view with a `ModelContext` |
| `@MainActor` on `IntelligenceService` | All published state mutations happen on the main actor; no manual `DispatchQueue.main` calls needed |
| `defer` for generation state cleanup | Guarantees `generatingSessionIDs` and `activeTasksBySessionID` are cleaned up even if the task throws or is cancelled |
| Generation stamp UUIDs | Prevents a defer race when rapid successive messages are sent; only the current generation's stamp matches |
| MarkdownUI for assistant bubbles | Full block-level rendering (code blocks, headings, lists) is not achievable with `AttributedString` alone |
| `PendingIntentStore` `@Observable` singleton | App Intents execute outside SwiftUI's environment; a singleton observable bridges intent → view without requiring Environment injection or NotificationCenter |

---

## Out of Scope (MVP Exclusions)

Per the product brief, the following are explicitly deferred:

- iCloud sync
- Advanced prompt templates
- Telemetry / analytics
- Rich attachments (images, files)
- Cloud routing configuration UI (PCC routing is automatic and Apple-managed)
- Formal XCTest target (executable validation snippets exist per phase)

## Known Pending Items

- `snapshotRefreshReason: String?` — field still present in `ChatSession` model and `SessionSnapshotView`; scheduled for removal (SwiftData lightweight migration handles field removal automatically)
