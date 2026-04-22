# Freeze Investigation Hand-off (Current)

**Last updated:** 2026-04-22  
**Current diagnostics build label:** 0.2.111  
**Status:** Unresolved at framework level; mitigation and recovery layers are active.

---

## 1. Executive Summary

`intrai` is a local-first, on-device chat app using Apple's `FoundationModels`.
The primary failure mode is a generation wedge where framework calls stop making
forward progress. We cannot fix the framework itself, so current work focuses on:

1. preventing high-risk requests before inference,
2. bounding inference behavior when it does run,
3. recovering automatically when wedges happen,
4. preserving diagnostics for post-mortem analysis.

The codebase has moved beyond earlier 0.2.10x streaming architecture. As of
0.2.111, user-visible responses are generated as a single finalized block
(`respond(to:options:)`) rather than token streaming.

---

## 2. Current User Experience

Typical healthy path:

1. User sends a prompt.
2. App performs pre-flight transcript/context checks.
3. Model returns one complete response block.
4. Assistant message is saved and rendered as Markdown.

Failure-handling path:

- If pre-flight predicts context-hang risk, send is blocked early with a
  context-full message and two recovery actions:
  - `Trim oldest`
  - `Start new chat`
- If generation wedges during/after model invocation, a GCD-driven watchdog
  runs a cancel -> grace -> force-recover pipeline.
- If MainActor is unreachable during force-recovery, the app aborts
  intentionally so iOS can relaunch cleanly; next launch can surface a
  one-time explanatory banner using persisted diagnostics.

---

## 3. Source-of-Truth Files

| File | Responsibility |
|------|----------------|
| `intrai/IntelligenceService.swift` | Send lifecycle, context gate, generation call, watchdog + recovery pipeline, retry governance. |
| `intrai/AIContextBuilder.swift` | Transcript assembly, token/char heuristic, context fill ratio, runtime context-size cache. |
| `intrai/FreezeLogger.swift` | In-memory logging and heartbeat degradation tracking on app side. |
| `intrai/DiskFreezeLogger.swift` | Durable JSONL persistence, direct breadcrumb writes, export helpers, latest abort marker lookup. |
| `intrai/ChatDetailView.swift` | Context risk UI, blocked-context actions, retry/cancel controls. |
| `intrai/ContentView.swift` | Diagnostics version display, startup runtime-limit preload, post-abort banner check. |

---

## 4. Current Architecture (0.2.111)

### 4.1 Generation mode

- **Non-streaming response path:** `LanguageModelSession.respond(to:options:)`
- **No prewarm/session reuse:** fresh `LanguageModelSession` per generation
- **Token cap:** response bounded by `GenerationOptions(maximumResponseTokens:)`

### 4.2 Pre-flight context gate

Before generation, the app builds transcript text and estimates risk using the
synchronous heuristic path in `AIContextBuilder`.

- If transcript is at/above hang threshold, send is blocked with
  `IntelligenceError.contextFullBlocked`.
- The blocked prompt is preserved for guided recovery actions.
- The previous tokenizer-based gate call (`tokenCount(for:)`) is intentionally
  removed from this path because diagnostics indicated that tokenizer access can
  wedge similarly to generation.

### 4.3 Watchdog and recovery pipeline (GCD)

The send watchdog is armed at `send_start`, before potentially hanging work.
It uses GCD timers on a dedicated queue (not Swift cooperative scheduling):

1. **Absolute deadline timer** (current default: 25s).
2. **Proactive wedge timer** (poll heartbeat degradation, threshold currently
   5000 ms).
3. On trigger, run pipeline:
   - cancel target task,
   - wait grace window (currently 1s),
   - schedule MainActor force-recovery,
   - if MainActor hop never runs within abort window (currently 2s),
     persist `force_recovery_unreachable_mainactor` and call `abort()`.

This is intentionally fail-fast once app-level recovery is proven unreachable.

### 4.4 Context-full recovery UX

When blocked by context gate, UI presents:

- **Trim oldest** -> destructive removal of oldest exchanges until estimated
  risk drops below hang threshold, then auto-retry blocked prompt.
- **Start new chat** -> carries blocked prompt into a new session and clears the
  blocked state from the old session.

---

## 5. Diagnostics and Evidence Model

Diagnostics survive force-quit through disk persistence and direct writes.

### 5.1 Primary event families

- Send lifecycle: `send_start`, `generation_started`, `generation_finished`
- Gate/control: `send_blocked_context_full`, `generation_max_tokens`,
  `generation_capped`
