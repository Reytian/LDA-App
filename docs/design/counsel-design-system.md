# Counsel Design System

The authoritative reference for LDA.app, a native macOS (SwiftUI) legal document
anonymizer. "Counsel" is the visual direction the UI grew into across
`CounselTheme.swift`, `DocumentPane.swift`, `EntitySidebar.swift`,
`AppShell.swift`, and `SettingsView.swift`. This document records what actually
ships today so future UI changes stay consistent. When code and this document
disagree, treat the divergence as a bug in one of them and reconcile.

House rules that apply to everything below: English only. No em-dash and no
en-dash used as a phrase separator (ranges and dates only).

Source of truth files:

- `macos/LDACore/Sources/LDAUI/CounselTheme.swift` (tokens)
- `macos/LDACore/Sources/LDAUI/DocumentPane.swift` (reading column, drop zone, sealed tokens)
- `macos/LDACore/Sources/LDAUI/EntitySidebar.swift` (grouped review list, chips, pills, headers)
- `macos/LDACore/Sources/LDAUI/AppShell.swift` (window shell, toolbar, status banner, sheets)
- `macos/LDACore/Sources/LDAUI/SettingsView.swift` (tabbed settings, vocabulary, learned badges)
- `macos/LDACore/Sources/LDACore/Domain/CoreTypes.swift` (`EntityType`, `DetectionSource`)

---

## 1. Direction and principles

Counsel is paper-forward, restrained, and professional. It should read like a
serious document tool a lawyer trusts, not a consumer app. The guiding ideas:

1. **Paper is the subject.** The document pane is a warm paper surface with a
   serif body set in a narrow reading column. Chrome recedes; content leads.
2. **One ink accent, used sparingly.** A single ink-blue (`inkAccent`) is the
   only brand color. It marks primary actions, focus, and selection, and nothing
   else. It is NEVER used as an entity color.
3. **Entities carry their own quiet hues.** Each `EntityType` has one low-chroma
   hue used only as a highlight underline, a sidebar dot, and a sealed-token
   tint. These hues never compete with the ink accent and never act as buttons.
4. **Hairlines over shadows.** Separation comes from 1px hairline borders and
   layered flat surfaces, not drop shadows or blur. Depth is achieved through
   surface tone (`appSurface` < `paper`/`raised`), not elevation effects.
5. **Dense but scannable.** The review sidebar must stay usable on a 200-entity
   contract. Rows are compact, counts use monospaced digits so they align, and
   repeated values collapse into one row with an occurrence pill.
6. **Fully appearance-adaptive.** Every color is a light/dark pair resolved
   against the effective `NSAppearance`, so light, dark, and system-following
   modes all look intentional. Do not hardcode a single-appearance color.
7. **Type tells you what a thing is.** Serif = document content and section
   titles; SF Pro (system) = chrome and controls; monospaced = sealed tokens and
   counts. The face is a semantic signal, not decoration.

---

## 2. Color tokens

All tokens live in `CounselTheme` and are built by
`dynamic(light:dark:)`, which wraps a dynamic `NSColor` that resolves
`.aqua` vs `.darkAqua` at draw time. Hex values are 24-bit sRGB `0xRRGGBB`.

### 2.1 Brand, surface, text, and line tokens

| Token | Light hex | Dark hex | Role / usage rule |
|-------|-----------|----------|-------------------|
| `inkAccent` | `#3A4FA0` | `#6E82DA` | The single brand accent. Primary buttons (tint), selection background, focus, progress bars, switch on-state, the `auto-redact` badge. NEVER an entity color, never a generic decorative fill. |
| `paper` | `#FCFBF9` | `#242529` | The document pane surface (warm paper). Backs the reading column and the detail column. |
| `appSurface` | `#F4F5F7` | `#1B1C1F` | Recessed app chrome. Backs the sidebar, the settings window, the sidebar footer. The lowest tone in the stack. |
| `raised` | `#FFFFFF` | `#2E2F33` | A raised surface: cards, popovers, chips, the status banner, sheet backgrounds, settings footers, status callouts. |
| `textPrimary` | `#2B2E33` | `#E9EAED` | Primary text: document body, entity values, headlines, section titles. |
| `textSecondary` | `#71757C` | `#9CA1A9` | Secondary text: captions, counts, helper copy, non-error banner text, the Settings gear glyph, the `hidden`/`learning` badges. |
| `hairline` | `#E2E4E8` | `#3A3C41` | The 1px border used in place of shadows: banner/footer dividers, card outlines, the occurrence-pill fill (at 0.6 opacity). |
| `danger` | `#B05F5C` | `#D98B88` | Errors and warnings only: invalid-regex glyph, error banner text. Note this is intentionally close to the `phone` entity hue but is a separate token with a separate role; do not substitute one for the other. |

