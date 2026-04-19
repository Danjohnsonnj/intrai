## Plan: Local vs Cloud Indicator (Technical Improvement #1)

**The key constraint:** The `FoundationModels` framework does **not** expose which compute location (NPU vs PCC) was used on the `Response` object. Execution routing is handled transparently by the OS. The `Response<Content>` struct only has `.content`, `.rawContent`, and `.transcriptEntries`. There is no `.computeUnit` or equivalent public API.

This means the feature requires a **best-effort inference strategy**, stored as metadata on `ChatMessage`, and displayed alongside the timestamp.

---

**Steps**

### Phase A — Model Changes

1. Add `computeLocation: String?` to `ChatMessage` (SwiftData `@Model`). Values: `"local"`, `"cloud"`, or `nil` (unknown/simulator). Use `String` for SwiftData compatibility following the same `role` pattern already in the codebase.
2. Add a `ComputeLocation` enum (`case local, cloud, unknown`) with `rawValue: String` and a display icon property (`"📱"` / `"☁️"` / `""`).
3. Add `validatedComputeLocation: ComputeLocation` computed property on `ChatMessage` (mirrors the `validatedRole` pattern).

### Phase B — Responder Protocol Changes _(depends on Phase A)_

4. Update the `ChatResponding` protocol to return a `StreamResult` struct containing `stream: AsyncThrowingStream<String, Error>` and `computeLocation: ComputeLocation`. This avoids repeating the metadata on every fragment and keeps the stream element type simple.

5. Update `LocalFirstChatResponder.streamResponse(...)` to return `StreamResult`. Inference logic:
   - In the `#if canImport(FoundationModels)` path, after `LanguageModelSession` responds, inspect `response.transcriptEntries` for any asset IDs or cloud-indicating metadata. If detectable → `.cloud`; else → `.local`.
   - In the `#else` path (simulator/no FoundationModels) → `.unknown`.
   - _If the `transcriptEntries` heuristic is unreliable after testing_: default to `.local` when `SystemLanguageModel.default.availability == .available` (best-effort assumption that available = ran locally), acknowledging this is an approximation.

6. Update all mock responders in validation files (`DelayedMockResponder`, `FailingMockResponder`) to return `StreamResult` with `.unknown`.

### Phase C — Service Layer _(depends on Phase B)_

7. Update `IntelligenceService.send(...)` to consume the new `StreamResult` shape. After streaming completes successfully, write the resolved `computeLocation.rawValue` to `assistantMessage.computeLocation`.
8. Cancel and error paths: leave `computeLocation` as `nil` (message is deleted on cancel, or never set on error — both cases already remove the assistant placeholder).

### Phase D — UI _(depends on Phase A)_

9. Update `ChatMessageBubble` to display the compute location icon to the **right of the timestamp**, at `.caption2` size matching the existing timestamp font. Only shown for assistant messages where `computeLocation != nil` / `!= .unknown`.

   Current timestamp line:

   ```swift
   Text(message.timestamp, format: .dateTime.hour().minute())
       .font(.caption2)
       .foregroundStyle(.secondary)
   ```

   Becomes an `HStack` of timestamp + icon label.

---

**Relevant files**

- `intrai/ChatMessage.swift` — add `computeLocation: String?` stored property + `ComputeLocation` enum + `validatedComputeLocation`
- `intrai/IntelligenceService.swift` — update `ChatResponding` protocol, `LocalFirstChatResponder`, and `send(...)` to carry and persist compute location
- `intrai/ChatDetailView.swift` — update `ChatMessageBubble` to show icon alongside timestamp
- `intrai/Phase6Validation.swift` — update mock responders to conform to new protocol shape

**Verification**

1. Build clean: `xcodebuild -project intrai.xcodeproj -scheme intrai -destination 'platform=iOS Simulator,name=iPhone 17' build`
2. Simulator run: send a message → assistant bubble shows no icon (`.unknown` on simulator, no FoundationModels)
3. Device run (if available): send a message → bubble shows 📱 or ☁️ depending on inferred location
4. Cancel mid-generation: no icon should appear (message is deleted, no stale state)

**Decisions**

- Framework does not expose compute location directly — best-effort inference from `transcriptEntries` with a fallback assumption
- `nil`/`.unknown` hides the icon rather than showing a "?" — avoids surfacing uncertainty to users
- Compute location only shown on assistant messages, never user messages

**Further Considerations**

1. **PCC detection reliability:** The `transcriptEntries` heuristic is unproven — needs testing on a real device with Apple Intelligence. If it proves unreliable, the honest fallback is to always show 📱 when on-device model is available (may be inaccurate for PCC calls). Worth flagging after first device test.
2. **Stream protocol shape change:** Changing `ChatResponding` is a breaking change to the protocol. Since the mock responders are in validation-only files (not a test target), this is low-risk but should be done atomically.