- Watchdog: `send_watchdog_armed`, `send_watchdog_disarmed`,
  `generation_timeout_watchdog_triggered`, `generation_early_cancel_wedge_detected`
- Recovery/abort: `generation_grace_expired`, `force_recovered_from_stall`,
  `force_recovery_unreachable_mainactor`

### 5.2 Core interpretation rules

- Presence of `send_watchdog_armed` without a corresponding completion event is
  immediate signal to inspect watchdog-trigger and recovery breadcrumbs.
- Presence of `force_recovery_unreachable_mainactor` means app-level recovery
  could not hop to MainActor and process abort was intentional.
- `DiskFreezeLogger.latestAbortRecoveryEntry()` is the retrieval mechanism used
  at startup to drive post-abort user messaging.

### 5.3 Build-version traceability

Diagnostics build label in `MemorySettingsView` is currently:

```swift
private let diagnosticsBuildVersion = "0.2.111"
```

Increment on each diagnostics-significant build to keep exported logs
attributable to exact behavior.

---

## 6. What Is Already Landed (vs old docs)

Compared with earlier handoff versions, the following are now implemented:

- GCD-based watchdog timers (deadline + proactive wedge path)
- Unified watchdog arming at send start (covers pre-flight + generation)
- Non-streaming generation mode with bounded response length
- Context-full pre-flight gate and dedicated blocked-context UI actions
- Force-recovery + abort fallback with durable breadcrumbing

In other words, earlier recommendations to "switch from detached watchdog loops
to GCD timers" are complete and should not be re-listed as future work.

---

## 7. Remaining Open Work

1. **Threshold tuning from field telemetry (open)**
   - Revisit:
     - `proactiveWedgeThresholdMs`
     - `graceAfterCancelSeconds`
     - `mainActorWedgeAbortSeconds`
   - Objective: reduce user-visible stall time while minimizing false aborts.

2. **Minimal standalone reproducer + Apple escalation (open)**
   - Build a tiny repro app around `FoundationModels` generation wedge behavior.
   - File/update Feedback Assistant report with logs + repro steps.

3. **Fallback watchdog strategy (unbuilt)**
   - Keep pure `pthread` watchdog as a contingency only if current GCD path
     proves insufficient in real telemetry.

4. **Documentation maintenance (open)**
   - Keep this handoff aligned with future architecture changes so stale guidance
     does not re-enter investigation loops.

---

## 8. Known Facts and Constraints

- The issue is consistent with framework/OS-level behavior in iOS 26-era
  `FoundationModels` builds.
- App-level mitigations can reduce impact and improve recoverability but cannot
  guarantee elimination of framework wedges.
- Intentionally aborting on unrecoverable MainActor wedge is a product decision:
  it favors predictable recovery over indefinite frozen UI.

---

## 9. Quick Onboarding Checklist for Next Agent

1. Confirm current constants in `IntelligenceService` match expected watchdog
   tuning values.
2. Confirm diagnostics build label bump if any behavior changed.
3. Reproduce with diagnostics export enabled.
4. Classify run by event sequence (healthy, gated, recovered stall, abort path).
5. If abort path persists at meaningful rate, prioritize Apple repro package.

---

## 10. Suggested Next Experiments (Prioritized)

Previous fix attempts focused exclusively on the generation/watchdog layer.
The experiments below widen the lens to include rendering, dependency health,
and interaction effects that have not yet been isolated.

### 10.1 Isolate MarkdownUI as a freeze contributor

**Why this is high priority.** Assistant messages are rendered via
`Markdown(message.text)` (gonzalezreal/swift-markdown-ui 2.4.1) inside a
`LazyVStack`. This library has multiple open, unfixed performance bugs that
cause MainActor hangs:

- **Issue #310:** A short string with 6-level nested bullets causes a 1-2 s
  severe hang — 100% CPU on the main thread. Confirmed reproducible on main
  branch; still open.
- **Issue #426:** Moderate-length markdown with nested lists freezes the app
  entirely. A maintainer confirmed the cause is "excessive nesting" interacting
  with SwiftUI's `Environment` propagation.
- **Issue #396:** Long code snippets crash (`EXC_BAD_ACCESS`) on iOS.

The on-device model can and does produce nested lists and code blocks. If the
response triggers any of these MarkdownUI pathologies, the MainActor will be
blocked for seconds *after* generation completes. This could:

- Extend the apparent freeze window beyond what the watchdog expects.
- Delay the MainActor hop in the force-recovery pipeline, causing the abort
  timer to fire on what is actually a render hang, not a generation wedge.
