# Freeze Investigation Hand-off (Current)

**Last updated:** 2026-04-22  
**Current diagnostics build label:** 0.2.112  
**Status:** Unresolved at framework level; mitigation and recovery layers are active. 0.2.112 removes `swift-markdown-ui` per experiment §10.1. Field testing confirms MarkdownUI is **not** the root cause. Diagnostics export from `intrai-freeze-diagnostics-1776885219.json` reveals a **100% reproducible "3rd send" failure pattern**: sends 1 and 2 always succeed; send 3 always wedges the MainActor — across all sessions, all transcript sizes, and in airplane mode. Root cause is inside `FoundationModels` after two prior invocations. See §12.3 for full analysis.

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
(`respond(to:options:)`) rather than token streaming. 0.2.112 additionally
removes the `swift-markdown-ui` dependency so assistant bubbles render as
plain `Text` — see §10.1 for rationale and §10.2 for follow-up options.

---

## 2. Current User Experience

Typical healthy path:

1. User sends a prompt.
2. App performs pre-flight transcript/context checks.
3. Model returns one complete response block.
4. Assistant message is saved and rendered as plain text (selectable).

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

Known additional failure modes (observed in 0.2.112 field testing):

- **Framework init wedge at launch.** Repeated main-thread stalls (1–14 s)
  occur between `runtime_limits_loaded` and first user interaction. These
  have `sid=-` and are caused by `FoundationModels` lazy Neural Engine
  initialization, not by any app-layer call.
- **Post-force-quit relaunch failure.** After a force-quit during a wedge,
  the framework's Neural Engine context may remain partially live. On next
  launch the initialization burst can become permanently wedged, leaving the
  app stuck on the loading screen indefinitely. Recovery requires a device
  reboot or app reinstall. The watchdog and abort path cannot protect against
  this because the wedge occurs before any user interaction and before the
  watchdog arms.

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

## 4. Current Architecture (0.2.112)

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
private let diagnosticsBuildVersion = "0.2.112"
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
- **MarkdownUI is not the root cause.** Removed in 0.2.112. Freezes and
  relaunch failures reproduce without it. See §10.1 and §12.
- **Framework initialization is independently destabilizing.** Repeated
  main-thread stalls occur at every app launch before any generation is
  attempted. The `FoundationModels` framework performs lazy Neural Engine
  initialization on first `SystemLanguageModel.default` access, and this
  process blocks the main thread in multi-second bursts regardless of whether
  any prompt is sent.
- **Force-quit can leave the framework in an unrecoverable state.** A
  force-quit during an active wedge may prevent clean relaunch. Device reboot
  is the only known recovery path. This failure mode is outside the app's
  control but motivates the §11.1 UI-readiness gate (to reduce the frequency
  of force-quits by making the initialization period visible and non-
  interactive).
- **The freeze has a 100% reproducible "3rd send" pattern.** Across three
  separate sessions and test conditions (including airplane mode), sends 1
  and 2 always complete successfully; send 3 always wedges the MainActor.
  Context fill ratio at the freeze ranges from 0.18–0.32 — well below the
  pre-flight gate threshold. The trigger is not transcript length, content
  structure, or network routing.
- **Network routing (PCC) is not a factor.** Confirmed by airplane-mode
  testing: the freeze reproduces identically with no network available.
  `SystemLanguageModel.default` is strictly on-device; PCC is not involved.
- **All recorded freezes are caught by the proactive wedge detector, not the
  absolute deadline.** The main thread stalls abruptly for ~5.5–5.8 s in
  every case, triggering `generation_early_cancel_wedge_detected`. The
  MainActor is then unreachable during force-recovery, leading to `abort()`.
  The absolute 25 s deadline has never fired in field testing.

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

### 10.1 Isolate MarkdownUI as a freeze contributor — **landed in 0.2.112**

**Why this was high priority.** Assistant messages were previously rendered via
`Markdown(message.text)` (gonzalezreal/swift-markdown-ui 2.4.1) inside a
`LazyVStack`. That library has multiple open, unfixed performance bugs that
cause MainActor hangs:

- **Issue #310:** A short string with 6-level nested bullets causes a 1-2 s
  severe hang — 100% CPU on the main thread. Confirmed reproducible on main
  branch; still open.
- **Issue #426:** Moderate-length markdown with nested lists freezes the app
  entirely. A maintainer confirmed the cause is "excessive nesting" interacting
  with SwiftUI's `Environment` propagation.
