# LDA seven-item feature wave

**Date**: 2026-09-02
**Scenario**: Full-flow delivery (product review, design, investigation, implementation, security audit, code review, QA)
**Members**: product reviewer, designer, investigator, security officer, QA lead, plus four implementation engineers
**Branch**: merged into `feat/lda-macos-core` at `ce98f12` by fast-forward from `feat/wave-2026-09-02-integration`. Local only: nothing pushed.

---

## TL;DR

- All seven requests are delivered. Two of them were questions, and both answers are yes with stated caveats.
- 47 commits plus 9 merges, 96 files, +12,645 / -1,409, 27 new test files. Final full suite: **2017 tests, 0 failures**, and **0 skipped** once re-run on the Mac mini against the real model. The three products (`LDAApp`, `lda`, `lda-mcp`) all build.
- The investigation for item 5 found four real defects, two of them silent PII leaks in the redacted Word file. All are fixed and pinned by tests.
- A security audit of the MCP surface returned five findings, three of them blocking. All five are fixed and pinned by tests.
- Verified live against the real model on the Mac mini, which surfaced two pre-existing defects, one of them a leak. Nothing is pushed.

## Go / No-Go

| Item | Content |
|------|---------|
| Verdict | Go for the wave itself: green, reviewed, and verified live. GUI interaction still needs a human on an unlocked screen, and one pre-existing leak is worth fixing before release |
| Blockers | None in code |
| Severity found and fixed | 2 silent PII leaks (docx), 1 high MCP disclosure, 2 medium MCP integrity, 1 sandbox write denial |
| Open follow-ups | 10, all listed below, none blocking |

### Independent QA pass

A QA lead reproduced every claim against the built binaries rather than the implementers' logs, and scored the wave 88 of 100 with no critical and no high findings. On a 22-part adversarial Word fixture, none of 17 planted values survived anywhere in the redacted package, the restored file was textutil-identical to the original, and eight parts came back byte-identical. All 22 checks on the machine-facing surface passed, including every refusal the security fixes added and a whole-wire scan that found no path, filename or planted value.

Three medium findings came back, all in one family: a value's **type** was not re-derived after the value was split or partially excluded, so type-level controls did not mean what the interface said they meant. A date following a soft line break was typed as a phone, the text and Markdown export path never split at all, and excluding one occurrence over the machine surface left that value's other occurrences tokenized beside it, which lets a reader infer the placeholder and undo the protection everywhere. None leaked data on its own; all three broke a control the user is told they have, so all three were fixed rather than deferred.

Fixing them turned up three more problems that no one had reported. Splitting is now done inside the splitter itself rather than at each call site, because the defect was precisely that one call site behaved differently from another. The export used by the app's Export for AI action never split at all, which meant a value spanning a line break got a **different placeholder from the same value in a partner document**, quietly breaking the one promise a shared session mapping exists to make. And excluding a value by exact bytes still tokenized the same value in a different letter case a few words away, which re-created the inference leak the fix was meant to close; values are now compared the same way the rest of the pipeline compares them.

One residual risk is recorded rather than fixed: a defined-term alias attached to an excluded name is still replaced, so a document can read `ABC Company (hereinafter "{COMPANY_2}")` and hand a reader the equation directly. It is not new, and closing it needs a refactor plus a live model run to confirm.

---

## 1. What each request became

### Item 1: remove Copy for AI and Restore from paste, export .md instead

`Copy for AI` is now **Export for AI…** (Cmd+Shift+E). The save panel opens first, then the session builds its handoff, then one Markdown file is written with an encrypted `.ldamap` sidecar beside it. Cancelling the panel changes nothing: no mapping, no session record, no parked state, no token chips.

Paste from AI is gone entirely: the sheet, the menu item, the request token, the card. The menu-bar clipboard companion (Redact Clipboard / Restore Clipboard) is **kept**, because it was not part of the request and it is the one path that needs no file.

The five side effects that lived inside the old clipboard action are inherited unchanged rather than re-implemented: the shared session mapping, the session record that the compliance report and the Matters list depend on, the parked session that survives quitting, the sealed token chips, and the cross-document rescan plus release preflight.

### Item 2: different colors per entity type during the scan

A measured finding came first: after a scan every detection is accepted, and accepted spans were drawn as a faint fill with **no underline**, so the type hue was invisible exactly when the user looked for it. The nine common types sat within a colour difference of about 3 on a scale where 10 is the threshold for reliable discrimination. A palette swap alone would not have fixed the complaint.

