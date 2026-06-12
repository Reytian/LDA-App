# LDA.app Accessibility Audit (WCAG 2.1 AA, with 2.2 notes)

Audited surface: native macOS SwiftUI app "Legal Document Anonymizer" (Counsel direction).
Source reviewed:

- `macos/LDACore/Sources/LDAUI/CounselTheme.swift`
- `macos/LDACore/Sources/LDAUI/AppShell.swift`
- `macos/LDACore/Sources/LDAUI/DocumentPane.swift`
- `macos/LDACore/Sources/LDAUI/EntitySidebar.swift`
- `macos/LDACore/Sources/LDAUI/SettingsView.swift`

Contrast ratios were computed from the actual `CounselTheme.dynamic(light:dark:)` hex literals using the WCAG 2.x relative-luminance formula (sRGB, 8-bit). Alpha tints were alpha-composited over the stated surface before measuring. Both Light and Dark variants were evaluated.

Thresholds applied:

- Normal text: 4.5:1 (SC 1.4.3)
- Large text (>= ~18pt, or >= 14pt bold): 3:1 (SC 1.4.3)
- UI components and graphical objects: 3:1 (SC 1.4.11)

Note on the macOS context: the document body uses `.system(.body, design: .serif)`, which is normal-size text. Sidebar values are `.callout`, captions are `.caption2` / `.caption`. All of these are normal text for WCAG purposes, so the 4.5:1 threshold applies to them.

---

## A. Measured contrast table

### Light theme

| Pairing | Ratio | Threshold | Pass? |
|---|---|---|---|
| textPrimary `#2B2E33` on paper `#FCFBF9` | 13.17 | 4.5 | PASS |
| textPrimary on raised `#FFFFFF` | 13.62 | 4.5 | PASS |
| textSecondary `#71757C` on paper | 4.47 | 4.5 | **FAIL (marginal)** |
| textSecondary on appSurface `#F4F5F7` | 4.24 | 4.5 | **FAIL** |
| textSecondary on raised `#FFFFFF` | 4.63 | 4.5 | PASS |
| white on inkAccent `#3A4FA0` (prominent button text) | 7.48 | 4.5 | PASS |
| inkAccent text on paper | 7.24 | 4.5 | PASS |
| danger `#B05F5C` on raised | 4.53 | 4.5 | PASS |
| danger on paper | 4.38 | 4.5 | **FAIL (marginal)** |
| person `#4F62B0` underline/dot on paper | 5.48 | 3.0 | PASS |
| company `#3E8497` underline/dot on paper | 4.10 | 3.0 | PASS |
| address `#4E8C68` underline/dot on paper | 3.85 | 3.0 | PASS |
| email `#3F84B5` underline/dot on paper | 3.92 | 3.0 | PASS |
| id `#A07A2E` underline/dot on paper | 3.82 | 3.0 | PASS |
| amount `#9A5499` underline/dot on paper | 4.95 | 3.0 | PASS |
| phone `#B05F5C` underline/dot on paper | 4.38 | 3.0 | PASS |
| date `#8A8175` underline/dot on paper | 3.71 | 3.0 | PASS |
| date dot on appSurface | 3.51 | 3.0 | PASS |
| company text on paper (sealed/chip TEXT) | 4.10 | 4.5 | **FAIL** |
| address text on paper | 3.85 | 4.5 | **FAIL** |
| email text on paper | 3.92 | 4.5 | **FAIL** |
| id text on paper | 3.82 | 4.5 | **FAIL** |
| phone text on paper | 4.38 | 4.5 | **FAIL (marginal)** |
| date text on paper | 3.71 | 4.5 | **FAIL** |
| person text on paper | 5.48 | 4.5 | PASS |
| amount text on paper | 4.95 | 4.5 | PASS |
| Sidebar TokenChip text vs its 0.12 fill (on appSurface): person 4.42 / company 3.38 / address 3.20 / email 3.24 / id 3.17 / amount 4.04 / phone 3.60 / date 3.10 | see cells | 4.5 (text) | **FAIL for all 8** |
| Sealed in-document token text@0.95 vs sealed fill@0.20: person 3.72 / company 2.96 / address 2.82 / email 2.86 / id 2.82 / amount 3.47 / phone 3.13 / date 2.76 | see cells | 4.5 (text) | **FAIL for all 8** |

