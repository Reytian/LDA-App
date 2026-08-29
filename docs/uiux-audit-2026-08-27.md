# LDA UI/UX Audit & Improvement Plan (2026-08-27)

> Researched by the UI Designer expert. Covers the two shipped surfaces:
> the **native macOS app** (`macos/LDACore/Sources/LDAUI`, ~11.5k lines, the
> current hackathon product) and the **Streamlit PoC** (`ui/`, the legacy
> `streamlit run app.py` entry). The macOS app is the focus unless noted.

## 1. What is already excellent

- **A real design system ("Counsel")** — `CounselTheme.swift` defines
  appearance-adaptive color tokens, an entity-hue map, spacing/radius tokens,
  and WCAG-AA-checked contrast (ink accent fill darkened specifically because
  `0x6E82DA` only hit 3.58:1). This is rare discipline for a PoC.
- **Consistent state → feedback mapping** — every `ReviewStatus` has a banner
  state, empty state, and tray glyph (`EntitySidebar`, `DocumentPane`,
  `SessionViews`).
- **Trust-first UX** — "On-device" lock indicator, "X will remain visible"
  danger callout, flag-don't-guess restore reporting.
- **Accessibility** — VoiceOver announcements on completion, labeled controls,
  keyboard nav (Space/Return toggle, Cmd+Shift+S scan).

## 2. Findings

| # | Area | Severity | Issue | Where | Fix |
|---|------|----------|-------|-------|-----|
| F1 | Privacy / safety | High | **Restore Clipboard writes de-anonymized PII to the system clipboard with no timeout and no warning** — readable by any app, clipboard managers, cloud sync. Pre-launch audit item #6. | `SessionViews.swift` `restoreClipboard()` | Auto-clear after ~30s if unchanged + warn the user in the companion note and onboarding. |
| F2 | Error recovery | High | **Scan failure is a dead end.** At `.failed` the banner shows the error but the primary "Scan for PII" action only appears at `.imported`; there is no retry/re-import affordance, so the user must reopen the file to recover. | `AppShell.swift` `statusBanner` | Add a "Re-import / Try again" action in the failed-state banner. |
| F3 | Terminology | Low | Mode is labeled **"Restore"** in the picker, but code/docs/prose also say **"De-anonymize"** and **"Bring back"** (7 "De-anonymize" vs 33 "Restore" across LDAUI; `DeanonymizeShell` file/comments vs `Restore` header). Split naming risks user confusion. | `RootShell`, `DeanonymizeShell`, `OnboardingView` | Standardize on **"Restore"** for the mode; keep "Bring the answer back" only as friendly copy. Align code comments. |
| F4 | Feedback | Medium | The workflow header (Add→Scan→Review→Share) and the primary action live in **different chrome** (header vs banner). A user on "Share" may not notice Copy/Save in the toolbar. | `AppShell.swift` | When `hasSharedOutput`, briefly highlight the toolbar Copy/Save actions or surface the next step in the completion card (already partly done). |
| F5 | Empty/edge states | Medium | **Multi-document + one-not-ready**: "Save Redacted" enabled on the active doc while "Copy for AI" spans all ready docs — fine, but the per-doc readiness is only a tiny tray count; no inline "N of M ready" summary before Copy. | `AppShell` toolbar / `SessionViews` tray | Add a quiet "3 of 4 documents ready" caption near Copy for AI. |
| F6 | Onboarding | Low | Onboarding explains the round trip well but never mentions the **clipboard PII caveat** (F1) or that **rejected items stay visible**. | `OnboardingView.swift` | One line on clipboard clearing + the "kept visible" rule. |
| F7 | Streamlit PoC | Medium | Linear 4-step rerun flow; no persistent error surface if Pass 1/2 LLM call fails mid-session; settings show partial API key in plaintext-ish code block. | `ui/*.py` | Add a sticky error banner + mask key in "Current Configuration". (Lower priority: legacy PoC.) |

## 3. Recommended plan (priority order)

1. **F1 Clipboard safety** — highest value, low risk, localized to `restoreClipboard()`.
2. **F2 Failure recovery** — add retry affordance to the failed banner.
3. **F3 Terminology unify** — string/comment pass.
4. **F5 / F6 polish** — readiness caption + onboarding caveats.
5. (Optional) **F7 Streamlit** — only if the PoC is still in active use.

## 4. Constraint

The macOS app cannot be run/visually verified in this environment (needs Xcode +
the GGUF model). F1/F2/F3 are localized, obviously-correct edits, but they
**must be compiled (`swift build` / Xcode) to confirm** before shipping. The
Streamlit PoC *can* be run here for live verification.

## 5. Open question for the user

Which surface should I change, and how deep? (See the in-chat question.)

---

## 6. Implementation log (2026-08-27)

Scope confirmed by user: **macOS app (primary) + full plan (F1–F7)**.