So three things changed together. The 16 hues were replaced with a two-tier palette pinned by contrast tests, the underline now carries the hue in both states (solid when the value will be redacted, dashed when it is kept visible) while the fill carries state only, and the Safe Preview placeholder chips take their own type hue instead of one accent colour. A legend in the document header lists the types present with counts and collapses in three tiers on a narrow window.

### Item 3: select a word in the document and add it as PII

The reading pane is now backed by a text view that reports its selection, so a right-click on selected text offers `Protect "张三" as Person` with the type guessed from the selection, plus a submenu of all kinds. There is also Cmd+Shift+P and a footer button that becomes primary while a selection exists.

Protecting covers every occurrence, and the rules are explicit: the selection is trimmed of punctuation, it may not cross a paragraph, a manual selection wins over a partially overlapping detection, a selection strictly inside an already protected value is a no-op that says so, and role labels such as 甲方 are blocked with a Protect Anyway escape. Undo is the standard Cmd+Z.

### Item 4: restore should default to the same document and workspace

One card, `Restore a file`, accepts a chosen or dropped `.md`, `.txt`, or `.docx`. The mapping is resolved without asking: the sidecar saved next to that exact file wins, then the in-memory session mapping, then the parked session resumed just in time, then the matter profile, and only if all of those fail does it ask. The passphrase prompt appears only after a Keychain attempt actually fails. The result line names which key opened the file.

### Item 5: can a .docx restore keep its formatting? (question)

**Yes, and it now does better than when the question was asked.** The file path is genuinely run-preserving: 17 of 22 package parts come back byte-identical including styles, numbering, fonts, theme, header, footer and comments, and the restored text matches the original.

The investigation also found four defects, two of them leaks:

| Defect | Effect before the fix |
|---|---|
| Tabs and line breaks were invisible to the parser | Two tab-separated phone numbers were glued into one digit run that matched no pattern, so **both shipped in clear**; a phone before a soft break was mistyped and its date moved across the break on restore |
| Tracked deletions and field instructions were never scanned | A phone inside a tracked deletion and two `mailto:` addresses inside hyperlink fields **shipped in clear**; revision and comment author names too |
| Rewritten runs lost edge whitespace | Word rendered `{EMAIL_1}for details` and the space was gone for good after a re-save |
| A newline was injected per paragraph per cycle | Document XML grew from 1 to 53 stray newlines over a round trip |

After the fixes, a grep of all 13 planted values and author names across every part of the redacted package returns zero hits, the restored text is byte-identical to the original in the `textutil` comparison, and the stray newline count is back to 1.

The honest caveat that remains: a value that spans a formatting boundary comes back with the first run's formatting, and a value that spans a **tracked change** is restored into the live text and flattens that change. The app now counts tracked changes at import and warns before you redact.

### Item 6: can an MCP user choose which PII to redact, like in the app? (question)

**Yes.** `detect_entities` now returns a stable id per entity plus a `detectionId` for the set. `anonymize` accepts `excludeEntityIds` with that `detectionId`, and `excludeTypes` for whole categories, and reports back how many values it left visible and whether the detection had moved since the review.

No entity text ever crosses the wire: an id is a hash of the handle, type, and the offsets that the tool already returned. Ids are bound to their handle, so an id from one document cannot silently keep a value visible in another. A stale, foreign, or malformed id is refused before anything is written.

### Item 7: can an MCP user send a .docx and get a restored .docx, with no .md in between? (question)

**Yes, on the path that preserves formatting.** Restoring a redacted `.docx` artifact yields a `.docx`. For the round trip through a human or agent edit, the edited redacted `.docx` is staged back and passed as `editedHandle`, and the restored Word file keeps its formatting; a manual transcript confirmed the bold run, the human's edit, the header date and the untouched `styles.xml` all survive.

The one path that stays text is `editedText`: restoring an edited **text** blob gives text back, because merging free-form edits into Word runs is a different problem, and the tool description now says so instead of implying otherwise.

---

## 2. Review findings, all fixed

**Security audit of the MCP surface** returned Conditional Go with five findings. The `editedHandle` argument accepted any staged document with no lineage check, which let an unrelated original's real text cross the wire inside the suspect-placeholder report and let that original be laundered into the outbox past the rule that originals never leave. A second matter's redacted artifact restored silently with the wrong mapping and exported under the wrong name. Entity ids were portable across documents. Exclusions left no trace in the attestation, so a run that deliberately left everything visible looked identical to a full redaction. All five are fixed, with 13 new tests including a whole-wire scan for paths, filenames and planted values.