### Dark theme

| Pairing | Ratio | Threshold | Pass? |
|---|---|---|---|
| textPrimary `#E9EAED` on paper `#242529` | 12.73 | 4.5 | PASS |
| textSecondary `#9CA1A9` on paper | 5.89 | 4.5 | PASS |
| textSecondary on appSurface `#1B1C1F` | 6.56 | 4.5 | PASS |
| textSecondary on raised `#2E2F33` | 5.15 | 4.5 | PASS |
| white on inkAccent `#6E82DA` (prominent button text) | 3.58 | 4.5 | **FAIL** |
| inkAccent text on paper | 4.28 | 4.5 | **FAIL (marginal)** |
| inkAccent on appSurface | 4.76 | 4.5 | PASS |
| danger `#D98B88` on raised | 5.09 | 4.5 | PASS |
| danger on paper | 5.83 | 4.5 | PASS |
| All 8 entity hues as underline/dot on paper | 5.78 to 8.08 | 3.0 | PASS |
| All 8 entity hues as TEXT on paper | 5.78 to 8.08 | 4.5 | PASS |
| Sidebar TokenChip text vs fill | 5.32 to 7.05 | 4.5 | PASS |
| Sealed in-document token text vs sealed fill | 3.76 to 4.80 | 4.5 | person 3.76 **FAIL**, amount 4.01 **FAIL**, rest pass/marginal |

Dark theme text-on-surface is healthy. The dark failures are concentrated on (1) white-on-inkAccent button text and (2) the person/amount sealed in-document token.

---

## B. Findings

### F1 (Critical) Prominent button text fails contrast in Dark theme

- WCAG: 1.4.3 Contrast (Minimum)
- Severity: Critical
- Elements: every `.buttonStyle(.borderedProminent).tint(CounselTheme.inkAccent)` button. Anonymize and Export (`AppShell.swift` lines 88-89, 99 / 238-240), Choose File (`DocumentPane.swift` 88-89), Add Term (`SettingsView.swift` 218-219), Export Profile (`SettingsView.swift` 70-71), passphrase-sheet Export (`AppShell.swift` 239-240).
- Measured: white on inkAccent `#6E82DA` = **3.58:1** (Dark). Threshold for this normal-weight button text is 4.5:1.
- The same buttons pass in Light (7.48:1).
- Fix: darken the dark-mode ink accent used as a *filled button background* so white text clears 4.5:1. `#6E82DA` needs to drop to roughly `#5266C0` (approx 4.6:1 with white) or darker. Because `inkAccent` is also used as foreground ink (lines/selection) where a brighter value reads better on dark surfaces, split the token: keep `inkAccent` for foreground use and add `inkAccentFill` = `dynamic(light: 0x3A4FA0, dark: 0x4A5DB8)` for prominent button backgrounds, then tint the prominent buttons with `inkAccentFill`.

```swift
// CounselTheme.swift
public static let inkAccent     = dynamic(light: 0x3A4FA0, dark: 0x6E82DA) // foreground/selection
public static let inkAccentFill = dynamic(light: 0x3A4FA0, dark: 0x4A5DB8) // filled button bg (white text >= 4.5:1)
```

### F2 (Serious) Entity hue used AS TEXT fails contrast in Light theme (token chips and sealed tokens)

- WCAG: 1.4.3 Contrast (Minimum)
- Severity: Serious
- Elements:
  - `TokenChip` foreground text in the sidebar, `EntitySidebar.swift` line 301: `.foregroundStyle(CounselTheme.color(for: type))` over a `color.opacity(0.12)` fill (lines 304-307).
  - Sealed in-document token text, `DocumentPane.swift` lines 285-287: `foregroundColor = hue.opacity(0.95)` over `backgroundColor = hue.opacity(0.20)`.