### macOS app (`macos/LDACore/Sources/LDAUI`)

- **F1 Clipboard PII safety** (`SessionViews.swift` `restoreClipboard` +
  new `scheduleClipboardClear`): after "Restore Clipboard" writes de-anonymized
  PII to the system pasteboard, it now auto-clears after 30s *only if* the user
  has not copied something else, and tells the user in the companion note.
  Pre-launch audit #6 closed.
- **F2 Failure recovery** (`AppShell.swift` `statusBanner` + new `failedBanner`):
  a `.failed` detection/import now shows a recovery action. Import failure
  (empty document text) offers "Re-open document"; detection failure (text
  present) offers "Try again" (in-place re-run). The dead-end is gone.
- **F3 Terminology** (`DeanonymizeShell.swift`, `RootShell.swift` comments):
  internal "De-anonymize" comments unified to "Restore" to match the user-facing
  mode label. No user-facing string changed (the mode was already "Restore").
- **F5 Readiness caption** (`AppShell.swift` `copyForAIHelp`): the Copy for AI
  tooltip now reads "Copy the redacted text from N of M ready documents..." in
  multi-document sessions, so a partial handoff is never silent.
- **F6 Onboarding caveat** (`OnboardingView.swift`): the privacy promise now
  also states the 30s clipboard auto-clear and that rejected items stay visible.

F4 (workflow header ↔ toolbar) is satisfied by the existing completion card
("Safe text copied ... Bring the answer back in Restore" + "Go to Restore"
button); no additional change made.

### Streamlit PoC (`ui/`)

- **F7**: `settings_page.py` now fully masks the API key in "Current
  Configuration" (was leaking the last 4 chars). `anonymize_page.py` and
  `deanonymize_page.py` gain a sticky top-of-page error banner driven by
  `st.session_state["ui_error"]`, set wherever a workflow step catches an
  exception, so a mid-flow failure is never lost on rerun/scroll.

All three Python files pass `py_compile`. The Swift edits are type-checked via
`swift build` (see build result); they must be relinked/signed in Xcode before
shipping because the GGUF model and notarization are not exercised here.

---

## 7. Verification passes (2026-08-27)

### 7a. First verification pass

Every §6 claim was re-checked against the working tree, compiled, and the full
suite run. Two gaps were found and closed at the time:

- **F7's sticky error never unstuck, and leaked across pages.** Both pages
  shared one `ui_error` key and nothing ever cleared it, so one failure
  persisted for the whole session (including after a successful retry) and an
  anonymize-page failure also rendered on the restore page. Fixed with
  page-scoped keys cleared at the start of each attempt.
- **F2 looked half-done**, and was "closed" by making `ReviewModel.canAnonymize`
  return `!documentText.isEmpty` for `.failed`. **That fix was wrong — see 7b.**

### 7b. Expert review pass, and a retraction

Three reviewers (code, security/QA, design) reviewed the batch. Build clean at
zero warnings; `swift test` **812 passed / 0 failed / 0 skipped**, twice. (The
model-gated tests now run: the GGUF is present at
`~/Developer/lda-models/lda-v2-Q4_K_M.gguf`. Note 812 is this branch's count;
866 belongs to `claude/mac-app-prelaunch-16ff47`, which is not an ancestor of
`feat/lda-macos-core`.)

**F2's premise was false, and 7a's fix for it was unreachable code.** Tracing
the state machine:

- `.failed` is set in exactly **one** place: `open(_:)`'s catch, i.e. an
  **import** failure, which leaves `documentText` empty.
- `anonymize()` never sets `.failed`. It ends at `.ready`, and an LLM problem
  surfaces through `aiWarning` on purpose, so a degraded pass warns rather than
  looking clean.
- Therefore `.failed` always implied empty text, `!documentText.isEmpty` was
  permanently false, the "Try again" button was unreachable, and Cmd+Shift+S
  stayed disabled exactly as before. Two of the four tests added in 7a asserted
  a state combination the app cannot produce, which is why they passed and why
  they made 7a's conclusion look verified.
- The audit's own premise ("no retry/re-import affordance") was also wrong:
  at `.failed`, `DocumentPane` renders its drop zone, which already carries a
  `borderedProminent` **Choose Files** invoking the same `presentOpenPanel()`,
  plus the same error text. There was never a dead end in the content area.

**The one real gap was the keyboard**: that prominent Choose Files had no menu
item and no shortcut anywhere in the app, so a keyboard-only user genuinely
could not recover from a failed import.

Actions taken:

- Reverted `canAnonymize` to `false` for `.failed`, with a comment recording why
  it must not be "fixed" again. Removed the unreachable `failedBanner` (which
  also restored `bannerIsError` and `bannerText`'s `.failed` case to being
  reachable instead of dead).
- Deleted the two vacuous tests. Kept the two that assert reachable states, and
  added: a guard that detection still has no failure state, and a test that a
  failed import clears any previous document's text.
