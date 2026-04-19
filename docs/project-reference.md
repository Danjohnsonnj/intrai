# Intrai — Project Reference

## Overview

Intrai is a **private, local-first multi-session chatbot** for iOS 26+ that uses Apple's `FoundationModels` framework for on-device inference with automatic Private Cloud Compute (PCC) fallback. All data is stored locally via SwiftData — no accounts, no external API keys, no telemetry.

Users maintain multiple independent chat threads. Each thread has a "baked-in" snapshot of a global system prompt and user memory facts, captured at session creation time and immutable by default. This ensures the AI's persona and context remain stable across a session's lifetime.

---

## Current Status

All six MVP phases are complete and committed.

| Phase | Scope | Status |
|-------|-------|--------|
| 0 | Baseline & guardrails | ✅ Complete |
| 1 | Domain & persistence hardening | ✅ Complete |
| 2 | AI service vertical slice | ✅ Complete |
| 3 | Chat UI core | ✅ Complete |
| 4 | Memory & prompt management UX | ✅ Complete |
| 5 | Markdown export & sharing | ✅ Complete |
| 6 | Error handling, cancellation & stabilization | ✅ Complete |

---

## Functional Capabilities

### Multi-Session Chat
- Create, rename (swipe-left), and delete (swipe-right) sessions via a `NavigationSplitView` sidebar.
- Sessions are sorted reverse-chronologically.
- Deleting a session cascade-deletes all associated messages.

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
- Chat bubbles render inline Markdown via `AttributedString(markdown:)`.
- Text is selectable.

### Markdown Export
- `ChatExport` serializes a session to a structured `.md` file (title, date, conversation with role headings).
- The file is written to the system temp directory and shared via `UIActivityViewController`.

### Error Handling & Retry
- Typed `IntelligenceError` enum: `.emptyPrompt`, `.unavailableModel`, `.generationCancelled`.
- General errors are surfaced via `error.localizedDescription`.
- Failed prompts are stored per-session for one-tap retry.
- Cancellation removes the in-progress assistant message cleanly.

---

## Technical Design

### Architecture Pattern
SwiftUI + SwiftData + a `@MainActor` service layer. Views interact directly with an `@ObservedObject` `IntelligenceService` and the SwiftData `ModelContext`. No MVVM wrapper layer.

### Source Files

| File | Role |
|------|------|
| `intraiApp.swift` | App entry point; configures `ModelContainer` with all three model types |
| `ChatSession.swift` | `@Model` — session identity, snapshot versioning, cascade delete relationship |
| `ChatMessage.swift` | `@Model` — message content, role as `String` with `ChatRole` enum validation |
| `UserMemory.swift` | `@Model` — singleton global memory; `fetch(from:)` load-or-create pattern |
| `SnapshotBuilder.swift` | Pure function — composes system prompt + memory facts into a snapshot string |
| `AIContextBuilder.swift` | Pure function — builds an ordered role-prefixed transcript from session messages |
| `IntelligenceService.swift` | `@MainActor ObservableObject` — generation lifecycle, task tracking, cancellation, retry, error mapping |
| `ContentView.swift` | Session list sidebar + `MemorySettingsView` (system prompt & facts editor) |
| `ChatDetailView.swift` | Message timeline, composer, cancel button, snapshot inspector, markdown export |
| `ChatExport.swift` | Markdown serialization + sanitized temp file writer |

### Data Models

**`ChatSession`**
```swift
var id: UUID
var title: String
var createdAt: Date
var systemPromptSnapshot: String     // Frozen at creation
var snapshotVersion: Int
var lastSnapshotRefreshAt: Date?
var snapshotRefreshReason: String?
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
| Per-session refresh requires a reason string | Forces intentionality; reason is persisted for auditability |
| `UserMemory` singleton via `fetch(from:)` | Avoids duplicating global state; safe to call from any view with a `ModelContext` |
| `@MainActor` on `IntelligenceService` | All published state mutations happen on the main actor; no manual `DispatchQueue.main` calls needed |
| `defer` for generation state cleanup | Guarantees `generatingSessionIDs` and `activeTasksBySessionID` are cleaned up even if the task throws or is cancelled |

---

## Out of Scope (MVP Exclusions)

Per the product brief, the following are explicitly deferred:

- iCloud sync
- Advanced prompt templates
- Telemetry / analytics
- Rich attachments (images, files)
- Cloud routing configuration UI (PCC routing is automatic and Apple-managed)
- Formal XCTest target (executable validation snippets exist per phase)