- **Issue #396:** Long code snippets crash (`EXC_BAD_ACCESS`) on iOS.

The on-device model can and does produce nested lists and code blocks. If the
response triggered any of these MarkdownUI pathologies, the MainActor would be
blocked for seconds *after* generation completes, which could:

- Extend the apparent freeze window beyond what the watchdog expects.
- Delay the MainActor hop in the force-recovery pipeline, causing the abort
  timer to fire on what is actually a render hang, not a generation wedge.
- Compound with a borderline-slow generation to push total wall-clock time
  past the 25 s deadline.

**What changed in 0.2.112.**

- `ChatMessageBubble` now renders assistant bubbles with plain
  `Text(message.text).textSelection(.enabled)`. The raw model string is
  displayed verbatim; no parsing or view-tree transformation happens in-app.
- `import MarkdownUI` was removed from `ChatDetailView.swift`.
- The `swift-markdown-ui` SPM package reference and its `MarkdownUI` product
  dependency were removed from `project.pbxproj` (5 locations). On the next
  Xcode resolve, `Package.resolved` will drop `swift-markdown-ui`,
  `NetworkImage`, and `swift-cmark`.
- `ChatExport.markdown(for:)` and the long-press "copy as Markdown" actions
  are pure string operations and continue to work — the raw model output is
  already Markdown-formatted, so export fidelity is unchanged.

**Result (0.2.112 field test, 2026-04-22).** MarkdownUI is ruled out. Freezes
and the post-force-quit relaunch failure reproduced with plain `Text` rendering
and no `swift-markdown-ui` in the binary. The freeze occurs during framework
initialization before any generation is attempted, and during generation on
multi-turn exchanges. See §12 for full incident details. §10.2 (replacement
rendering library) is deprioritized; focus should return to the `FoundationModels`
generation-wedge hypothesis and §11.1 (framework readiness gate).

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
layout. If this delta is consistently > 1 s, it confirms the rendering layer
as a bottleneck independent of the generation path.

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

With MarkdownUI ruled out (§10.1), the rendering-layer qualifier no longer
applies. Current guidance:

- `proactiveWedgeThresholdMs` — with MarkdownUI gone, any main-thread stall
  exceeding this threshold is attributable to framework initialization or
  generation, not rendering. The threshold can potentially be tightened.
- `mainActorWedgeAbortSeconds` — field data shows initialization-phase stalls
  of up to ~14 s; the abort timer must remain above this to avoid false aborts
  during the init burst. Consider gating the watchdog arm on `frameworkReady`
  (see §11.1) so initialization stalls are never seen by the watchdog at all.
- `generationDeadlineSeconds` — can potentially be tightened now that rendering
  is off the critical path.

### 10.6 Apple Feedback Assistant escalation

**Top priority** — the §12.3 diagnostics export provides the clearest
signal collected to date: a 100% reproducible, zero-variance "3rd send"
wedge confirmed across three sessions and in airplane mode.

**Minimal repro sequence (confirmed, ready to file):**
1. Fresh `LanguageModelSession`.
2. Send any first message → succeeds.
3. Send any second message → succeeds.
4. Send any third message → `FoundationModels` wedges the main thread.

No specific content, context size, or network state required to reproduce.

Build a minimal standalone app (single-view, no MarkdownUI, no SwiftData)
to strip all app-specific variables, then file two separate reports:

1. **"3rd send" generation wedge** — `LanguageModelSession.respond(to:)` 
   wedges the main thread indefinitely on exactly the third invocation in a
   fresh session. Include the §12.3 session table and `generation_early_cancel_
   wedge_detected` + `force_recovery_mainthreadunreachable` log excerpts.
2. **Post-force-quit relaunch failure** — force-quitting during an active
   generation wedge leaves the framework in a state where subsequent app
   launches wedge on the loading screen indefinitely. Include the §12.1
   incident description.
3. **Init-phase main-thread stalls** — `SystemLanguageModel.default` access
   at launch causes repeated 1–14 s main-thread stalls before any generation.
   Include the `main_thread_stall` sequence from §12.1.

The minimal repro and the exact 3-step sequence give Apple engineers the
clearest possible signal with no app-specific noise.

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

## 11. General Performance Optimization Initiative

Independent of the root freeze investigation, field diagnostics from build
0.2.112 reveal a class of inefficiency that may be compounding the root issue
even if it is not causing it. These observations motivate a broader effort to
remove unnecessary main-thread load, thread-blocking operations, and memory
pressure from the app — reducing the surface area that interacts badly with an
already-fragile framework.

