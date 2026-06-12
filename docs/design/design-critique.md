# LDA.app Design Critique: "Counsel" Review Window

A structured product-design review of the native macOS SwiftUI app, grounded in the
shipped source. Visual direction is "Counsel": paper-forward, light/dark adaptive,
one ink-blue accent, semantic per-entity-type hues. Audience is cross-border lawyers
who care about precision, defensibility, and not leaking client data.

Files reviewed:

- `macos/LDACore/Sources/LDAUI/AppShell.swift`
- `macos/LDACore/Sources/LDAUI/DocumentPane.swift`
- `macos/LDACore/Sources/LDAUI/EntitySidebar.swift`
- `macos/LDACore/Sources/LDAUI/SettingsView.swift`
- `macos/LDACore/Sources/LDAUI/CounselTheme.swift`
- `macos/LDACore/Sources/LDAUI/ReviewModel.swift`

The headline: the visual language is genuinely good. Paper detail surface, hairlines
over shadows, a disciplined single accent, serif body, and adaptive entity hues all
read as intentional and professional, closer to Harvey/Legora than to a generic
Tailwind admin panel. The weaknesses are almost entirely in *flow legibility and
trust signaling*, not in styling. For a redaction tool a lawyer will stake privilege
on, "where did my file go," "what does Accept mean," and "can I trust the count" are
the load-bearing questions, and several of them are currently underserved.

---

## 1. Information hierarchy and visual weight

### 1.1 The three-state detail pane has no persistent title or document identity
**Severity: Med.** Once a document is open (`DocumentPane.readingColumn`), nothing in
the detail pane tells the user *which* file they are looking at. The window's
`navigationTitle` is the static string `"Legal Document Anonymizer"`
(`AppShell.swift:58`), not the document name. The serif reading column shows body text
but no filename, page count, or word count header.

*Why it matters for a lawyer:* Redaction work is often batched across near-identical
drafts (Engagement Letter v3 vs v4). With no visible document identity, a lawyer can
accept entities and export the wrong draft and never notice. Provenance is a
professional-responsibility concern, not a nicety.

*Fix:* Set `navigationTitle` (and the window proxy icon) to the open document's
filename via `.navigationDocument(url)` or by binding the title to
`model.sourceURL?.lastPathComponent`. Add a thin document header above the reading
column with filename, detected type, and a word/char count.

### 1.2 Entity hue carries critical meaning but is the weakest channel
**Severity: Med.** Entity type is encoded almost entirely as a low-chroma color: a 7px
section dot (`SectionHeader`), an 8px row dot, and an underline tint in the document.
`CounselTheme.color(for:)` deliberately uses muted, closely-spaced hues, and three
distinct sensitive types (`nationalID`, `uscc`, `bankAccount`) collapse to the *same*
gold (`CounselTheme.swift:66`). The type name is present as text, so color is
redundant rather than sole-channel (good), but the dots are doing real scanning work
at a size and chroma where they are nearly indistinguishable, especially in dark mode
and for color-vision-deficient users.

*Why it matters:* A lawyer scanning a 200-entity contract relies on the dots to
triage "are the bank accounts all caught?" If gold means three different things and
green vs teal vs blue are a few hue degrees apart, the at-a-glance channel fails.

*Fix:* Either (a) give `nationalID`/`uscc`/`bankAccount` distinct hues, or (b) accept
that color is decorative and lean on a tiny type glyph/abbreviation in the dot.
Increase dot size to ~10px and add a subtle ring so low-chroma fills still register.

### 1.3 Accept state is encoded by global row opacity, which fights legibility
**Severity: High.** A rejected group row is dimmed to 55% opacity over the *entire*
row (`EntityGroupRow.body` `.opacity(accepted ? 1.0 : 0.55)`), and the type dot drops
to 40%. "Dimmed" reads as "disabled/unavailable" in macOS conventions, not as "I
deliberately excluded this from redaction."

*Why it matters:* Reject is the high-stakes action: a rejected PII span will appear in
cleartext in the exported document. Encoding the most dangerous state as a *faded,
easy-to-overlook* row is backwards. The thing a lawyer most needs to re-scan before
export (what did I choose to leave exposed?) is the thing the UI visually retreats.