### 2.2 Entity hue tokens

Returned by `CounselTheme.color(for: EntityType)`. Dark variants are lifted for
legibility on a dark surface. Each hue is used three ways and three ways only:
the highlight underline in the reading column, the dot in the sidebar/section
header/learned row, and the sealed-token tint (chip fill and inline sealed
text). Several `EntityType` cases intentionally share one hue.

| EntityType case(s) | rawValue label | Light hex | Dark hex |
|--------------------|----------------|-----------|----------|
| `.person` | `PERSON` | `#4F62B0` | `#8B9BE6` |
| `.company` | `COMPANY` | `#3E8497` | `#6FBDD0` |
| `.address` | `ADDRESS` | `#4E8C68` | `#86C9A1` |
| `.email` | `EMAIL` | `#3F84B5` | `#77B6E0` |
| `.nationalID`, `.uscc`, `.bankAccount` | `NATIONAL_ID` / `USCC` / `BANK_ACCOUNT` | `#A07A2E` | `#D9B968` |
| `.amount` | `AMOUNT` | `#9A5499` | `#D18FCF` |
| `.phone` | `PHONE` | `#B05F5C` | `#E09A97` |
| `.date`, `.unknown` | `DATE` / `UNKNOWN` | `#8A8175` | `#BFB6A6` |

> Note: `.person`'s hue (`#4F62B0`) is deliberately near `inkAccent`
> (`#3A4FA0`) but is a distinct token. The person hue only ever appears as a
> dot/underline/tint; the ink accent only ever appears on interactive accent
> surfaces. Keeping them apart by role is what prevents confusion. Do not unify
> them.

### 2.3 Standard opacity steps

Opacity is how the system reuses one hue at several intensities. The values in
use today:

| Opacity | Where |
|---------|-------|
| `0.10` | Candidate highlight background tint (reading column); ink-accent selection-row background in the sidebar. |
| `0.12` | Sealed `TokenChip` fill; learned decision-badge fill. |
| `0.20` | Sealed (accepted) inline token background fill in the reading column. |
| `0.28` | `TokenChip` border stroke. |
| `0.40` | Sidebar type dot when the group is not accepted. |
| `0.55` | Whole unaccepted sidebar row opacity; idle drop-zone card fill. |
| `0.60` | Occurrence pill fill (`hairline` at 0.6). |
| `0.85` | Drop-zone tray icon. |
| `0.95` | Sealed inline token foreground (keeps mono text legible). |

---

## 3. Typography

Three families, each with a fixed semantic role. There is no fourth family and
no custom font; everything is a SwiftUI system font with a `design:` selector.

| Family | SwiftUI | Role |
|--------|---------|------|
| Serif | `.system(_, design: .serif)` | Document content and titles. The reading-column body, drop-zone primary line, entity values in the sidebar and learned list, and every Settings section headline. The "this is the subject" face. |
| Sans (SF Pro) | `.system(...)` default | All chrome: toolbar labels, helper/caption copy, banner text, button labels, sheet body, pickers. The default unless a serif or mono role applies. |
| Monospaced | `.system(_, design: .monospaced)` / `.monospaced()` / `.monospacedDigit()` | Sealed tokens (`[PERSON_1]`), and all counts/digits that should align in a column (section counts, occurrence pills, "N active", learned kept/rejected counts, the ETA percentage). |

### 3.1 Type roles and sizes

Sizes are SwiftUI semantic text styles (which scale with the system), not raw
points. Roles in use, largest to smallest:

