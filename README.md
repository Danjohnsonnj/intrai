# Intrai

A private, local-first multi-session chatbot for iOS 26+ powered by Apple Intelligence.

All conversations stay on-device via SwiftData. The app uses Apple's `FoundationModels` framework to run inference on the Neural Engine with automatic Private Cloud Compute (PCC) fallback — no third-party API keys required.

## Features

- **Multi-session chat** — Create, rename, and delete independent chat threads from a sidebar. Sessions persist across app launches.
- **Auto-naming** — New chats are automatically named after the first exchange, prefixed with ✦. Long-press the chat title at any time to rename.
- **Memory snapshot system** — A global system prompt and user memory are composed into a snapshot and frozen into each session at creation time. Snapshots can be refreshed per-session with a confirmation dialog.
- **AI responses** — Complete responses are returned as a single block from `SystemLanguageModel.default` (strictly on-device; PCC is not used) with cancellation support. Generation is bounded by `GenerationOptions(maximumResponseTokens:)` to prevent runaway loops. A unified send watchdog arms at `send_start` and covers the entire pre-flight + generation window: an absolute 25 s deadline plus a proactive wedge detector that cancels within ~5–7 s when the main thread stops running. When the framework wedges the main actor past recovery, the app self-terminates so iOS can cleanly restart it; the next launch surfaces a one-time banner explaining what happened. The pre-flight context gate uses the synchronous char/token heuristic only — the real-tokenizer (`tokenCount(for:)`) call was removed in 0.2.111 after diagnostics showed it could wedge the same way `respond(to:)` can. The SDK's own `exceededContextWindowSize` error is still routed into the Trim / Start-new-chat UI path if the heuristic ever under-counts. Token-by-token streaming remains disabled while framework stability is investigated — see `docs/freeze-investigation-handoff.md`.
- **Plain-text rendering** — Assistant responses are displayed as untransformed `Text` (selectable/copyable) while the freeze investigation rules out `swift-markdown-ui` as a compounding cause — see `docs/freeze-investigation-handoff.md` §10.1. Rich Markdown rendering may return once the root cause is confirmed. User messages are also plain text.
- **Markdown export** — Copy any conversation as plain-text Markdown from the chat menu, or long-press any message bubble to copy just that message as Markdown. The raw model output is already Markdown-formatted, so export fidelity is unaffected by the in-app rendering change.
- **Context usage progress bar** — A thin, always-visible bar above the composer estimates transcript context load. It fills left-to-right as conversations grow and uses monochrome styling by appearance mode (black in light mode, white in dark mode).
- **Siri integration** — Say "Hey Siri, ask Intrai" to trigger a new chat via App Intents. Also runnable from the Shortcuts app.
- **Secure deletion** — Swipe-to-delete a session and all associated messages are cascade-deleted.
- **Error handling & retry** — Friendly error messages for model unavailability, generation failures, and cancellation. Failed prompts are stored for one-tap retry.

## Requirements

- iOS 26+
- Xcode 26+
- Apple Silicon device (simulator works for UI, on-device required for AI generation)

## Architecture

SwiftUI + SwiftData with a `@MainActor` service layer. No third-party dependencies as of 0.2.112 (`swift-markdown-ui` was removed to isolate a suspected UI-hang contributor — see `docs/freeze-investigation-handoff.md` §10.1).

```
intrai/
├── intraiApp.swift            # App entry, ModelContainer setup
├── ChatSession.swift          # @Model — session identity, snapshot versioning, cascade delete
├── ChatMessage.swift          # @Model — message with role normalization
├── UserMemory.swift           # @Model — singleton global memory
├── SnapshotBuilder.swift      # Composes system prompt + memory facts into snapshot
├── AIContextBuilder.swift     # Builds ordered transcript from session messages
├── IntelligenceService.swift  # Generation lifecycle, cancellation, retry, auto-naming, context progress state
├── PendingIntentStore.swift   # @Observable singleton — bridges App Intent → ContentView
├── SiriIntents.swift          # AskIntraiIntent + IntraiShortcuts (AppShortcutsProvider)
├── ContentView.swift          # Session list sidebar, Memory Settings, intent handler
├── ChatDetailView.swift       # Message timeline, composer, context progress bar, long-press rename, bubble copy menu, export menu
└── ChatExport.swift           # Session and per-message markdown serialization
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| `ChatMessage.role` stored as `String` | SwiftData compatibility; `validatedRole` computed property provides type-safe `ChatRole` enum access |
| `ChatResponding` protocol | Abstracts the AI provider for testability; `LocalFirstChatResponder` is the production implementation |
| `#if canImport(FoundationModels)` | Ensures the project compiles on simulators and targets without the framework |
| Snapshot immutable by default | Refresh is an explicit user action requiring confirmation |
| Plain `Text` for assistant bubbles (0.2.112) | MarkdownUI removed to rule it out as a compounding freeze cause; raw model output is displayed verbatim with `.textSelection(.enabled)` |
| `PendingIntentStore` singleton | Decouples App Intent execution (outside SwiftUI) from view observation without requiring Environment injection |

## Building

Open `intrai.xcodeproj` in Xcode 26 and build for an iOS 26 device or simulator.

```bash
xcodebuild -project intrai.xcodeproj \
  -scheme intrai \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

## Documentation

- [Project Reference](docs/project-reference.md) — full overview, current status, functional capabilities, technical design, and key decisions

## License

Private project. All rights reserved.