*Fix:* Keep both states fully legible. Use an explicit state affordance: accepted rows
get a filled accent check or the sealed-token chip; rejected rows get a clear
"will remain visible" marker (e.g., a struck dot or a small "kept in clear" caption in
`danger`), not blanket dimming. Reserve opacity for true unavailability.

---

## 2. The toolbar: Anonymize vs Export balance and labeling

### 2.1 Two competing primaries: prominent Anonymize and prominent passphrase Export
**Severity: Med.** Anonymize is `.borderedProminent` ink-tinted in the toolbar
(`AppShell.swift:88`), while Export is plain bordered (`:99`), which is the correct
relationship *for the detect step*. But the modal passphrase sheet's confirm button is
*also* `.borderedProminent` ink (`AppShell.swift:239`), and the empty-state "Choose
File" is *also* ink-prominent (`DocumentPane.swift:88`). The accent is reserved
per-screen, so there is never a moment of two accents on one surface, but the accent no
longer reliably means "the single most important action of the whole task." It means
"the local primary," which is weaker brand signaling.

*Why it matters:* In a linear pipeline (open to anonymize to review to export), the
user benefits from the accent advancing like a wayfinding cue. Right now it lights up
on every step's local default, so it stops pointing forward.

*Fix:* Keep the accent on the single forward action that is currently actionable, and
demote the satisfied step. Once a doc is `.ready`, the toolbar's prominent accent
should move from Anonymize to Export so the eye is pulled toward the next real step.

### 2.2 "Anonymize" the verb vs "Detect" the behavior: labeling mismatch
**Severity: High.** The button says **Anonymize** with a magic-wand icon
(`AppShell.swift:85`), but clicking it does *not* anonymize anything. It runs
detection and presents candidates for review; nothing is redacted until Export
(`ReviewModel.anonymize()` only sets `entities`, while `export()` does the tokenizing
and file writing). The help text even says "Detect sensitive information"
(`AppShell.swift:91`), contradicting the label. Meanwhile the banner after import says
"Click Anonymize to detect" (`AppShell.swift:184`), conflating the two words.

*Why it matters:* A lawyer who reads "Anonymize" as "the document is now anonymized"
may believe the work is done after step 2 and skip the export, or worse, assume the
on-screen document is already safe to share. For a redaction tool, a verb that
overstates what happened is a genuine trust/safety bug, not just copy.

*Fix:* Rename the primary to **Detect** (or "Find Sensitive Info") with a scan-style
icon (`sparkle.magnifyingglass`), and reserve "Anonymize/Redact" for the Export action
that actually produces the redacted file. Make the banner copy agree.

### 2.3 Export is the act of redaction but is labeled like a generic share/save
**Severity: Med.** "Export" with `square.and.arrow.up` (`AppShell.swift:96`) reads as
"send this somewhere," not "produce the redacted document plus encrypted mapping." The
real semantics (write a redacted file + an encrypted `.ldamap` sidecar) are richer and
more reassuring than the label admits.

*Fix:* Consider **Export Redacted...** (the trailing ellipsis correctly signals a
follow-on dialog, which is also missing today). Lead the user to understand this is the
moment redaction is committed to disk.

### 2.4 Open lives far from the empty-state CTA, and there is no keyboard parity shown
**Severity: Low.** Open is in `.navigation` placement (leading), while the empty-state
"Choose File" is center-canvas. Fine. But neither surfaces the Cmd+O / Cmd+E shortcuts
that the File menu reportedly provides (per commit history), so power users can't learn
them in context.

*Fix:* Add `.keyboardShortcut` hints in `.help()` tooltips, or show the shortcut in the
menu and let the toolbar inherit it.

---

## 3. The empty / drop state as first-run

### 3.1 Strong, on-brand empty state, but the privacy promise is buried as fine print
**Severity: Med.** The drop zone is the best-composed screen in the app: serif
headline, dashed ink target with a hover state, single CTA, and the line "Everything
stays on this Mac" (`DocumentPane.swift:76`). For this product, *offline / on-device*
is the entire value proposition versus cloud tools that lawyers are forbidden to use.
Yet it is set in `.callout` secondary text, visually equal to the file-format list.