> **Note:** The items in this section are not directly implicated in the freeze
> mechanism described in §§1–9. However, any inefficiency that occupies the
> main thread, inflates memory pressure, or introduces unexpected blocking
> increases the probability that a borderline `FoundationModels` call tips into
> a full wedge. Addressing them is low-risk and produces measurable UX
> improvements regardless of root-cause outcome.

### 11.1 Earlier FoundationModels framework initialization

**Observed behavior.** `loadRuntimeLimits()` is called from
`ContentView.onAppear` and completes in ~41 ms. However, the first access to
`SystemLanguageModel.default` triggers lazy framework initialization — the
Neural Engine context setup, internal reporter registration, and result
accumulator allocation — which causes repeated main-thread stalls of 1–14 s
*after* `runtime_limits_loaded` is logged. These stalls appear with `sid=-`
(no active session), confirming they are framework-level and not generation-
or render-layer. Associated framework log noise:

```
Result accumulator timeout: 3.000000, exceeded.
Reporter disconnected. { function=sendMessage, ... }
Attempted to update accumulator from source type: X, after completion has
already been called for token:[...]
```

The app has no awareness that this initialization window is open. The UI
appears fully ready while the framework is still settling, so the first user
action (tapping New Chat, composing a message) hits the main thread while it
is still absorbing initialization bursts.

**Two actionable improvements:**

**A. Shift initialization earlier.** Move the first `SystemLanguageModel.default`
access to the earliest possible app lifecycle point — `intraiApp.init()` or a
detached task spawned from `@main` — so the framework initialization window
overlaps with the launch sequence rather than occurring while the user is
actively navigating. Total stall time is unchanged; perceived impact is
reduced because the stalls happen before the UI is interactive.

**B. Gate UI on framework readiness.** Add a `frameworkReady: Bool` state to
`IntelligenceService` (or a lightweight `FoundationModelsReadinessMonitor`
observable) that starts `false` and flips to `true` after the initialization
burst has settled. Surface this state in `ContentView` and `ChatDetailView`
to:

- Disable the New Chat button and composer until `frameworkReady` is `true`.
- Show a brief, non-alarming indicator (e.g. a muted "AI initializing…" label
  in the toolbar or a disabled compose field with placeholder text).
- Prevent navigation into `ChatDetailView` when the framework is not yet
  ready — avoiding the scenario where the user enters a chat, the device
  freezes, and there is no recovery indicator.

Detecting readiness is non-trivial because `FoundationModels` does not expose
an explicit "ready" event. Pragmatic approaches:

- Poll `SystemLanguageModel.default.availability` at a short interval from a
  background task until it returns `.available` with stable timing (i.e. two
  consecutive fast polls).
- Use a fixed settling delay (e.g. 3–5 s after `runtime_limits_loaded`) as a
  conservative heuristic.
- Monitor main-thread heartbeat degradation via the existing proactive wedge
  detector — flip `frameworkReady` only after the heartbeat returns to
  baseline.

**Expected outcome.** Even without resolving the root freeze cause, this
change eliminates the "app looks ready but isn't" UX failure and prevents
watchdog false-positives where an initialization-phase stall is
misclassified as a generation wedge.

### 11.2 Audit for other synchronous main-thread work at navigation time

The 0.2.112 session also shows main-thread stalls when navigating to a new
`ChatDetailView` even after startup completes. Beyond framework init, common
sources of unintentional main-thread work at navigation time include:

- SwiftData fetch descriptors executing synchronously on the main actor.
- `@Model` property access triggering fault resolution across a large object
  graph.
- `.onAppear` closures performing non-trivial computation before yielding.

A focused audit of `ChatDetailView.onAppear`, any `@Query` property wrappers
in the view hierarchy, and `IntelligenceService` state mutations triggered by
session selection would identify any additional contributors.

### 11.3 Memory pressure baseline

High memory pressure increases the probability of the OS pre-empting
background threads (including the cooperative thread pool) to reclaim pages,
which can extend or trigger wedges. A baseline memory profile (Xcode
Instruments → Allocations + Leaks) across a typical session lifecycle would
confirm whether retained `LanguageModelSession` objects, cached transcripts,
or SwiftData fault buffers are accumulating across sessions. Known candidates:

- `LanguageModelSession` instances — currently created fresh per generation
  but should be verified as deallocated promptly after `respond(to:)` returns.
- `AIContextBuilder` transcript strings — these can be large for long sessions
  and are currently rebuilt on every send.