**Code review of the docx fixes** returned Merge, with three medium follow-ups. Two were closed in this wave: a supplementary part that failed to redact used to be copied through with its PII intact and no error, and the GUI export never split spans at breaks the way the engine does. The third, dual-view detection for tracked changes, is documented and deferred.

**Sandbox check**: the packaged app is sandboxed, and writing the `.ldamap` next to a save-panel file was denied. A throwaway sandboxed probe app proved both the failure and the fix, which is now a declared related-item type plus coordinated file access.

---

## 3. Live verification on the Mac mini

The MacBook has no model, so the wave was first verified deterministic-only with 8 tests skipping. The whole suite was then re-run on the Mac mini against the real 2.74 GB Qwen3.5-4B model, twice: once through the staged Command Line Tools workaround, and once through plain `swift test` after full Xcode 26.6 was installed mid-run. Both agree.

| | |
|---|---|
| Result | 2017 tests, 0 failures, **0 skipped** |
| Live-model tests | all 8 ran and passed, from 6.5 s model load to a 17 s profile fill |
| Person and company | redacted end to end, absent from all 18 package parts |
| Restore | text identical, 17 of 19 parts byte-identical, headers and footers included |
| Whitespace drift | none; every detected value was located and replaced |

The features this wave added hold up live. Two documents exported together share one mapping, so the same person carries the same placeholder across both while a person unique to the second document continues the numbering. A phone sitting directly above a date splits into two correctly typed tokens instead of one swallowing the other. On the machine-facing surface, excluding one person left all six of that person's occurrences visible while everything else stayed tokenized, and a scan of the whole transcript for eighteen different needles found no path, no filename, and no entity text beyond the one value the caller deliberately exposed.

### Two defects found, both pre-existing

**A spaced Chinese date was never detected and shipped in clear. Now fixed.** The pattern required `2026年3月15日` with no spaces, so `2026 年 3 月 15 日` passed straight through into the redacted file, leaking in all three channels at once: the Word file, the text file, and the machine-facing read. It was asymmetric within the same function, since every English date form a few lines below tolerates whitespace and phone numbers match with spaces. It matters because converting a PDF to text routinely inserts spaces around Chinese numerals, and this project has already lost entities once to exactly this kind of spacing. Fixed at `a7fcec4`: the gap between the date parts is now the Unicode space separators plus the tab, so it also covers the ideographic space a Chinese editor inserts. Each run is bounded, because an unbounded whitespace quantifier beside another quantifier is the backtracking shape this engine has stalled on before, and newlines are excluded so a date can never span a line break. Four tests pin it, including a backtracking guard, and all three forms verified end to end through the command line tool.

**Coverage is under-reported.** The detect command and the anonymize summary count body text only, while redaction also covers headers, footers and notes. A fixture reported 19 entities and made 22 replacements. It errs in the safe direction, but anyone auditing coverage with detect would wrongly conclude the header names leak.

## 4. What still needs a human

1. **GUI interaction on an unlocked screen.** Automated input was refused, so the select-to-protect flow, the legend collapse, the export panel and the restore panel were verified by hosted tests and by inspection, not by driving the real app. Manual scripts are in the implementer reports.
2. **Decide where this lands.** The wave is merged into `feat/lda-macos-core` locally. Nothing has been pushed.

## 5. Open follow-ups, none blocking

- Type exclusion is applied before a value is split, so asking to keep dates visible can still lose a date that arrived inside a phone-shaped span. The type is now correct everywhere the user sees it, but the deny-list decision was already made by then. Moving it is a design call because the app path has no exclusion layer at all today.
- The detect command and the anonymize summary count body text only, while redaction covers the whole package.
- Dual-view detection so a value spanning a tracked change stops producing a chimera.
- Tracked changes inside headers and footers are not counted, only the body.
- Word glossary parts are still not scanned, so Quick Part content can carry PII.
- Soft hyphens and symbol elements still glue text the way tabs used to.
- The MCP detection cache was left unbuilt, so a review plus anonymize runs the model twice.
- A restored value that crossed a formatting boundary takes the first run's formatting.
- The parked session stores the mapping without its alias metadata, so a restore resumed after quitting loses the full-name to short-name links.
- `SessionModel.swift` is 1573 lines, past the 800-line house limit, and was already over before this wave.

## 6. Rollback

Every change is on one local branch. Reverting means deleting `feat/wave-2026-09-02-integration`; the four feature branches remain independently revertible, and `feat/lda-macos-core` was never touched.

---

*Detailed per-item reports, the security audit, the code review and the fidelity investigation are in the session scratchpad and summarized here. Key decisions should be reviewed by the engineering owner before this lands.*