- Measured (Light):
  - TokenChip text vs its own fill: person 4.42, company 3.38, address 3.20, email 3.24, id 3.17, amount 4.04, phone 3.60, date 3.10. All 8 below 4.5:1; six below 3.6:1.
  - Even ignoring the tint and measuring hue text directly on paper: company 4.10, address 3.85, email 3.92, id 3.82, phone 4.38, date 3.71. Six of eight below 4.5:1.
  - Sealed in-document token (text@0.95 over fill@0.20 over paper): person 3.72, company 2.96, address 2.82, email 2.86, id 2.82, amount 3.47, phone 3.13, date 2.76. All 8 below 4.5:1.
- Why it matters: the token (for example `[ADDRESS_1]`) is the load-bearing content a reviewing lawyer reads. Rendering it in the low-chroma hue as text is decorative styling that drops real text below the readable threshold. The hues are fine as the 3:1 *graphical* underline/dot (they pass), but not as text.
- Fix: do not color the token text in the entity hue. Render `TokenChip` and the sealed in-document token in `textPrimary` (13:1 on paper) and let the hue carry meaning through the fill and border only.

```swift
// EntitySidebar.swift TokenChip
Text(displayToken)
    .font(.caption2.monospaced())
    .foregroundStyle(CounselTheme.textPrimary) // was color(for: type)
    .background(Capsule().fill(CounselTheme.color(for: type).opacity(0.12)))
    .overlay(Capsule().strokeBorder(CounselTheme.color(for: type).opacity(0.5), lineWidth: 1))
```

```swift
// DocumentPane.swift apply(...) accepted branch
attributed[range].foregroundColor = CounselTheme.textPrimary // was hue.opacity(0.95)
attributed[range].backgroundColor = hue.opacity(Style.sealedFillOpacity)
```

### F3 (Serious) Secondary text fails contrast in Light theme on its real backgrounds

- WCAG: 1.4.3 Contrast (Minimum)
- Severity: Serious
- Element: `CounselTheme.textSecondary` `#71757C`, used pervasively for captions, source labels, counts, banner status text, and Settings body copy. Examples: `EntitySidebar.swift` captionLine (262) and SectionHeader (179, 183); `AppShell.swift` banner text (131, 144); `DocumentPane.swift` subtitle (78), placeholder (193); `SettingsView.swift` throughout.
- Measured (Light): textSecondary on paper = **4.47:1**; on appSurface = **4.24:1**. Both below 4.5:1. (On raised `#FFFFFF` it is 4.63, a pass.) The sidebar background is `appSurface` (`EntitySidebar.swift` line 64), so every caption and count in the sidebar sits at 4.24:1.
- These are normal-size text (`.caption2`, `.caption`, `.callout`), so 4.5:1 applies; 4.24 and 4.47 are genuine fails.
- Fix: darken the light variant of `textSecondary` to clear 4.5:1 on the darkest of its surfaces (appSurface). `#5F636B` gives approx 5.4:1 on appSurface and approx 5.6:1 on paper.

```swift
public static let textSecondary = dynamic(light: 0x5F636B, dark: 0x9CA1A9)
```

### F4 (Serious) Accept switch and mini toggles miss the 24x24 minimum target size

- WCAG: 2.5.8 Target Size (Minimum) (WCAG 2.2)
- Severity: Serious
- Elements:
  - The accept `Toggle(...).toggleStyle(.switch).controlSize(.mini)` in every entity row, `EntitySidebar.swift` lines 219-224. A `.mini` switch is roughly 18-20pt tall; there is no enlarged hit area and rows are tightly packed (`.padding(.vertical, 3)`).
  - The `.toggleStyle(.button)` regex and case toggles in `PatternRow` (`SettingsView.swift` 256-258, 266-268), labels `.*` and `Aa`, are small bordered buttons.
  - The Learned-tab forget button `xmark.circle.fill`, `SettingsView.swift` line 337, with no explicit frame; the SF Symbol glyph hit area is well under 24x24.
