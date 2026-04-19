# Intrai

A private, local-first multi-session chatbot for iOS 26+ powered by Apple Intelligence.

All conversations stay on-device via SwiftData. The app uses Apple's `FoundationModels` framework to run inference on the Neural Engine with automatic Private Cloud Compute (PCC) fallback — no third-party API keys required.

## Features

- **Multi-session chat** — Create, rename, and delete independent chat threads from a sidebar. Sessions persist across app launches.
- **Memory snapshot system** — A global system prompt and user memory are composed into a snapshot and frozen into each session at creation time. Snapshots can be refreshed per-session with a mandatory reason and confirmation.
- **Streaming AI responses** — Responses stream token-by-token from `SystemLanguageModel.default` with cancellation support.
- **Markdown rendering** — Chat bubbles render inline Markdown via `AttributedString`.
- **Markdown export** — Export any conversation as a `.md` file through the iOS Share Sheet.
- **Secure deletion** — Swipe-to-delete a session and all associated messages are cascade-deleted.
- **Error handling & retry** — Friendly error messages for model unavailability, generation failures, and cancellation. Failed prompts are stored for one-tap retry.

## Requirements

- iOS 26+
- Xcode 26+
- Apple Silicon device (simulator works for UI, on-device required for AI generation)

## Architecture

SwiftUI + SwiftData with a `@MainActor` service layer. No external dependencies.

```
intrai/
├── intraiApp.swift            # App entry, ModelContainer setup
├── ChatSession.swift          # @Model — session identity, snapshot versioning, cascade delete
├── ChatMessage.swift          # @Model — message with role normalization
├── UserMemory.swift           # @Model — singleton global memory
├── SnapshotBuilder.swift      # Composes system prompt + memory facts into snapshot
├── AIContextBuilder.swift     # Builds ordered transcript from session messages
├── IntelligenceService.swift  # Generation lifecycle, cancellation, retry, error mapping
├── ContentView.swift          # Session list sidebar + Memory Settings editor
├── ChatDetailView.swift       # Message timeline, composer, snapshot inspector, export
└── ChatExport.swift           # Markdown serialization + temp file writer
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| `ChatMessage.role` stored as `String` | SwiftData compatibility; `validatedRole` computed property provides type-safe `ChatRole` enum access |
| `ChatResponding` protocol | Abstracts the AI provider for testability; `LocalFirstChatResponder` is the production implementation |
| `#if canImport(FoundationModels)` | Ensures the project compiles on simulators and targets without the framework |
| Snapshot immutable by default | Refresh is an explicit user action requiring a reason string and confirmation dialog |

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