| Role | Style | Family | Example use |
|------|-------|--------|-------------|
| Pane title | `.title3` | serif | Drop-zone "Drop a document to anonymize". |
| Section / sheet heading | `.headline` | serif (chrome headings) | Settings tab headings ("Always redact these"), passphrase sheet title ("Protect the mapping" uses `.headline` sans). |
| Body (document) | `.body` | serif | Reading-column document text, `lineSpacing` 6. |
| Body (sealed token) | `.body` | monospaced | Accepted inline token inside the document. |
| Entity value | `.callout` | serif | Sidebar group value, learned row value. |
| Helper / banner / sheet copy | `.callout` | sans | Drop-zone subtitle, banner text, settings helper paragraphs, sheet body. |
| Section header label | `.caption` `.semibold` | sans | Sidebar `SectionHeader` type name. |
| Section count | `.caption` `.monospacedDigit` | mono | Sidebar `SectionHeader` count; "N active"; sharing counts. |
| Caption / fine print | `.caption` | sans | Settings fine print. |
| Row caption | `.caption2` | sans | Sidebar row "TYPE · source"; learned row "TYPE · kept/rejected". |
| Pill / chip / badge | `.caption2` (often `.monospaced`/`.monospacedDigit`/`.weight(.medium)`) | mono or sans | Occurrence pill, `TokenChip`, learned decision badge. |
| Footnote | `.footnote` | sans | Drop-zone failure detail. |
| Drop-zone icon | `.system(size: 46, weight: .light)` | SF Symbol | Tray icon. |
| Settings placeholder icon | `.system(size: 28, weight: .light)` | SF Symbol | Empty-state glyph. |
| Sidebar gear icon | `.system(size: 14, weight: .regular)` | SF Symbol | Footer Settings button. |

Rule of thumb: if it is part of the document or a name/title, set it in serif.
If it is a control or explanatory chrome, leave it in the system sans. If it is a
token or a number that should line up, set it monospaced.

---

## 4. Spacing and layout

### 4.1 Reading column (DocumentPane)

| Constant | Value | Meaning |
|----------|-------|---------|
| `columnWidth` | `680` | The capped reading measure for the serif body. Text never exceeds this width; it is centered with `.frame(maxWidth: .infinity, alignment: .center)`. |
| `gutter` | `48` | Minimum horizontal gutter on each side of the column. Also the placeholder padding. |
| `columnVerticalInset` | `56` | Vertical inset above and below the column body. |
| `lineSpacing` | `6` | Extra leading between wrapped lines of serif body. |
| `placeholderSpacing` | `12` | Vertical spacing inside the busy placeholder stack. |

### 4.2 Window and sidebar (AppShell)

- Shell is a `NavigationSplitView`: `EntitySidebar` leading, paper document pane
  detail. Detail = `statusBanner` over `DocumentPane` in a zero-spacing `VStack`.
- Sidebar column width: `min: 260, ideal: 320, max: 420`.
- Detail background `paper`; shell background `appSurface`.
- Navigation title: `"Legal Document Anonymizer"`.

### 4.3 Spacing scale observed

There is no formal token set for spacing; these are the recurring values. Prefer
reusing them over inventing new ones.

| Value | Typical use |
|-------|-------------|
| `2`, `3` | Tight vertical padding inside rows; value/caption stack spacing. |
| `6`, `8`, `9` | Inter-element gaps in rows and headers; chip horizontal padding. |
| `10`, `12`, `16` | Footer/banner padding; HStack gaps; settings inter-section spacing. |
| `18` | Drop-zone stack spacing; drop-zone card corner radius. |
| `20`, `24` | Settings section padding; sheet padding. |
| `48` | Reading-column gutter; drop-zone outer padding (doubled: inner card then outer frame). |
| `56` | Reading-column vertical inset. |

### 4.4 Corner radii

| Radius | Where |
|--------|-------|
| `18` | Drop-zone card (`RoundedRectangle`). |
| `8` | Settings status callout card. |
| Capsule | Occurrence pill, `TokenChip`, learned decision badge (all `Capsule(style: .continuous)`). |

### 4.5 Settings window

- Root is a `TabView` fixed at `width: 580, height: 440`, backed by `appSurface`.
- Four tabs: General, Vocabulary, Learned, Sharing.
- Each tab: top description block padded `20`/`24`, a `List` body, a footer bar
  (`raised` background, top `hairline`) holding the primary action and a count.

---

## 5. Elevation (hairlines over shadows)

The app uses no drop shadows. Depth is conveyed two ways:

1. **Surface tone stacking.** `appSurface` (lowest) under `paper`/`raised`
   (higher). The sidebar and settings sit on `appSurface`; the document, banner,
   chips, and sheets sit on `paper`/`raised`.