- WCAG 2.2 SC 2.5.8 requires at least 24x24 CSS px (or equivalent spacing) unless an exception applies. These are the primary review controls (accept is the core action of the whole app), so the small target is a real motor-accessibility barrier.
- Fix: give each control an explicit >= 24x24 (prefer 44x44 per Apple HIG) hit area without changing the visual size, via `.frame(minWidth: 44, minHeight: 28).contentShape(Rectangle())`, and raise the mini switch to at least `.controlSize(.small)`. For the forget button:

```swift
Button { onForget() } label: {
    Image(systemName: "xmark.circle.fill")
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
}
.accessibilityLabel(Text("Forget \(term.value)")) // see F6
```

### F5 (Serious) Sealed person/amount token fails contrast in Dark theme

- WCAG: 1.4.3 Contrast (Minimum)
- Severity: Serious
- Element: sealed in-document token, `DocumentPane.swift` 285-287 (Dark variant).
- Measured (Dark): person sealed text vs sealed fill = **3.76:1**, amount = **4.01:1** (both below 4.5:1); the other six are 4.25 to 4.80 (marginal pass). Adopting the F2 fix (render token text in `textPrimary`, 12.7:1 on dark paper) resolves this finding as well, so F2 and F5 share one fix.

### F6 (Serious) Missing VoiceOver labels on icon-only and structural controls

- WCAG: 4.1.2 Name, Role, Value; 1.1.1 Non-text Content
- Severity: Serious
- Elements with NO accessibility name:
  - Forget button, `SettingsView.swift` line 337: `Image(systemName: "xmark.circle.fill")` icon-only, no `.accessibilityLabel`. VoiceOver announces nothing meaningful. (`.help` is not an accessibility label.)
  - Regex toggle `.*` and case toggle `Aa`, `SettingsView.swift` 256, 266: glyph labels carry no semantic meaning to a screen reader; only a `.help` tooltip exists. Needs `.accessibilityLabel("Treat as regular expression")` and `.accessibilityLabel("Match letter case exactly")`.
  - The invalid-regex warning icon, `SettingsView.swift` 249-252, conveys an error state purely as an icon with a `.help`; add `.accessibilityLabel("Invalid regular expression")` so the error is exposed (also relevant to F8/1.4.1).
  - The drop zone, `DocumentPane.swift` lines 66-119: the whole intake target has a tap gesture and a drop destination but no accessibility label, role, or hint describing it as a file drop area. The `Choose File` button inside it is reachable, which is the AT alternative (good, see F7), but the zone itself is an unlabeled tap target.
  - The TokenChip and the occurrence-count `xN` pill (`EntitySidebar.swift` 241, 252) are decorative-looking but carry the assigned token; group them into the row label so VoiceOver reads the token with the row.
- Labels that ARE correctly set (good): Settings gear `EntitySidebar.swift` 86; accept toggle `EntitySidebar.swift` 224. The toolbar Open/Anonymize/Export use `Label(text, systemImage:)` so they carry a name.
- Fix: add `.accessibilityLabel(...)` to each icon-only control above; mark the drop zone with `.accessibilityElement(children: .combine)`, `.accessibilityLabel("Drop a document to anonymize")`, `.accessibilityAddTraits(.isButton)`, and `.accessibilityHint("Opens a file chooser")`.

### F7 (Pass, noted) Drag-and-drop has a keyboard/AT alternative

- WCAG: 2.1.1 Keyboard; 2.5.7 Dragging Movements (WCAG 2.2)
- Status: PASS. The `dropDestination` (`DocumentPane.swift` 115-119) is mirrored by the `Choose File` button (82-89) and the toolbar Open button (`AppShell.swift` 73-79), both keyboard-operable and opening an `NSOpenPanel`. No drag-only path exists. Keep this parity if the intake UI changes.