- **Added File ▸ Open (⌘O)** via `SessionModel.requestOpen()`. This is F2's
  actual closure.
- `open(_:)`'s catch now clears `documentText`. It sets the new `sourceURL`
  before importing, so retained text from a previous document would have been
  described under the new document's name across the window title, tray row,
  export name, and mapping `sourceFile`.

**F1 (clipboard)** — a genuine defect was found in 7a's own code: the 30s clear
handler **assigned** `companionNote`, wholesale erasing the "N placeholders need
review" warning written by the restore seconds earlier. `companionNote` has
exactly one render site, so that was the only channel telling the lawyer a
restore was **incomplete** — and by then the text may already be in a filing.
Now appends. The delay is a named constant referenced by the timer and by every
sentence quoting it. Two limits are documented in code rather than papered over:
quitting inside the window defeats the timer, and a clipboard manager has
already archived the value at t=0. **Do not invest further here** —
`SensitiveClipboard` on `claude/mac-app-prelaunch-16ff47` (changeCount guard
plus `org.nspasteboard` concealed/transient markers, with tests) supersedes this
mechanism, and **must win at merge**; re-add this tree's onboarding wording if
the merge drops it.

**F6 (onboarding)** — the sentence added in §6 was factually wrong for the flow
the sheet teaches. It told every user that "when you restore, the real values
are placed on your clipboard", but only the menu-bar companion's Restore
Clipboard does that; Restore's own paste-back and file flows write a file and
never touch the clipboard. It also filed a caution under the lock icon and ink
accent, the app's reassurance mark, packaging a caveat as part of the guarantee.
Now: the promise stands alone under the lock; the cautions are a separate Label
with their own icon, the clipboard sentence is scoped to the companion, and it
no longer promises the clearing outright. Vocabulary aligned to the app's own
("choose to keep visible", "the exported document").

**F5 (readiness count) — reopened, NOT closed.** The audit asked for a quiet
caption near Copy for AI; a tooltip is hover-only, is invisible to VoiceOver
(`.help` is neither label nor value), and is unreachable in the state that most
needs it (at 0-of-M the button is disabled). Its denominator also counted failed
imports that can never become ready, reading as "you are about to leave that
document out". The denominator and the pluralization ("1 of 4 ready document")
are fixed; the placement is not. Recommended home: the tray section header's
existing count chip in `EntitySidebar.swift`. Note also that
`SessionModel.anonymizeAll()` exists but has **zero callers** — there is no
"Scan all" action, so the message currently names a problem the UI offers no way
to resolve.

**F4 — reopened, NOT closed.** §6 judged it satisfied by the completion card,
but that card is post-action feedback and F4 is about pre-action discoverability:
a user standing on "Share" who has not found Copy for AI cannot be helped by a
card that only appears after doing the thing they cannot find. The file's own
rule (put the mode's primary action in the banner next to the sentence naming it)
is applied at `.imported` and `.ready`-rescan but not to Copy for AI. Treat as
knowingly-not-fixed.

**Other fixes in this pass**: `copyForAIHelp` pluralization and denominator;
dead `bannerIsError` path resolved; restore page now clears its sticky error on
input change (7a claimed this and did not do it); one banner per failure instead
of two (set key + rerun, except the auto-running execute step where a rerun
would loop); `st.header("De-anonymize / Restore")` → `"Restore"`, finishing F3
on the Streamlit surface; `RootShell` comment table realigned.

### 7c. The window-inset refactor is NOT part of this change

`AppShell.swift` also carried an unrelated refactor
(`WindowContentTopInsetReader`, detail restructured onto `safeAreaInset`,
hardcoded initial 52). All three reviewers flagged it as the riskiest thing in
the diff and as needing verification on a real window, which this environment
cannot do. **It has been left out of the commit and remains in the working
tree.** Before committing it, check on a real window:

1. Does the header align across all four modes (Matters / Anonymize / Restore /
   Fill)? Only AppShell's detail was changed; `MatterWorkspaceView` and
   `FillReviewBody` have the same NavigationSplitView shape. If their safe area
   was already correct, AppShell now double-counts and shows a ~52pt gap.
2. The spacer is painted `paper` while the header below it is `appSurface`, so a
   visible band may sit under the toolbar (worse in dark mode).
3. Full screen and Split View: move the pointer to the top edge and watch
   whether the header stack slides as the titlebar returns.
4. Sidebar column top inset ("Documents" tray header under the toolbar).

Also worth addressing there: `Color.clear` is hit-testable in SwiftUI (unlike
`Spacer()`), so a full-width invisible band overlays the pane; and the
`.bordered` + `.tint(inkAccent)` button style introduced with it is the app's
first, with `CounselTheme`'s own notes warning that `inkAccent` reaches only
3.58:1 (hence `inkAccentFill`).