2. **1px hairlines.** A `Rectangle().fill(CounselTheme.hairline).frame(height: 1)`
   placed as a top or bottom `overlay` divides chrome regions: status-banner
   bottom edge, sidebar-footer top edge, settings-footer top edge. Cards use
   `.strokeBorder(CounselTheme.hairline, lineWidth: 1)`.

Do not introduce `.shadow(...)`, material blur as a depth cue, or large radii to
fake elevation. If two regions need separation, add a hairline or change the
surface tone.

---

## 6. Motion

Motion is minimal and functional, not expressive.

- **Progress, not spinners-for-flair.** Determinate detection uses a linear
  `ProgressView(value:)` tinted `inkAccent`, capped at `maxWidth: 300`, paired
  with a monospaced-digit percentage and ETA. Indeterminate import uses a small
  circular `ProgressView`.
- **Drop-target feedback** is a state change, not an animation timeline: on
  hover the drop-zone card fill goes `0.55 -> 1.0` opacity and the dashed border
  switches from `hairline` 1.5px to `inkAccent` 2px.
- Rely on SwiftUI's implicit transitions for state swaps (busy placeholder vs
  drop zone vs reading column). Do not add bespoke spring chains or attention
  animations. If motion does not clarify a state change, leave it out.

---

## 7. Component specs

Each component lists its anatomy, its states, and the exact tokens it uses.

### 7.1 Primary button (`borderedProminent` + ink tint)

- **Anatomy:** `Button` with `.buttonStyle(.borderedProminent)` and
  `.tint(CounselTheme.inkAccent)`. Label is text or a `Label` with an SF Symbol.
- **Used by:** Choose File (drop zone), Anonymize (toolbar), Export confirm
  (sheet), Export Profile / Add Term (settings).
- **States:** default = ink fill, white text; hover/active = system bordered-
  prominent feedback; disabled = `.disabled(...)` system dimming (Anonymize when
  `!canAnonymize`, Export when `!model.canExport`).
- **Tokens:** `inkAccent` (tint).

### 7.2 Secondary button

- **Anatomy:** `Button` with the default bordered style (no explicit tint), or
  `.buttonStyle(.borderless)` for icon-only affordances.
- **Used by:** Export (toolbar, default bordered, not prominent), Import Profile,
  Forget All (`role: .destructive`), the sidebar gear and the learned-row forget
  `xmark.circle.fill` (both borderless, glyph tinted `textSecondary`).
- **States:** default = system bordered/borderless; disabled via `.disabled`.
- **Tokens:** `textSecondary` for borderless glyph color; no accent.
- **Rule:** Exactly one prominent ink button per context. Export stays a
  secondary (bordered) button so it does not compete with Anonymize.

### 7.3 Switch toggle (accept control)

- **Anatomy:** `Toggle("", isOn:)` `.labelsHidden()` `.toggleStyle(.switch)`
  `.controlSize(.mini)` `.tint(CounselTheme.inkAccent)`, bound through
  `acceptedBinding` which routes to `model.setAccepted(ids:_)` for every
  occurrence in the group.
- **States:** on = ink-tinted switch (group accepted); off = system off
  (group rejected, and the whole row dims, see 7.6).
- **Tokens:** `inkAccent` (on-state tint).
- Other toggles (`.toggleStyle(.button)`) in the Vocabulary row (`.*` regex,
  `Aa` case) are button-style, not switches, and carry no ink tint.

### 7.4 Entity group row (`EntityGroupRow`)

- **Anatomy:** `HStack(alignment: .firstTextBaseline, spacing: 9)`:
  1. Type **dot**: `Circle().fill(color(for: type)).frame(8x8)`, baseline-
     aligned via an `alignmentGuide`.
  2. `VStack(spacing: 2)`: **value line** then **caption line**.
  3. `Spacer(minLength: 8)`.
  4. **Accept switch** (7.3).
  - Outer: `.padding(.vertical, 3)`.
- **Value line** (`HStack spacing: 6`): serif `.callout` value (`textPrimary`,
  `lineLimit(1)`, `.truncationMode(.middle)`); optional occurrence pill (7.8);
  optional `TokenChip` (7.7) when accepted and a token exists.
- **Caption line:** `.caption2` `textSecondary`, format
  `"TYPE  ·  source"` where source is `regex` / `LLM` / `manual`.
- **States:** accepted = full opacity, dot opacity `1.0`; not accepted = whole
  row `.opacity(0.55)`, dot `.opacity(0.4)`; selected = row background
  `inkAccent.opacity(0.10)` (selection is a UI affordance only, it does not
  change accept state).