---

## C. Keyboard operability and focus

### F8 (Serious) Error and status are conveyed without a programmatic announcement

- WCAG: 4.1.3 Status Messages; 3.3.1 Error Identification
- Severity: Serious
- Elements: the status banner (`AppShell.swift` 120-148) and the Settings status line (`SettingsView.swift` 82-90) update text on import/detect/export/failure but are plain `Text`. A VoiceOver user gets no announcement when a run finishes, when export succeeds, or when an export/import fails. The invalid-regex state (F6) is icon-only.
- Fix: expose the banner string as a live region. On macOS SwiftUI use `.accessibilityLabel` on a representative element plus `NSAccessibility.post(element:notification:)` (or wrap an `NSAccessibilityElement`) when `bannerText`/`status` changes; at minimum annotate error text with `.accessibilityAddTraits(.isStaticText)` and post an announcement notification so completion/failure is spoken.

### Keyboard reachability (mostly Pass)

- Open, Anonymize, Export, Choose File, Add Term, Export/Import Profile, Forget, Forget All, and the accept switch are all standard focusable SwiftUI controls; they are reachable and operable by Tab/Space/Return and by Full Keyboard Access. The accept control being a `Toggle` (switch) is keyboard-togglable with Space. No keyboard trap was found.
- Gaps:
  - Sidebar `selection` (`EntitySidebar.swift` 31-38) is decorative only and does not move focus into the document or scroll the matching span into view, so there is no keyboard path to "jump to this entity in the text." Moderate (see F11).
  - Visible focus: the app relies entirely on the system focus ring. Counsel never suppresses it, which is correct, but verify the ink-accent selection tint (`rowBackground`, 0.10 opacity) is not mistaken for focus. The system ring satisfies 2.4.7; no custom non-visible focus styling was introduced. Pass.

---

## D. Reduce Motion, Dynamic Type, and remaining items

### F9 (Moderate) No `accessibilityReduceMotion` handling for progress and accept transitions

- WCAG: 2.3.3 Animation from Interactions (AAA, noted) and general motion hygiene
- Severity: Moderate
- Elements: the linear `ProgressView(value:)` in the banner (`AppShell.swift` 124-127) and the implicit opacity/animation on accept (rows change `opacity` 0.55 -> 1.0, `EntitySidebar.swift` 227; dot opacity 209). There is no `@Environment(\.accessibilityReduceMotion)` gate.
- The indeterminate spinners are system controls (acceptable). The concern is any implicit `withAnimation` on accept-state changes and the progress fill. Fix: read `accessibilityReduceMotion` and drop to a non-animated state change when it is on.

### F10 (Moderate) Dynamic Type is not validated; fixed frames risk clipping at large text sizes

- WCAG: 1.4.4 Resize Text; 1.4.10 Reflow
- Severity: Moderate
- Elements: many fixed `.frame` widths and heights that do not scale with text: Settings window `.frame(width: 580, height: 440)` (`SettingsView.swift` 40); picker `maxWidth: 320` (165); `PatternRow` field `minWidth: 170` and type picker `width: 140` (244-264); passphrase field `width: 320` (`AppShell.swift` 226); reading column `columnWidth: 680` (`DocumentPane.swift` 302). At the largest accessibility text sizes, `caption2` captions and the `xN` pill (`EntitySidebar.swift` 241-249) and dense rows can truncate or clip.
- The app uses semantic fonts (`.callout`, `.caption`, `.body`), which is good and means they respond to text-size settings. The risk is layout, not opting out of scaling.
- Fix: audit at the largest accessibility size; replace fixed-height containers with `minHeight`, let the Settings window be resizable, and verify the sidebar row does not clip the value/caption/token at AX5.

### F11 (Moderate) Color/shape-only meaning for accept state and entity type

