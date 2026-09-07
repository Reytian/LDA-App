//
//  CJKSpacing.swift
//  LDACore
//
//  Repairs one specific surface drift seen in model output: spaces injected at
//  a CJK-to-ASCII script boundary, for example "...化工路口 98 号..." for a
//  source that reads "...化工路口98号...", "2027 年 3 月 18 日" for
//  "2027年3月18日", or "创新产业园 C 座" for "创新产业园C座".
//
//  The value is semantically correct, so recall scoring counts it as found, but
//  EntityLocator matches literally and never anchors it, which means the value
//  is never redacted. Tightening the reported value gives the literal locator a
//  second, exact needle to try. The locator itself stays a pure literal matcher,
//  so every span it returns is still a byte-identical slice of the source.
//
//  Only boundaries where one side is CJK are tightened. A space inside pure
//  ASCII text ("98 Main Street", "Alice Wong") is real and is preserved.
//
//  The boundary rule itself (isScriptBoundary) is shared with
//  EntityVariantPattern, where it makes the whitespace gap at a script boundary
//  optional, so EntityLocator anchors both the tight and the spaced surface in
//  one pass. tightenScriptBoundaries stays as the pure repair for a caller that
//  needs a tightened needle; fed through a literal locator it can only ever
//  succeed by finding a real occurrence in the source, never invent a span.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//
import Foundation

/// Pure string repair for CJK digit-boundary space drift. No IO, no clock.
public enum CJKSpacing {

    /// Space characters that a model may inject at a script boundary.
    private static let spaceScalars: Set<Unicode.Scalar> = [
        " ",             // U+0020 space
        "\u{00A0}",      // no-break space
        "\u{3000}"       // ideographic space
    ]

    /// True when the scalar is a CJK ideograph or CJK punctuation. U+3000 is
    /// excluded on purpose because it is handled as whitespace above.
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3001...0x303F,  // CJK symbols and punctuation
             0x3400...0x4DBF,  // CJK unified ideographs extension A
             0x4E00...0x9FFF:  // CJK unified ideographs
            return true
        default:
            return false
        }
    }

    /// True when the scalar is an ASCII digit or an ASCII letter. These are the
    /// characters a CJK legal document embeds inline: house numbers, floor
    /// numbers, building block letters and Latin company names.
    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
            return true
        default:
            return false
        }
    }

    /// True when a space run sitting between these two scalars is drift rather
    /// than real spacing: exactly one side is CJK and the other is ASCII
    /// alphanumeric. Internal so EntityVariantPattern applies the same rule.
    static func isScriptBoundary(_ before: Unicode.Scalar, _ after: Unicode.Scalar) -> Bool {
        return (isCJK(before) && isASCIIAlphanumeric(after))
            || (isASCIIAlphanumeric(before) && isCJK(after))
    }

    /// Remove every run of spaces that sits directly on a CJK-to-ASCII script
    /// boundary. All other spacing is preserved exactly.
    ///
    /// - Parameter s: the value as the model reported it.
    /// - Returns: the tightened value, or s unchanged when it carries no drift.
    public static func tightenScriptBoundaries(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { spaceScalars.contains($0) }) else {
            return s
        }

        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard spaceScalars.contains(scalar) else {
                out.append(scalar)
                index += 1
                continue
            }

            // Measure the whole space run, then decide once whether to drop it.
            var runEnd = index
            while runEnd < scalars.count, spaceScalars.contains(scalars[runEnd]) {
                runEnd += 1
            }

            let before = out.last
            let after = runEnd < scalars.count ? scalars[runEnd] : nil
            if let before, let after, isScriptBoundary(before, after) {
                index = runEnd
                continue
            }

            for offset in index..<runEnd {
                out.append(scalars[offset])
            }
            index = runEnd
        }

        return String(out)
    }

    /// True when the value carries CJK script-boundary space drift, meaning it
    /// cannot match its own source literally.
    public static func hasScriptBoundarySpacing(_ s: String) -> Bool {
        return tightenScriptBoundaries(s) != s
    }
}
