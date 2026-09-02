//
//  DocumentTextStyler.swift
//  LDAUI
//
//  The pure styling layer behind the document pane: it turns the document
//  text plus the review entities (Original mode) or the tokenized preview text
//  (Safe Preview) into one NSAttributedString in the AppKit attribute scope,
//  which is what the NSTextView-backed pane renders. SwiftUI-scoped
//  AttributedString attributes do not survive conversion to NSAttributedString,
//  so everything here speaks AppKit directly.
//
//  Highlight treatment (see the scan-phase design spec, section 3):
//  - The underline carries the type hue in BOTH review states: thick solid for
//    a span that will be redacted, thick dashed for a span kept visible. A 1pt
//    hairline cannot show hue; a 0.10 to 0.20 fill cannot tell 16 hues apart.
//  - The fill carries state only: the hue at 0.18 behind text that will be
//    redacted, nothing behind text kept visible.
//  - Original mode keeps the body serif face. Safe Preview tokens take the
//    parsed type hue at 0.24 in the monospaced chip face.
//  - Every highlighted range carries a tooltip naming the type, the detection
//    source, and how often the value occurs in this document: the discoverable,
//    color-independent answer to "what is this highlight".
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import LDACore

/// The constants of the highlight treatment, shared with the tests.
enum DocumentHighlightStyle {
    /// Fill behind text that will be redacted. Composited on paper this keeps
    /// textPrimary above 8:1 in both appearances for every hue.
    static let acceptedFillOpacity: CGFloat = 0.18
    /// Kept-visible spans carry no fill: the open (dashed) underline is the
    /// state cue and the paper stays readable around a value that will ship.
    static let keptVisibleFillOpacity: CGFloat = 0.0
    /// Underline for spans that will be redacted: sealed, solid.
    static let acceptedUnderline: NSUnderlineStyle = [.thick]
    /// Underline for spans the user keeps visible: open, dashed.
    static let keptVisibleUnderline: NSUnderlineStyle = [.thick, .patternDash]
    /// Fill behind a Safe Preview token chip, in the token's type hue.
    static let tokenFillOpacity: CGFloat = 0.24
}

/// Pure builders for the pane's attributed text. No view state, no side
/// effects: text in, NSAttributedString out.
enum DocumentTextStyler {

    // MARK: - Reading typography

    /// Extra leading between wrapped lines of serif body text.
    static let lineSpacing: CGFloat = 6

    /// The serif reading face at the system body size (matches the SwiftUI
    /// `.system(.body, design: .serif)` the pane used before).
    static let bodyFont: NSFont = font(design: .serif)

    /// The monospaced chip face for Safe Preview tokens, at the body size.
    /// The dedicated constructor is used because the design-derived SF Mono
    /// descriptor does not report the fixed-pitch trait.
    static let monoFont: NSFont = NSFont.monospacedSystemFont(
        ofSize: bodyFont.pointSize,
        weight: .regular
    )

    /// The paragraph style of the reading column.
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    /// The attributes every character starts from.
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: CounselTheme.textPrimaryNSColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    // MARK: - Original mode

    /// The document text with every valid entity span highlighted. Spans that
    /// fall outside the text or split a composed character sequence are
    /// skipped rather than mis-styled.
    static func styledOriginal(text: String, entities: [ReviewEntity]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
        let nsText = text as NSString
        let occurrences = occurrenceCounts(entities)

        for entity in entities {
            guard let range = validRange(of: entity.span, in: nsText) else { continue }
            let hue = CounselTheme.entityNSColor(for: entity.span.type)
            if entity.accepted {
                result.addAttribute(
                    .backgroundColor,
                    value: CounselTheme.entityNSColor(
                        for: entity.span.type,
                        alpha: DocumentHighlightStyle.acceptedFillOpacity
                    ),
                    range: range
                )
                result.addAttribute(
                    .underlineStyle,
                    value: DocumentHighlightStyle.acceptedUnderline.rawValue,
                    range: range
                )
            } else {
                result.removeAttribute(.backgroundColor, range: range)
                result.addAttribute(
                    .underlineStyle,
                    value: DocumentHighlightStyle.keptVisibleUnderline.rawValue,
                    range: range
                )
            }
            result.addAttribute(.underlineColor, value: hue, range: range)
            result.addAttribute(
                .toolTip,
                value: tooltip(
                    type: entity.span.type,
                    source: entity.span.source,
                    occurrences: occurrences[occurrenceKey(entity.span.text)] ?? 1
                ),
                range: range
            )
        }
        return result
    }