- WCAG: 1.4.1 Use of Color; 1.3.3 Sensory Characteristics
- Severity: Moderate
- Elements:
  - Accept vs reject is signalled by row opacity (1.0 vs 0.55) and dot opacity (1.0 vs 0.4) plus the switch position (`EntitySidebar.swift` 207, 227). The switch carries an accessible value, which redeems it for AT, but the visual-only opacity cue is weak for low-vision users. The accept toggle's `.accessibilityLabel` ("Accept PERSON ...") does not announce the current on/off value distinctly from its name; rely on the switch trait, and consider an explicit "accepted"/"not accepted" in the label.
  - Entity type is carried by the hue dot and underline only. For color-blind users, the type name is present in the caption (good) and the section header (good), so type is not color-only. Pass on type; the accept-opacity cue is the residual concern.
- Fix: add a non-color accept indicator (a checkmark glyph or a filled vs outline dot) in addition to opacity, and include the accept state word in the toggle's accessibility value.

### F12 (Minor) Gear hit target below 24x24

- WCAG: 2.5.8 Target Size (Minimum) (WCAG 2.2)
- Severity: Minor (labelled, low-frequency, has menu equivalent Cmd+,)
- Element: Settings gear, `EntitySidebar.swift` 78-83, `.frame(width: 26, height: 22)`. Width passes 24 but height is 22, one point short, and `contentShape(Rectangle())` is already set. Fix: `.frame(width: 28, height: 28)`.

### F13 (Minor) inkAccent text is marginal on dark paper

- WCAG: 1.4.3
- Severity: Minor
- Element: inkAccent as foreground (selection tint base, the `tray.and.arrow.down` glyph at 0.85 opacity in `DocumentPane.swift` 68-70, and the auto-redact badge `SettingsView.swift` 349). Dark inkAccent on paper = 4.28:1 (marginal fail for normal text), on appSurface = 4.76 (pass). The drop glyph is large/decorative (the adjacent text carries the meaning), so this is minor, but if `inkAccent` is ever used for small normal text on dark paper it would fail. Splitting the token per F1 lets you keep a brighter foreground inkAccent; ensure any normal-size inkAccent text on dark paper uses a value >= 4.5:1.

---

## E. Priority summary

| ID | Severity | WCAG | One-line |
|---|---|---|---|
| F1 | Critical | 1.4.3 | White-on-inkAccent button text = 3.58:1 (Dark). Split into `inkAccentFill`. |
| F2 | Serious | 1.4.3 | Entity-hue token TEXT fails 4.5:1 in Light (3.10 to 4.42). Render token text in `textPrimary`. |
| F3 | Serious | 1.4.3 | `textSecondary` = 4.24 on appSurface / 4.47 on paper (Light). Darken to `#5F636B`. |
| F4 | Serious | 2.5.8 | Accept mini switch, regex/case toggles, forget button below 24x24. Enlarge hit areas. |
| F5 | Serious | 1.4.3 | Sealed person/amount token = 3.76 / 4.01 (Dark). Same fix as F2. |
| F6 | Serious | 4.1.2 / 1.1.1 | Forget button, regex/case toggles, invalid-regex icon, drop zone missing AX labels. |
| F8 | Serious | 4.1.3 / 3.3.1 | Status/error text not announced to VoiceOver. Add live-region announcements. |
| F9 | Moderate | 2.3.3 | No Reduce Motion handling for progress/accept. |
| F10 | Moderate | 1.4.4 / 1.4.10 | Dynamic Type not validated; fixed frames risk clipping. |
| F11 | Moderate | 1.4.1 / 1.3.3 | Accept state cued by opacity; add a non-color indicator. |
| F12 | Minor | 2.5.8 | Gear is 26x22; one point short. |
| F13 | Minor | 1.4.3 | inkAccent foreground marginal (4.28) on dark paper. |

All contrast numbers were computed directly from the `CounselTheme` hex literals; tinted values were alpha-composited over their stated surface first.