*Why it matters:* The first-run screen is where a risk-averse lawyer decides whether to
trust the tool with a privileged document at all. "Nothing leaves this machine" should
be the loudest non-headline element, ideally with a lock glyph, because it is the
reason to use this over Harvey.

*Fix:* Promote the privacy line to its own reassurance row with a `lock.shield` glyph
and slightly stronger weight, distinct from the format hint. Consider a persistent
"Offline" pill in the toolbar or status bar so the guarantee is always visible, not
only at first run.

### 3.2 The drop target is the entire pane but doesn't look droppable until hovered
**Severity: Low.** The dashed border only intensifies on hover (`isDropTargeted`), and
the whole pane is tappable. A first-run user may not realize they can drag a file onto
it; the affordance is discoverable only by accident or by reading.

*Fix:* The current resting dashed border at 1.5px is okay, but add a quiet "or drag a
file anywhere here" caption under the button, and make the resting border slightly more
present so the drop affordance reads without hover.

### 3.3 Failure copy collides with the empty state
**Severity: Low.** On import failure the error is appended *inside* the drop zone
(`DocumentPane.swift:91`) in footnote secondary color, not `danger`. A failed
"unsupported format" message in muted gray under a friendly "Drop a document" headline
is easy to miss and tonally mismatched.

*Fix:* Render import errors in `CounselTheme.danger` with a warning glyph, and consider
a brief inline banner rather than tucking it beneath the CTA.

---

## 4. Review flow clarity (accept vs reject, what Export does, where files go)

### 4.1 No model for "what does the green switch mean," and the default is Accept-all
**Severity: High.** Every detected entity is created `accepted: true`
(`ReviewModel.anonymize()` `:209`), and each group has a bare switch with no label
(`EntityGroupRow` `Toggle("", ...)`). There is no legend, no header explaining that
ON = "will be redacted" and OFF = "will remain visible in the export." A new user sees
a wall of green switches and a dimmed minority and must infer the contract.

*Why it matters:* This is the core interaction of the entire app and it is unlabeled.
Accept-all-by-default is a defensible *safety* default (over-redaction is safer than
under), but combined with the dimming problem (1.3), a user who flips a switch off may
not realize they just chose to expose a national ID in cleartext.

