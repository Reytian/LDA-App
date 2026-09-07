//
//  DocxDecodedXML.swift
//  LDACore
//
//  XML character data decoded ONCE, with a map from every UTF-16 unit of the
//  decoded text back to the raw units it came from.
//
//  Why. Several scrubs have to decide something about the text a consumer
//  reads, then edit the RAW bytes: a field instruction's HYPERLINK target, a
//  namespace name. Deciding on the raw bytes is wrong, because XML expands
//  character references and the five predefined entities before any consumer
//  sees the value. Review R3 measured the cost of the shortcut: an
//  instruction spelling its scheme "mail&#116;o:" carried a client address
//  straight through a scrub that was looking for "mailto:".
//
//  Decoding alone is not enough either. The edit has to land on the raw
//  bytes, so the decoded text needs an offset map, exactly the shape
//  PdfImporter.normalizeWhitespace uses for the same reason: decoded text
//  plus one original index per UTF-16 unit. Keeping the map per unit, not per
//  character, is what makes combining marks and surrogate pairs safe.
//
//  A character reference contributes ONE raw span to every unit it produced,
//  so a decoded range that touches any part of a reference maps to the whole
//  reference. A reference can never be half replaced, which is what a naive
//  "index of the next unit" map would allow.
//
//  Pure: no clock reads, no I/O.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Decoded XML text with offsets back into the raw text it came from.
struct DocxDecodedXML {

    /// The decoded text: character references and the five predefined
    /// entities expanded, everything else copied.
    let text: String

    /// UTF-16 length of the raw text `starts` and `ends` index.
    let rawLength: Int

    /// For each UTF-16 unit of `text`, the raw index its source starts at.
    /// INVARIANT: count == text.utf16.count.
    private let starts: [Int]

    /// For each UTF-16 unit of `text`, the raw index one past its source.
    /// INVARIANT: count == text.utf16.count.
    private let ends: [Int]

    private static let ampersand: UInt16 = 0x26 // "&"
    private static let semicolon: UInt16 = 0x3B // ";"

    /// The widest entity name this decoder will look at, counted in raw units
    /// after the "&". Mirrors the window the shared xmlDecode has always used.
    private static let entityNameLimit = 12

    // MARK: - Decoding

    /// Decode `raw`, building the offset map alongside it.
    static func decode(_ raw: String) -> DocxDecodedXML {
        let source = raw as NSString
        let length = source.length
        guard raw.contains("&") else {
            return DocxDecodedXML(
                text: raw,
                rawLength: length,
                starts: Array(0 ..< length),
                ends: Array(1 ..< length + 1)
            )
        }

        var units: [UInt16] = []
        var starts: [Int] = []
        var ends: [Int] = []
        units.reserveCapacity(length)

        var index = 0
        while index < length {
            let unit = source.character(at: index)
            guard unit == ampersand, let reference = reference(at: index, in: source) else {
                units.append(unit)
                starts.append(index)
                ends.append(index + 1)
                index += 1
                continue
            }
            let end = index + reference.width
            for produced in reference.units {
                units.append(produced)
                starts.append(index)
                ends.append(end)
            }
            index = end
        }

        return DocxDecodedXML(
            text: String(decoding: units, as: UTF16.self),
            rawLength: length,
            starts: starts,
            ends: ends
        )
    }

    /// One entity or character reference starting at `index`, or nil when the
    /// "&" begins nothing this decoder recognizes. An unrecognized spelling
    /// stays LITERAL, so no information is invented and none is lost.
    private static func reference(
        at index: Int,
        in source: NSString
    ) -> (units: [UInt16], width: Int)? {
        var cursor = index + 1
        while cursor < source.length,
              source.character(at: cursor) != semicolon,
              cursor - index <= entityNameLimit {
            cursor += 1
        }
        guard cursor < source.length, source.character(at: cursor) == semicolon else { return nil }

        let name = source.substring(with: NSRange(location: index + 1, length: cursor - index - 1))
        guard let replacement = replacement(for: name) else { return nil }
        return (Array(replacement.utf16), cursor + 1 - index)
    }

    /// The text one entity name stands for, or nil for a name this decoder
    /// leaves alone.
    private static func replacement(for name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: return characterReference(name)
        }
    }

    /// A numeric character reference, hexadecimal ("#x41") or decimal ("#65").
    private static func characterReference(_ name: String) -> String? {
        let code: UInt32?
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            code = UInt32(name.dropFirst(2), radix: 16)
        } else if name.hasPrefix("#") {
            code = UInt32(name.dropFirst())
        } else {
            return nil
        }
        guard let code, let scalar = Unicode.Scalar(code) else { return nil }
        return String(Character(scalar))
    }

    // MARK: - Projection

    /// The raw range covering `decoded`, so an edit decided on the decoded
    /// text can be applied to the raw bytes.
    ///
    /// An empty decoded range maps to an empty raw range at the same point,
    /// which is what an insertion means. A non-empty range always maps to the
    /// full raw span of every unit it covers.
    func rawRange(for decoded: NSRange) -> NSRange {
        guard decoded.length > 0 else {
            return NSRange(location: rawIndex(startingAt: decoded.location), length: 0)
        }
        let last = decoded.location + decoded.length - 1
        guard decoded.location < starts.count, last < ends.count else {
            return NSRange(location: rawLength, length: 0)
        }
        let start = starts[decoded.location]
        let end = ends[last]
        return NSRange(location: start, length: max(0, end - start))
    }

    private func rawIndex(startingAt decodedIndex: Int) -> Int {
        decodedIndex < starts.count ? starts[decodedIndex] : rawLength
    }
}