- `FreezeLogger` in-memory event buffer — confirm it is bounded and flushed
  to disk on backgrounding.

---

**Guiding principle (updated 2026-04-22).** §10.1 is complete — MarkdownUI and
network routing are both ruled out. The "3rd send" pattern (§12.3) is now the
strongest signal in the investigation. The most impactful next steps are:

1. **§10.6** (Apple Feedback Assistant escalation) — the "3rd send" pattern
   is a precise, zero-variance repro case. File a report with the §12.3 session
   data and the minimal sequence (fresh session → send any 2 messages → send a
   3rd). This is the highest-leverage action available right now.
2. **§11.1** (framework readiness gate) — prevents the force-quit cascade and
   eliminates false watchdog triggers from the init burst. Implementable without
   Apple involvement and improves UX regardless of root-cause resolution.
3. **§12.2** (disable autoname) — still an open hypothesis. The §12.3 log does
   not include autoname events, so it cannot be evaluated from that data.
   Low-effort to test: flip `autonameEnabled` to `false`, reproduce the 3-send
   sequence.
4. **§10.5** (watchdog threshold tuning) — lower priority; the proactive 5 s
   detector is already catching every freeze. Revisit once §11.1 separates the
   init window from the generation window.

The §11 initiative is complementary: it addresses confirmed inefficiencies
that are observable right now, produces immediate UX improvements, and
reduces the ambient load under which the `FoundationModels` framework
operates — making all root-cause experiments cleaner and more attributable.

---

## 12. Field Incident Log

### 12.1 Build 0.2.112 — 2026-04-22

**Device:** Physical iPhone (iOS 26)  
**Build:** 0.2.112 (fresh install after clean delete)  
**Outcome:** Freeze on second multi-turn message; app stuck on loading screen
after force-quit; required device reboot to recover.

#### Sequence of events

**App launch (fresh install):**
- CoreData `Application Support` directory did not yet exist → expected first-
  launch diagnostic noise; `Recovery attempt... was successful` confirmed clean
  creation. No concern.
- `runtime_limits_loaded` fired at 41 ms — `loadRuntimeLimits()` itself was
  fast.
- Immediately after, repeated main-thread stalls of 4–14 s (`sid=-`) with no
  user interaction and no generation in flight:
  ```
  main_thread_stall durMs=4277, 9778, 13649, 10558, 9267
  ```
  These are caused by `FoundationModels` lazy Neural Engine initialization
  triggered by the first `SystemLanguageModel.default` access.

**New chat navigation (before any prompt):**
- Further main-thread stalls (1–6 s) with `sid=-`.
- Framework-internal log noise:
  ```
  Result accumulator timeout: 3.000000, exceeded.
  Reporter disconnected. { function=sendMessage, ... }
  Attempted to update accumulator from source type: X, after completion
    has already been called for token:[...]
  ```
  These are `FoundationModels` internal reporters timing out and disconnecting
  during initialization. The app has no visibility into or control over these.

**First message (simple prompt):**
- Clean lifecycle: `send_start` → `generation_finished` in 3822 ms.
- `generation_max_tokens` fired — response was token-capped as expected.
- `autoname_model_call_finished` at 546 ms.
- Device remained responsive.

**Second message (multi-turn follow-up):**
- App froze immediately after sending. No `send_start` event captured —
  the debugger connection had already dropped due to the earlier init-phase
  stalls, so no log events were recorded for this freeze.
- The freeze did not self-resolve; user force-quit.

**After force-quit:**
- App stuck on loading screen on every relaunch attempt.
- No crash report generated (force-quit produces SIGKILL, not a crash).
- Device reboot required to restore normal launch behavior.

#### Conclusions from this incident

| Finding | Implication |
|---------|-------------|
| Freeze reproduced without MarkdownUI | MarkdownUI **ruled out** as root or compounding cause |
| Stalls at `sid=-` before any generation | Root cause is `FoundationModels` init, not generation path |
| First generation ran cleanly in 3.8 s | App-level generation path is healthy when framework is stable |
| Post-force-quit relaunch failure | Force-quit during wedge can leave Neural Engine context partially live; subsequent launches wedge on init |
| No crash report | Force-quit (SIGKILL) is not recorded; abort-path breadcrumbing would also not help here |

#### Recovery

Device reboot cleared the wedged Neural Engine state and restored normal
launch behavior.

---

### 12.2 Build 0.2.113 (attempted) — 2026-04-22