*Fix:* Add a one-line legend at the top of the sidebar ("Switched on = redacted on
export. Off = left visible.") and/or a column micro-header. Consider labeling the
control state inline ("Redact" / "Keep") rather than a bare switch. Add a sidebar
summary chip: "187 will be redacted, 13 kept visible."

### 4.2 The user cannot see or trust the consequence of Reject before exporting
**Severity: High.** In the document pane, rejected entities simply lose their highlight
and render as plain body text (`DocumentPane.apply` only styles accepted/candidate
states; a rejected entity has no span styling at all once toggled off). So a rejected
PII value visually becomes indistinguishable from ordinary prose. There is no preview
of the *redacted result* anywhere; the user only sees candidates over the original
text. They never see what the exported file will actually look like until they open it
on disk.

*Why it matters:* Lawyers verify redactions by reading the redacted output. Asking them
to mentally simulate "[PERSON_1] will replace this name, and that rejected name will
stay" across hundreds of spans is exactly the error-prone step redaction tools exist to
eliminate.

*Fix:* Add a "Redacted preview" toggle on the document pane that swaps accepted spans
for their sealed tokens inline and marks rejected-but-detected PII with a distinct
"will remain visible" treatment (e.g., a thin `danger` underline). Let the lawyer read
the actual output before committing.

### 4.3 "Where does the redacted file go?" is answered only after the fact
**Severity: Med.** The export flow opens a directory picker
(`AppShell.beginExport`), then a passphrase sheet, then writes
`<name>_redacted.txt|docx` plus `<name>_redacted.ldamap`. The naming and the sidecar
are never explained up front; the user learns the filename only from the terse success
banner "Exported N tokens to <file>" (`AppShell.confirmExport`). There is no "Reveal in
Finder" affordance, and the `.ldamap` sidecar (the encrypted key to re-identify) is
never named or explained in the UI at all.

*Why it matters:* The `.ldamap` *is* the privileged material; it is the mapping back to
real identities. A lawyer must understand it exists, that it is encrypted, and that it
must be stored/destroyed with care. Surfacing it only as a silent second file on disk
is a real custody gap.

*Fix:* In the passphrase sheet, preview both output filenames and explain the sidecar:
"We will write `Engagement_redacted.docx` and an encrypted key file
`Engagement_redacted.ldamap` that can restore the original names. Keep it secure."
After export, replace the banner with a result card offering "Reveal in Finder" and
naming both files.

### 4.4 The passphrase sheet's "blank = Keychain" model is subtle and risky
**Severity: Med.** Leaving the passphrase blank silently protects the mapping with the
*local* Keychain (`AppShell.confirmExport` `.keychain(account:)`). That means the
encrypted sidecar can only be opened on this Mac, which is a meaningful limitation if
the lawyer ever moves machines or needs co-counsel to restore. The sheet says "Leave it
blank to protect the mapping with the system Keychain" but does not spell out the
portability tradeoff.

*Fix:* Add one clarifying line: "Keychain protection only works on this Mac. Set a
passphrase if you need to open the mapping elsewhere." Consider making the choice an
explicit segmented control (Passphrase / This Mac only) rather than an empty field.

---

## 5. Sidebar density and grouping

### 5.1 Grouping by value is smart, but the header count is ambiguous
**Severity: Med.** Sections group by type, rows group by distinct value with an `xN`
occurrence pill, and the section header count is *distinct values* not occurrences
(`EntitySidebar` comment at `:55`, `SectionHeader count: groups.count`). So "Person 12"
means 12 distinct people, while a row's `x4` means 4 occurrences. Two different counting
semantics sit inches apart with no label distinguishing them.

*Why it matters:* "How many people are in this contract" vs "how many times is this
name mentioned" are both questions a lawyer asks, and the UI answers them with bare
numbers that look identical. Miscounting entities undermines confidence in completeness.

*Fix:* Label the header count ("12 names") or add a tooltip; keep the `xN` pill but
ensure the visual language clearly separates "distinct values" from "occurrences."

### 5.2 Row baseline alignment and triple-meaning of the dot
**Severity: Low.** The row uses `.firstTextBaseline` with a manual alignment guide
nudge on the dot (`EntityGroupRow.body`), which is fiddly and will drift if the serif
value wraps or the token chip changes height. The dot simultaneously encodes type (its
hue) and accept-state (its opacity), overloading a 8px target.

*Fix:* Separate concerns: let the dot mean type only; move accept-state to the
explicit control and chip. Simplify alignment to `.center` for a single-line row.

### 5.3 No bulk actions, no filtering, no search at 200-entity scale
**Severity: Med.** The sidebar comment explicitly targets a 200-entity contract, but
there is no "Accept all / Reject all," no per-type bulk toggle, no search box, and no
filter (e.g., "show only rejected" or "only LLM-detected"). At scale, reviewing means
scrolling and individually toggling.

*Why it matters:* The realistic workflow is "accept everything, then hunt for the few
false positives to reject" or "trust regex, scrutinize LLM guesses." Both need
filtering and bulk ops. Without them, a 200-entity doc is a scroll-and-squint marathon,
and fatigue causes missed exposures.

*Fix:* Add a sidebar search field and a small filter control (All / Redacted / Kept /
By source). Add per-section "redact all / keep all" affordances and a global one. Let
the user sort by occurrence count to triage high-frequency names first.

### 5.4 Source label "regex" leaks implementation
**Severity: Low.** The caption shows the detection source as "regex" vs "LLM" vs
"manual" (`EntityGroupRow.sourceLabel`). "regex" is engineer-speak. A lawyer cares
about *confidence/provenance* ("Rule-based" vs "AI-detected"), not the underlying
technique.

*Fix:* Relabel to "Rule" / "AI" / "Manual" (or "Pattern" / "AI suggestion"). This also
lets the user reason about trust: rule-based matches are deterministic; AI ones warrant
a closer look.

---

## 6. Status banner, progress, and the learning note

### 6.1 The learning note is buried mid-sentence and easy to miss
**Severity: Low.** After a run the banner reads "Ready for review. Applied 2 learned
terms, hid 1 you rejected before." (`AppShell.bannerText` + `ReviewModel.learningNote`).
This is a *trust-building* disclosure (the app silently suppressed something the user
once rejected), yet it is appended to a transient secondary-gray status line that is
replaced the moment an export message arrives.

*Why it matters:* "We hid 1 thing you rejected before" means a PII candidate was
*removed from review without the user seeing it this time*. That is exactly the kind of
automated decision a careful lawyer wants surfaced, not whispered. If they disagree,
they need a path to see what was suppressed.

*Fix:* Make the learning contribution a small, persistent, dismissible chip near the
sidebar header ("2 auto-applied, 1 hidden. Review") that links to the affected entries
or the Learned settings tab. Don't let an export message overwrite it.

### 6.2 Progress + ETA are well done; the indeterminate "Loading model" gap is not
**Severity: Med.** The determinate bar with monospaced percent and ETA is excellent
(`AppShell.detectingLabel`). But before the first progress callback, `etaText` is
"Loading model" (`ReviewModel.anonymize` `:189`) while `progress` is 0, so the bar sits
empty at 0% possibly for many seconds as a multi-GB GGUF loads. There is no distinct
"warming up the AI model" state; it looks like a stall at zero.

*Why it matters:* On first run after launch, model load can dominate. A bar frozen at
0% reads as "hung," and a lawyer may force-quit mid-detection.

*Fix:* Show an explicit indeterminate "Loading the on-device model..." phase (spinner,
not a 0% bar) until the first real progress tick, then switch to the determinate bar.
Cache/keep the model warm between runs if feasible.

### 6.3 No cancel control during detection
**Severity: Med.** Once Anonymize starts, there is no way to cancel; the toolbar button
just disables (`canAnonymize` false during `.detecting`). A long LLM pass on a big
document is uninterruptible.

*Fix:* Provide a Cancel affordance in the progress banner that tears down the detached
task.

### 6.4 No undo / no dirty-state guard
**Severity: Med.** There is no visible undo for accept/reject toggles, and nothing warns
if the user opens a new document or quits with un-exported review decisions. Re-running
Anonymize rebuilds `entities` from scratch (`:209`), silently discarding every manual
accept/reject the user made.

*Why it matters:* A lawyer who spends 20 minutes rejecting false positives, then clicks
Anonymize again (e.g., after toggling AI), loses all of it with no warning. That is a
destructive action presented as a benign re-run.

*Fix:* Preserve manual decisions across re-runs where spans still match, or at minimum
confirm "Re-detecting will reset your review. Continue?" Add Cmd+Z for toggles.

---

## 7. Settings organization across the four tabs

### 7.1 Tab naming and ordering don't match their weight or the header doc
**Severity: Low.** The file header comment claims two tabs (Vocabulary, Learned) but the
view ships four: General, Vocabulary, Learned, Sharing (`SettingsView.body`). "General"
contains *only* Appearance (`GeneralTab` is a single theme picker), so the tab is
misnamed: it's an Appearance tab pretending to be a catch-all. Ordering puts the rarely
touched Appearance first and the frequently used Vocabulary second.

*Fix:* Either rename "General" to "Appearance" (with its `paintbrush`-style icon), or
fold appearance into a real General tab that also hosts the AI-model and offline
settings (see 7.2). Update the stale header comment.

### 7.2 The single most important setting (the AI model) is absent from Settings
**Severity: High.** Detection quality hinges on `modelPath` and `useLLM`
(`ReviewModel`), and "AI detection is on by default; it degrades to
deterministic-only if no model is present" (`:99-102`). Yet Settings has *no* surface
for: whether a model is loaded, where it is, its size/version, or a toggle to turn AI
detection on/off. The "AI entities" toggle mentioned in the AppShell header comment is
not present in the shipped `toolbarContent` either. So the user cannot tell whether they
are getting full hybrid detection or silent deterministic-only fallback.

*Why it matters:* A lawyer running on deterministic-only (because the model didn't load)
gets materially worse PII coverage and has *no way to know*. Silent capability
degradation in a redaction tool is the most dangerous possible failure: it under-redacts
quietly. This is the highest-value missing surface in the app.

*Fix:* Add a "Detection" (or "AI Model") settings section showing model status
("On-device model loaded, v2, 2.7 GB" vs "No model found, using rules only"), a path
picker, and an explicit AI-detection toggle. Surface the active mode in the main window
too (a small "AI + Rules" vs "Rules only" indicator near the entity count).

### 7.3 Vocabulary regex UX assumes regex literacy and gives weak feedback
**Severity: Med.** The PatternRow exposes a `.*` regex toggle and an `Aa` case toggle
with terse tooltips (`PatternRow`). Invalid regex shows only a warning triangle inside
the field; there is no error message, no test field, and no examples beyond the inline
hint "M-\d{5}". Most lawyers are not regex authors.

*Why it matters:* Custom vocabulary is how a firm encodes "always redact Project
Cardinal" or matter numbers. If the power feature is regex-gated with cryptic toggles,
either it goes unused or a malformed pattern silently matches nothing/too much.

*Fix:* Default rows to literal mode (already the case), but add a "Test against
sample" field that shows live matches, spell out the invalid-regex reason on hover, and
offer a couple of one-click regex templates (matter number, employee ID).

### 7.4 "Forget All" is destructive but only protected by being a trailing button
**Severity: Low.** `LearnedTab`'s "Forget All" is `role: .destructive` but fires
`store.reset()` with no confirmation (`SettingsView:305`). Learned memory may represent
weeks of accumulated firm knowledge.

*Fix:* Add a confirmation dialog. Consider an "Export your learned terms first?" nudge
given the Sharing tab exists.

### 7.5 Sharing tab's security note is good but the format disclosure undercuts trust
**Severity: Med.** The Sharing tab honestly states the profile is "plain JSON (a
glossary of terms to redact)... may name clients or matters" (`SharingTab:92`). Honesty
is right, but exporting an *unencrypted* file that lists client/matter names from a tool
whose whole pitch is confidentiality is a tension. There is no option to encrypt the
shared profile, unlike the mapping sidecar which *is* encrypted.

*Why it matters:* A lawyer who emails `LDA-Vocabulary.json` to a colleague may be
transmitting a cleartext list of sensitive client identifiers, contradicting the app's
on-device promise.

*Fix:* Offer optional passphrase encryption for the exported profile (reuse the mapping
protection path), and/or warn at export time. At minimum, strengthen the caution into a
`danger`-toned note.

---

## 8. Consistency of spacing, type, and the accent

### 8.1 Spacing scale is ad hoc, not tokenized
**Severity: Low.** Paddings are hardcoded per view: banner uses 16/8, footer 10/6,
sidebar rows vertical 3, drop zone 48 (twice, nested), settings tabs 24 and 20 and 16.
There is no shared spacing scale in `CounselTheme` (which defines only colors). Values
drift (e.g., 20 vs 24 for tab section padding) without a system.

*Fix:* Add spacing/radius/duration tokens to `CounselTheme` (e.g., `space2 = 8`,
`space3 = 12`...) and consume them, matching the color-token discipline already in
place. This is the one place the otherwise-disciplined theme layer is incomplete.

### 8.2 Type pairing is intentional but applied inconsistently
**Severity: Low.** Serif (`.serif`) is used for body, entity values, and settings
headlines, while system sans carries captions and chrome. Good pairing. But some
headlines are serif (`SharingTab`, `VocabularyTab`, `LearnedTab`, `GeneralTab`) while
the passphrase sheet headline (`AppShell.passphraseSheet`) is plain `.headline` sans.
Minor inconsistency in the "voice" of headers.

*Fix:* Decide that section/sheet headlines are serif and apply uniformly, or reserve
serif strictly for document-adjacent content. Either is fine; pick one.

### 8.3 Accent discipline is strong; one near-violation
**Severity: Low.** The accent rule ("never an entity color, only primary/focus/
selection") is well honored. The closest tension: the Learned tab's "auto-redact" badge
uses `inkAccent` (`SettingsView:349`), which is the only place the brand accent labels a
*data state* rather than an action/selection. Defensible, but it slightly dilutes the
"accent = the thing you act on" rule.

*Fix:* Acceptable as-is, but consider a neutral or per-type hue for the badge to keep
the accent purely actionable.

---

## 9. Moments of confusion and dead-ends

- **Re-run wipes review (4/6.4):** clicking Anonymize again silently discards all
  accept/reject work. Dead-end with data loss.
- **Silent deterministic fallback (7.2):** no indication AI detection failed to load;
  the user can't tell which detection mode produced the results.
- **"Anonymize" overstates safety (2.2):** the on-screen doc is never actually
  anonymized; only the exported file is. A user could believe the visible document is
  safe to share.
- **The `.ldamap` sidecar (4.3):** the encrypted re-identification key is written to
  disk and never named or explained in-product. Custody dead-end.
- **No redacted preview (4.2):** the user cannot see the actual output before committing
  it, only candidates over the original.
- **No cancel during a long LLM pass (6.3):** the only escape is force-quit.
- **Empty-state error hidden (3.3):** import failures render in muted gray under a
  friendly headline.

---

## Prioritized Top-10 Fixes

1. **Rename "Anonymize" to "Detect" (and Export to "Export Redacted...").** The current
   verb claims the document is anonymized when nothing has been redacted yet; for a
   redaction tool this is a safety-grade mislabel. Make the help text and post-import
   banner agree. *(2.2, 2.3)*

2. **Surface AI-model status and add an explicit AI-detection toggle in Settings + main
   window.** Today the app can silently fall back to rules-only detection (worse PII
   coverage) with zero indication. Show "AI + Rules" vs "Rules only" and the loaded
   model's identity. This is the most dangerous silent degradation in the app. *(7.2)*

3. **Stop encoding Reject as faded-row opacity; make "will remain visible" explicit and
   legible.** The highest-risk state (PII left in cleartext) is currently the easiest to
   overlook. Use a clear danger-toned "kept visible" marker and keep both states fully
   readable. *(1.3, 4.1)*

4. **Add a Redacted Preview of the actual output before export.** Let the lawyer read
   what the exported file will look like (accepted spans as tokens, rejected PII flagged)
   instead of mentally simulating it across hundreds of spans. *(4.2)*

5. **Preserve manual accept/reject across re-runs, or confirm before discarding.**
   Re-clicking Detect silently destroys all review work with no warning or undo. *(6.4)*

6. **Explain and surface the `.ldamap` sidecar and the Keychain-vs-passphrase tradeoff
   in the export flow.** Name both output files up front, explain the encrypted
   re-identification key, add "Reveal in Finder," and clarify that blank passphrase =
   this-Mac-only. *(4.3, 4.4)*

7. **Add a sidebar legend, a redact/keep summary count, and bulk + filter + search
   controls.** Explain what the switch means, show "187 will be redacted, 13 kept," and
   make a 200-entity contract triageable instead of a scroll marathon. *(4.1, 5.3)*

8. **Show document identity (filename) in the window title/header and promote the
   "stays on this Mac" privacy promise.** Provenance prevents exporting the wrong draft;
   the offline guarantee is the core reason to trust the tool over cloud rivals and
   should be loud, persistent, and lock-badged. *(1.1, 3.1)*

9. **Fix the detection lifecycle: an explicit "Loading model" indeterminate phase, a
   Cancel control, and persistent surfacing of the learning note.** Don't let a 0% bar
   look hung during model load, let users abort a long pass, and don't whisper "we hid 1
   thing you rejected before." *(6.1, 6.2, 6.3)*

10. **Tighten the design system: tokenize spacing/radius in CounselTheme, relabel
    "regex"/"LLM" to "Rule"/"AI", give nationalID/uscc/bankAccount distinct hues, and
    rename the "General" settings tab.** A cluster of low-effort consistency and clarity
    wins that round out an already-strong visual language. *(8.1, 5.4, 1.2, 7.1)*