    /// The tooltip for one highlighted range: type, source, and how many times
    /// the value occurs in this document.
    static func tooltip(type: EntityType, source: DetectionSource, occurrences: Int) -> String {
        String(
            format: L10n.string("%@ \u{00B7} %@ \u{00B7} %lld in this document"),
            EntityTypePresentation.localizedName(for: type) as NSString,
            EntityTypePresentation.sourceLabel(for: source) as NSString,
            Int64(occurrences)
        )
    }

    // MARK: - Safe Preview

    /// The tokenized preview text with every placeholder painted in its type
    /// hue and the monospaced chip face. Pseudonym and asterisk previews carry
    /// no placeholders and come back with the base attributes only.
    static func styledSafePreview(text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
        guard let regex = try? NSRegularExpression(pattern: TokenGrammar.placeholderPattern) else {
            return result
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let type = tokenType(forPlaceholder: nsText.substring(with: match.range))
            result.addAttribute(.font, value: monoFont, range: match.range)
            result.addAttribute(
                .backgroundColor,
                value: CounselTheme.entityNSColor(
                    for: type,
                    alpha: DocumentHighlightStyle.tokenFillOpacity
                ),
                range: match.range
            )
        }
        return result
    }

    /// The entity type a placeholder token stands for. The token TYPE is the
    /// sanitized wire type (NATIONAL_ID becomes NATIONALID), so the lookup
    /// goes through the same sanitizer instead of the raw value; anything the
    /// grammar cannot name falls back to the neutral kind.
    static func tokenType(forPlaceholder token: String) -> EntityType {
        var inner = token
        if inner.hasPrefix("{") { inner.removeFirst() }
        if inner.hasSuffix("}") { inner.removeLast() }
        guard let separator = inner.lastIndex(of: "_") else { return .unknown }
        let sanitized = TokenGrammar.sanitizeType(String(inner[..<separator]))
        return typeBySanitizedName[sanitized] ?? .unknown
    }

    private static let typeBySanitizedName: [String: EntityType] = {
        var table: [String: EntityType] = [:]
        for type in EntityType.allCases {
            table[TokenGrammar.sanitizeType(type.rawValue)] = type
        }
        return table
    }()

    // MARK: - Helpers

    /// The span's UTF-16 range when it lies inside the text and does not split
    /// a composed character sequence (a surrogate pair or a combining mark).
    private static func validRange(of span: Span, in text: NSString) -> NSRange? {
        guard span.start >= 0, span.end <= text.length, span.start < span.end else { return nil }
        let range = NSRange(location: span.start, length: span.end - span.start)
        guard text.rangeOfComposedCharacterSequences(for: range) == range else { return nil }
        return range
    }

    /// How often each value occurs, keyed like ReviewModel.groups(of:) so the
    /// tooltip count matches the sidebar row.
    private static func occurrenceCounts(_ entities: [ReviewEntity]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entity in entities {
            counts[occurrenceKey(entity.span.text), default: 0] += 1
        }
        return counts
    }

    private static func occurrenceKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The body-size font in a system design, falling back to the plain
    /// system font if the design is unavailable.
    private static func font(design: NSFontDescriptor.SystemDesign) -> NSFont {
        let descriptor = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body)
        guard let designed = descriptor.withDesign(design),
              let font = NSFont(descriptor: designed, size: 0) else {
            return NSFont.preferredFont(forTextStyle: .body)
        }
        return font
    }
}