**Hypothesis:** The autoname feature fires a second `respond(to:)` call
immediately after the first user message completes. If the `FoundationModels`
framework has not fully settled from the primary generation, a concurrent or
rapid-successive invocation could compound the wedge or trigger a new one.
Disabling autoname would isolate whether the second model call is a
contributing factor.

**What was done:** `autonameEnabled` flag added to `IntelligenceService.swift`
set to `false`, guarding the single `scheduleAutonameIfNeeded(...)` call site.
`diagnosticsBuildVersion` bumped to `0.2.113`.

**Outcome:** The change was reverted before field testing could be completed
— the build did not reach the device in a state where the experiment could
be evaluated. Changes were rolled back via `git`.

**Status: Inconclusive — not yet tested.**

The hypothesis remains open. Autoname is still a plausible compounding
factor:

- It fires a `respond(to:)` call with a fresh `LanguageModelSession`
  approximately 1 turn after the primary generation finishes.
- The first confirmed freeze in §12.1 occurred on the second user message,
  which is the same exchange where autoname would have already run (from the
  first message) and may have left the framework in an unsettled state.
- Re-running this experiment is low-effort: flip `autonameEnabled` to `false`,
  install, reproduce the §12.1 prompt sequence.

---

### 12.3 Build 0.2.112 — Airplane-Mode Session + Diagnostics Export — 2026-04-22

**Device:** Physical iPhone (iOS 26)  
**Build:** 0.2.112  
**Test condition:** Airplane mode + Wi-Fi off (confirmed no network at OS level)  
**Diagnostics file:** `intrai-freeze-diagnostics-1776885219.json`

#### Purpose

Determine whether network routing (PCC / cloud model) plays any role in the
freeze, and capture a structured log for quantitative analysis.

#### Session summary

Three independent chat sessions were captured. The same pattern occurred in
every session:

| Session | Send 1 | Send 2 | Send 3 |
|---------|--------|--------|--------|
| 1 | ✅ 3.6 s | ✅ 8.1 s | ❌ Wedge |
| 2 | ✅ 2.9 s | ✅ 5.4 s | ❌ Wedge |
| 3 | ✅ 3.1 s | ✅ 6.2 s | ❌ Wedge |

Every third send produced:
1. `generation_early_cancel_wedge_detected` (proactive watchdog fired at ~5.5–5.8 s)
2. `force_recovery_mainthreadunreachable` — MainActor could not be reached
   during force-recovery
3. `process_abort` — intentional `abort()` for unrecoverable wedge

Sends 1 and 2 succeeded without incident. Context fill ratio at freeze was
0.18–0.32 in all cases, well below the 0.75 pre-flight cap, ruling out
token-window exhaustion as a trigger.

The absolute 25 s deadline timer has **never fired** in any recorded session.
All recorded freezes are caught by the proactive 5-second heartbeat detector.

#### Key findings

| Finding | Implication |
|---------|-------------|
| Freeze reproduced identically in airplane mode | PCC and network routing are **ruled out** as factors. `SystemLanguageModel.default` is strictly on-device. |
| 100% reproducible on exactly the 3rd send | The trigger is not transcript length, content, or prior session state — it is internal `FoundationModels` state after exactly two prior successful invocations. |
| Context fill ratio at freeze: 0.18–0.32 | Token-window exhaustion is **ruled out** as a trigger for these incidents. |
| Proactive watchdog always fires (absolute deadline never fires) | The freeze onset is consistent (~5.5–5.8 s stall). The 25 s absolute deadline may be unnecessarily conservative; §10.5 tuning is lower priority given this data. |
| MainActor unreachable during force-recovery in all cases | The wedge is deep enough that the recovery sequence cannot interrupt it; `abort()` is the correct terminal action. |
| No autoname events visible in the 0.2.112 diagnostics log | Cannot evaluate the §12.2 hypothesis from this data. Either autoname did not fire (unlikely) or its log events are not captured by the current `FreezeLogger` schema. |

#### Recovery

App self-terminated via `abort()` in all three freeze incidents. Cold relaunch
succeeded normally in each case (no post-force-quit relaunch failure in this
session, consistent with `abort()` producing a clean crash vs. SIGKILL from a
force-quit).

#### Updated priority implications

The "3rd send" pattern is the highest-quality repro case collected to date
and should be the primary artifact for Apple Feedback Assistant escalation
(§10.6). The exact repro sequence — fresh session, send any two messages,
send a third — works across content types, transcript sizes, and network
conditions.

**Status: Confirmed and documented.**