- **Tokens:** entity hue (dot), `textPrimary` (value), `textSecondary` (caption),
  `inkAccent` (selection bg + switch), `hairline` (occurrence pill).

### 7.5 Section header (`SectionHeader`)

- **Anatomy:** `HStack(spacing: 8)`: 7x7 entity-hue dot; `.caption.semibold`
  `textSecondary` type label (`textCase(nil)` so it is not uppercased);
  `Spacer(minLength: 8)`; `.caption.monospacedDigit` `textSecondary` count.
- **Count semantics:** number of distinct grouped values, not raw occurrences.
- **Tokens:** entity hue (dot), `textSecondary` (label + count).

### 7.6 Rejected / dimmed state

Not a component but a cross-cutting state: an unaccepted group row renders at
`0.55` opacity with its dot at `0.4`, so rejected entities read as present but
de-emphasized. Never hide a rejected entity; dim it.

### 7.7 Sealed `TokenChip`

- **Anatomy:** `Text(displayToken)` `.caption2.monospaced()` in the entity hue,
  padded `6`/`2`, on a `Capsule(.continuous)` filled with the entity hue at
  `0.12`, with a `0.28` entity-hue stroke border. `.lineLimit(1).fixedSize()`.
- **Display form:** token is normalized to bracket form `[PERSON_1]` (the curly
  `{PERSON_1}` grammar form is rewritten to square brackets).
- **States:** appears only when a group is accepted and has a token; otherwise
  absent. No hover/press state (it is a label, not a control).
- **Tokens:** `color(for: type)` at full / `0.12` / `0.28`.
- The inline sealed-token rendering in the document (DocumentPane) is the same
  idea expressed in `AttributedString`: background `hue.opacity(0.20)`,
  foreground `hue.opacity(0.95)`, monospaced face, underline removed.

### 7.8 Occurrence "xN" pill

- **Anatomy:** `Text("×N")` (`\u{00D7}` glyph) `.caption2.monospacedDigit()`
  `textSecondary`, padded `5`/`1`, on a `Capsule(.continuous)` filled
  `hairline.opacity(0.6)`.
- **Visibility:** only when `group.occurrences > 1`.
- **Tokens:** `textSecondary`, `hairline`.

### 7.9 Drop zone

- **Anatomy:** centered `VStack(spacing: 18)` capped at `maxWidth: 440`: a
  `tray.and.arrow.down` SF Symbol (`size 46, weight .light`,
  `inkAccent.opacity(0.85)`); serif `.title3` primary line + `.callout`
  `textSecondary` subtitle ("Everything stays on this Mac."); Choose File primary
  button (7.1); optional `.footnote` `textSecondary` failure detail.
  Inner padding `48`, then the card, then an outer `48` frame.
- **Card:** `RoundedRectangle(cornerRadius: 18)` filled `raised` (opacity `0.55`
  idle, `1.0` when targeted), overlaid with a dashed `strokeBorder`
  (`dash: [9, 7]`).
- **States:** idle = card fill `0.55`, border `hairline` 1.5px; drop-targeted =
  card fill `1.0`, border `inkAccent` 2px. Whole zone is tap-and-drop: tap opens
  `NSOpenPanel`, drop accepts a `URL`.
- **Tokens:** `inkAccent` (icon, targeted border), `paper` (backing ZStack),
  `raised` (card), `hairline` (idle border), `textPrimary`/`textSecondary`/text.

### 7.10 Status banner

- **Anatomy:** `bannerChrome` = `HStack(spacing: 12)`, padded `16`/`8`, on a
  `raised` background with a bottom `hairline` divider. Lives above the document
  pane.
- **Variants:**
  - *Detecting:* linear `ProgressView(value:)` tinted `inkAccent`
    (`maxWidth: 300`) + monospaced-digit `.callout` label
    ("Anonymizing 42%  ·  about 12s remaining") in `textSecondary`.
  - *Working (importing):* small circular `ProgressView` + `.callout` text.
  - *Message / error:* `.callout` text, `textSecondary` normally or
    `danger` when `model.status == .failed`.
  - *Hidden* when idle with nothing to report.
- **Tokens:** `raised` (bg), `hairline` (divider), `inkAccent` (progress),
  `textSecondary` (normal text), `danger` (error text).

### 7.11 Learned decision badge