- Compound with a borderline-slow generation to push total wall-clock time
  past the 25 s deadline.

**Experiment:** Temporarily replace `Markdown(message.text)` with plain
`Text(message.text)` for assistant bubbles and run the same prompt set that
triggers freezes. If freezes disappear or become reliably recoverable, the
rendering layer is a significant contributor or the sole remaining cause.

### 10.2 Evaluate MarkdownUI replacement

`swift-markdown-ui` is officially in **maintenance mode** (announced December
2025). The author's successor library,
[Textual](https://github.com/gonzalezreal/textual) (0.3.1, January 2026), was
designed from scratch to solve the nesting and performance problems documented
above. Alternatively, SwiftUI's built-in `Text` initialized with
`AttributedString(markdown:)` avoids the third-party view hierarchy entirely
and parses on Foundation's `cmark` without the deep `Environment` nesting that
causes MarkdownUI's hangs.

**Recommendation (if 10.1 confirms impact):**

1. First try `Text(AttributedString(markdown: message.text))` — zero new
   dependencies, native SwiftUI rendering pipeline, no nesting pathology.
   Trade-off: less theming control than MarkdownUI, no image/attachment
   support.
2. If richer rendering is needed, evaluate Textual. It uses `InlineText` /
   `StructuredText` views that preserve SwiftUI's `Text` rendering pipeline
   rather than building a parallel view tree.

### 10.3 Add render-timing diagnostics

Currently, diagnostics cover the send-through-generation window but not the
post-generation rendering pass. Adding a timestamp pair around the SwiftData
save + view update would distinguish "generation wedge" from "render hang" in
exported logs. Suggested events:

- `response_saved` — emitted after `modelContext.save()` for the assistant
  message.
- `response_rendered` — emitted from `.onAppear` of the newly inserted
  `ChatMessageBubble`.

The delta between these two events is the MainActor time consumed by SwiftUI
layout + MarkdownUI parsing. If this delta is consistently > 1 s, it confirms
the rendering layer as a bottleneck independent of the generation path.

### 10.4 Controlled stimulus testing for generation wedges

Design a prompt set that varies along the two axes most likely to trigger
issues:

| Axis | Low risk | High risk |
|------|----------|-----------|
| **Transcript length** | 1-turn, < 500 tokens | Multi-turn, near hang threshold |
| **Response structure** | Plain prose, no nesting | Nested lists (4+ levels), code blocks |

Run each combination multiple times with diagnostics export enabled. Classify
each run by event sequence (healthy / gated / recovered stall / abort). This
produces an empirical matrix that separates generation-layer instability from
rendering-layer instability.

### 10.5 Tune watchdog thresholds from field data

With rendering impact quantified (10.1-10.3), revisit:

- `proactiveWedgeThresholdMs` — may need to increase if MarkdownUI rendering
  legitimately occupies 1-2 s of MainActor time post-generation.
- `mainActorWedgeAbortSeconds` — should be set above the worst observed
  render time to avoid false aborts.
- `generationDeadlineSeconds` — can potentially be tightened once rendering
  cost is moved off the critical path or reduced.

### 10.6 Apple Feedback Assistant escalation

Build a minimal standalone app:

- Single-view, no MarkdownUI, no SwiftData.
- Calls `LanguageModelSession.respond(to:options:)` with a transcript near
  the 4096-token context window.
- Logs wall-clock time, thread state, and whether the call returns or hangs.

File with Apple alongside device logs and diagnostics exports from the main
app. The minimal repro eliminates all app-specific variables and gives Apple
engineers the clearest signal.

### 10.7 Evaluate streaming re-enablement (longer term)

The switch from `streamResponse(to:)` to `respond(to:options:)` was a
deliberate stability decision. However, the non-streaming path means the user
sees nothing until the full response is ready, which can feel like a freeze
even when generation is healthy. If Apple addresses the framework-level wedge,
re-enabling streaming with the current GCD watchdog infrastructure would
improve perceived responsiveness. Gate this on:

- Confirmed fix in a future iOS 26.x / FoundationModels update.
- Or stable telemetry showing wedge rate below an acceptable threshold with
  the current mitigations.

---

**Guiding principle:** The most impactful next step is likely 10.1 — it is
fast, low-risk, and tests a hypothesis that has never been isolated despite
multiple rounds of generation-layer debugging. If MarkdownUI rendering is
compounding or masking the true recovery behavior, all watchdog tuning done
without that knowledge is built on incomplete data.
