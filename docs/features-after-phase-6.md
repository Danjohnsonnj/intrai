# Product Improvements After Phase 6 (Excluding Freeze-Fix Work)

This document captures user-facing product improvements made after commit
`84425344a29140fa84d15f8c4ee421838a638744` ("Added logos"), while excluding
freeze-investigation and freeze-mitigation work.

Use this as a reconstruction guide if the original implementation is missing.

---

## Scope and Source

- **Starting point:** `84425344a29140fa84d15f8c4ee421838a638744`
- **Window reviewed:** `8442534..HEAD`
- **Included:** user-facing features, UX improvements, interaction polish
- **Excluded:** freeze fixes, diagnostics, watchdog behavior, docs-only freeze updates

---

## Features Added (Chronological)

## 1) Conversation export switched to copy-to-clipboard

- **Commit:** `ffe26d7`
- **What changed (product):**
  - Replaced a share-sheet export flow with direct "copy conversation as
    Markdown" behavior.
- **User value:**
  - Faster export with fewer taps, predictable output, no dependency on share
    targets.
- **Rebuild notes:**
  - Add a chat-level action (toolbar/menu) named similar to "Copy as Markdown".
  - Serialize the current conversation into plain Markdown text.
  - Write text to `UIPasteboard.general.string`.
  - Show immediate success feedback (toast/banner/inline status) so users know
    the copy succeeded.
- **Acceptance check:**
  - Triggering the export places full conversation Markdown on clipboard.

## 2) Auto-scroll improvements during composition and generation

- **Commit:** `f81c8be`
- **What changed (product):**
  - Chat view now scrolls to the newest content when:
    1) the keyboard gains focus, and
    2) generation begins.
- **User value:**
  - Prevents "stuck above latest message" confusion while composing/responding.
- **Rebuild notes:**
  - Ensure message list is hosted in `ScrollViewReader`.
  - Maintain a stable anchor id at the bottom (or last message id).
  - On composer focus change to active, scroll to bottom with animation.
  - On generation-start state transition, scroll to bottom with animation.
- **Acceptance check:**
  - User taps composer in long chat -> viewport snaps/animates to latest message.
  - Sending a message and entering generation keeps newest area visible.

## 3) Long-press title to rename chat session

- **Commit:** `84687ef`
- **What changed (product):**
  - Added long-press interaction on chat title to rename the session.
  - Added focus restoration after rename flow.
- **User value:**
  - Lightweight in-place naming without navigating to a separate edit screen.
- **Rebuild notes:**
  - Add long-press gesture to title UI.
  - Present rename input (alert/sheet/inline edit).
  - Validate non-empty input; trim whitespace.
  - Persist new name to session model.
  - Restore keyboard/composer focus to prior state after rename completes.
- **Acceptance check:**
  - Long-press title -> rename UI appears -> save persists immediately in list
    and detail views.

## 4) Rich Markdown rendering for assistant messages (historical)

- **Commit:** `1d5aa62`
- **What changed (product):**
  - Assistant messages were rendered with MarkdownUI (rich formatting instead of
    plain text).
- **User value:**
  - Better readability for headings, lists, emphasis, code formatting.
- **Important status:**
  - This was later removed in `9d9c42e` during freeze investigation.
  - Current product state may be plain text rendering.
- **Rebuild notes (if reintroducing):**
  - Add Markdown rendering dependency and wire it to assistant bubble only.
  - Keep user messages plain text unless intentional design change.
  - Preserve text selection/copy behavior.
- **Acceptance check:**
  - Assistant markdown syntax appears with styled output (not raw markdown).

## 5) Reliable composer clear-after-send (including dictation)

- **Commit:** `3436b94`
- **What changed (product):**
  - Message input reliably clears after send, including voice-dictated text.
- **User value:**
  - Removes stale-text confusion and accidental re-send risk.
- **Rebuild notes:**
  - On successful send action, clear bound input state on main thread.
  - Ensure dictation path and typed path share the same clear logic.
  - Guard against races where async send completion could rehydrate old text.
- **Acceptance check:**
  - Typed and dictated messages both leave an empty composer after send.

## 6) Siri/App Intents entrypoint ("Ask Intrai")

- **Commit:** `0c632b7`
- **What changed (product):**
  - Added Siri/Shortcuts integration for launching a chat intent.
  - Added bridging state object to carry pending intent into SwiftUI flow.
- **User value:**
  - Hands-free and shortcuts-based entry into a new chat.
- **Rebuild notes:**
  - Define an `AppIntent` for "Ask Intrai" (or equivalent).
  - Expose shortcut phrase(s) through `AppShortcutsProvider`.
  - Introduce an observable pending-intent bridge singleton.
  - In root view, observe bridge events and route to/newly create chat context.
- **Acceptance check:**
  - "Hey Siri, ask Intrai" (or Shortcut run) opens app and starts intended chat
    flow.

## 7) Per-message markdown copy from bubble long-press

- **Commit:** `e116cec`
- **What changed (product):**
  - Added long-press action on a message bubble to copy that single message as
    Markdown.
- **User value:**
  - Precise reuse of one response without exporting whole conversation.
- **Rebuild notes:**
  - Add context menu or long-press gesture per message row.
  - Convert message object to markdown text payload.
  - Copy payload to pasteboard.
  - Optional: include role prefixing conventions consistently.
- **Acceptance check:**
  - Long-press on any message -> copy action produces only that message in
    markdown format.

## 8) Always-visible monochrome context usage bar

- **Commit:** `88124ca`
- **What changed (product):**
  - Added a persistent context progress bar above composer.
  - Monochrome style adapts to appearance mode (light/dark).
- **User value:**
  - Continuous visibility into context consumption before hitting limits.
- **Rebuild notes:**
  - Compute a normalized ratio (0...1) from transcript/context estimator.
  - Render thin horizontal bar pinned above composer area.
  - Style with black in light mode, white in dark mode.
  - Keep bar visible at all times (not only while generating).
- **Acceptance check:**
  - Bar is always present and updates as conversation grows.

## 9) Better generation status wording ("Thinking" vs "Generating")

- **Commit:** `3aaabc8`
- **What changed (product):**
  - Status copy differentiates pre-first-fragment wait from active generation:
    - before assistant fragment: "Thinking..."
    - while assistant output is arriving/present: "Generating..."
- **User value:**
  - Clearer mental model of what state the assistant is in.
- **Rebuild notes:**
  - Derive state from:
    - generation active flag, and
    - whether latest message is already assistant output.
  - Show phase-appropriate label next to spinner/progress indicator.
- **Acceptance check:**
  - Immediately after send -> "Thinking..."
  - Once assistant output begins/existing assistant tail is present ->
    "Generating..."

---

## Not Included Here (Intentional Exclusions)

The following categories were excluded from this list:

- Freeze mitigation and watchdog changes (`23a9c9b`, `263b5da`, `081a45e`,
  `cd1c068`, `e157ab8`, `9d9c42e`)
- Freeze investigation handoff and diagnostics docs updates (`6028588`,
  `ae45e9d`, `2964f23`, `afff3a7`)
- Non-product maintenance (`fcb1f14`, `069e414`)

---

## Quick Rebuild Priority (If Re-implementing Product Value First)

1. Copy/export UX (`ffe26d7`, `e116cec`)
2. Navigation/composer polish (`f81c8be`, `3436b94`)
3. Session management polish (`84687ef`)
4. Siri/App Intent entrypoint (`0c632b7`)
5. Context visibility (`88124ca`)
6. Generation status clarity (`3aaabc8`)
7. Optional rich markdown rendering (`1d5aa62`, if desired)