- **Anatomy:** `Text` `.caption2.weight(.medium)` in a color, padded `7`/`2`, on
  a `Capsule` filled `color.opacity(0.12)`.
- **Variants by `term.decision`:** `auto-redact` -> `inkAccent`;
  `hidden` -> `textSecondary`; `learning` -> `textSecondary`.
- **Note:** this is the ONE sanctioned place ink accent appears on a badge,
  because `auto-redact` is a primary, accept-equivalent state. It is not an
  entity badge.
- **Tokens:** `inkAccent` or `textSecondary`.

### 7.12 Section heading (Settings)

- **Anatomy:** serif `.headline` `textPrimary` title atop a `.callout`
  `textSecondary` helper paragraph (`fixedSize(vertical:)` so it wraps), inside
  a leading `VStack(spacing: 4)`.
- **Used by:** every Settings tab top block (General/Vocabulary/Learned/Sharing).
- **Tokens:** `textPrimary` (title), `textSecondary` (helper).

### 7.13 Settings footer bar

- **Anatomy:** `HStack` padded `16`, `raised` background, top `hairline`
  overlay. Holds the tab's primary button (left or right) and a monospaced-digit
  count or destructive action.
- **Tokens:** `raised`, `hairline`, plus the button's own tokens.

### 7.14 List rows (settings: vocabulary / learned)

- Vocabulary and Learned `List`s use
  `.listStyle(.inset(alternatesRowBackgrounds: true))`.
- The review sidebar uses `.listStyle(.sidebar)` with
  `.scrollContentBackground(.hidden)` over an `appSurface` background and
  `.tint(inkAccent)` for selection.
- Empty states use the shared `placeholder(_:systemImage:)`: a light SF Symbol
  (`size 28`) + `.callout` text, both `textSecondary`, centered.

---

## 8. Iconography (SF Symbols in use)

All icons are SF Symbols rendered through `Image(systemName:)` /
`Label(_, systemImage:)`. No custom icon assets.

| Symbol | Where |
|--------|-------|
| `doc.badge.plus` | Toolbar Open. |
| `wand.and.rays` | Toolbar Anonymize (primary). |
| `square.and.arrow.up` | Toolbar Export; Export Profile. |
| `square.and.arrow.down` | Import Profile. |
| `square.and.arrow.up.on.square` | Sharing tab item. |
| `tray.and.arrow.down` | Drop-zone hero icon. |
| `gearshape` | Sidebar footer Settings button; General/Settings tab item. |
| `text.book.closed` | Vocabulary tab item. |
| `brain` | Learned tab item; learned empty-state placeholder. |
| `text.badge.plus` | Vocabulary empty-state placeholder. |
| `plus` | Add Term. |
| `trash` | Forget All (destructive). |
| `xmark.circle.fill` | Learned-row forget action. |
| `exclamationmark.triangle.fill` | Invalid-regex warning (tinted `danger`). |

Convention: toolbar and tab icons pair with a text label (`Label`,
`.titleAndIcon` on the prominent toolbar buttons). Inline affordances
(forget, gear) are glyph-only and tinted `textSecondary`.

---

## 9. Rules and do-nots

Do:

- Reserve `inkAccent` for primary action, selection, focus, progress, the accept
  switch on-state, and the `auto-redact` learned badge. Nothing else.
- Use `CounselTheme.color(for:)` for every entity dot, underline, and sealed-
  token tint. Reuse the same hue across the row, the underline, and the chip for
  one type.
- Set document content and names in serif; chrome in system sans; tokens and
  aligned numbers in monospaced.
- Separate regions with a 1px `hairline` or a surface-tone change.
- Keep every new color a light/dark pair via `CounselTheme.dynamic(...)`.
- Dim rejected entities (`0.55`/`0.4`); keep them visible.
- Keep exactly one prominent ink button per context.

Do not:

- Use `inkAccent` as an entity color, a decorative fill, or a second accent.
- Use an entity hue as a button or interactive accent.
- Add drop shadows or blur as a depth cue; use hairlines and surface tone.
- Hardcode a single-appearance color or a raw hex outside `CounselTheme`.
- Introduce a fourth font family or a custom typeface.
- Let the document reading measure exceed `680`pt.
- Hide rejected entities, or let `danger` and the `phone` hue be used
  interchangeably (separate tokens, separate roles).
- Use the em-dash (`—`) or en-dash-as-separator (`–`) anywhere in UI strings.
