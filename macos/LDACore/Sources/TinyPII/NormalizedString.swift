// A port of HF tokenizers 0.22.2 `NormalizedString` (tokenizers/src/tokenizer/normalizer.rs): the normalized text
// as UTF-8 bytes, and for every normalized byte the (start, end) byte range of the original it came from. Only the
// operations the cjk-punct-v1 pipeline uses are ported, with the same alignment rules, quirks included.

/// One Unicode scalar ("char" in Rust) with a change flag, as `transform` expects:
/// 0 replaces a char, 1 inserts a new one, -N replaces a char and removes the N chars after it.
public typealias Transformation = (scalar: Unicode.Scalar, change: Int)

enum UTF8Codec {
    @inline(__always) static func length(lead: UInt8) -> Int {
        if lead < 0x80 { return 1 }
        if lead < 0xE0 { return 2 }
        if lead < 0xF0 { return 3 }
        return 4
    }

    @inline(__always) static func bytes(_ scalar: Unicode.Scalar) -> [UInt8] {
        Array(String(Character(scalar)).utf8)
    }

    /// (scalar, byte length) for each scalar of valid UTF-8 bytes.
    static func scalars<C: Collection>(_ bytes: C) -> [(Unicode.Scalar, Int)] where C.Element == UInt8, C.Index == Int {
        var out: [(Unicode.Scalar, Int)] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let n = length(lead: bytes[i])
            var value: UInt32
            switch n {
            case 1: value = UInt32(bytes[i])
            case 2: value = (UInt32(bytes[i]) & 0x1F) << 6 | (UInt32(bytes[i + 1]) & 0x3F)
            case 3: value = (UInt32(bytes[i]) & 0x0F) << 12 | (UInt32(bytes[i + 1]) & 0x3F) << 6 | (UInt32(bytes[i + 2]) & 0x3F)
            default:
                value = (UInt32(bytes[i]) & 0x07) << 18 | (UInt32(bytes[i + 1]) & 0x3F) << 12
                    | (UInt32(bytes[i + 2]) & 0x3F) << 6 | (UInt32(bytes[i + 3]) & 0x3F)
            }
            out.append((Unicode.Scalar(value) ?? "\u{FFFD}", n))
            i += n
        }
        return out
    }
}

public struct NormalizedString {
    /// The original text of this (slice of the) string, UTF-8.
    public var original: [UInt8]
    /// The normalized text, UTF-8.
    public var normalized: [UInt8]
    /// For each normalized byte, its (start, end) in `original`.
    public var alignments: [(Int, Int)]
    /// Where `original` starts in the full original string (bytes).
    public var originalShift: Int

    public init(_ text: String) {
        let bytes = Array(text.utf8)
        original = bytes
        normalized = bytes
        alignments = []
        alignments.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let n = UTF8Codec.length(lead: bytes[i])
            for _ in 0..<n { alignments.append((i, i + n)) }
            i += n
        }
        originalShift = 0
    }

    init(original: [UInt8], normalized: [UInt8], alignments: [(Int, Int)], originalShift: Int) {
        self.original = original
        self.normalized = normalized
        self.alignments = alignments
        self.originalShift = originalShift
    }

    public var isEmpty: Bool { normalized.isEmpty }

    /// `offsets_original()`: this slice's place in the full original (bytes).
    public var offsetsOriginal: (Int, Int) { (originalShift, originalShift + original.count) }

    /// `convert_offsets(Range::Normalized(range))`.
    public func originalRange(normalized range: Range<Int>) -> Range<Int>? {
        if range.isEmpty { return range }
        if normalized.isEmpty && range == 0..<0 { return 0..<original.count }
        guard range.lowerBound >= 0, range.upperBound <= alignments.count else { return nil }
        return alignments[range.lowerBound].0..<alignments[range.upperBound - 1].1
    }

    /// `transform_range(Range::Normalized(range), dest, initial_offset)`.
    public mutating func transformRange(_ range: Range<Int>, _ dest: [Transformation], initialOffset: Int) {
        let replaced = UTF8Codec.scalars(normalized[range])
        var next = 0
        var initialRemoved = 0
        for _ in 0..<initialOffset where next < replaced.count {
            initialRemoved += replaced[next].1
            next += 1
        }
        var offset = initialRemoved + range.lowerBound
        var newAlignments: [(Int, Int)] = []
        var newBytes: [UInt8] = []
        newAlignments.reserveCapacity(range.count)
        newBytes.reserveCapacity(range.count)
        for (scalar, change) in dest {
            let idx = offset
            let align: (Int, Int)
            if change > 0 {
                align = idx < 1 ? (0, 0) : alignments[idx - 1]
            } else {
                align = alignments[idx]
            }
            var replacedSize = 0
            if change <= 0, next < replaced.count {
                replacedSize = replaced[next].1
                next += 1
            }
            var removedBytes = 0
            if change < 0 {
                for _ in 0..<(-change) where next < replaced.count {
                    removedBytes += replaced[next].1
                    next += 1
                }
            }
            offset += replacedSize + removedBytes
            let bytes = UTF8Codec.bytes(scalar)
            newBytes.append(contentsOf: bytes)
            for _ in 0..<bytes.count { newAlignments.append(align) }
        }
        alignments.replaceSubrange(range, with: newAlignments)
        normalized.replaceSubrange(range, with: newBytes)
    }

    /// `transform(dest, initial_offset)` over the whole string (`Range::Original(..)`).
    public mutating func transform(_ dest: [Transformation], initialOffset: Int) {
        // For the full original range, convert_offsets selects every normalized byte whose alignment is inside it,
        // which is all of them for the strings this pipeline transforms.
        transformRange(0..<normalized.count, dest, initialOffset: initialOffset)
    }

    /// `replace(pattern, content)`: every match is replaced by `content`, each new char aligned like the last
    /// byte of the match.
    public mutating func replace(matches: [Range<Int>], with content: String) {
        var newNormalized: [UInt8] = []
        var newAlignments: [(Int, Int)] = []
        newNormalized.reserveCapacity(normalized.count)
        newAlignments.reserveCapacity(alignments.count)
        var lastEnd = 0
        let contentScalars = Array(content.unicodeScalars)
        for match in matches {
            newNormalized.append(contentsOf: normalized[lastEnd..<match.lowerBound])
            newAlignments.append(contentsOf: alignments[lastEnd..<match.lowerBound])
            // All matched chars are removed up front (initial_offset = their count); content chars are inserted.
            let offset = match.upperBound
            for scalar in contentScalars {
                let align = offset < 1 ? (0, 0) : alignments[offset - 1]
                let bytes = UTF8Codec.bytes(scalar)
                newNormalized.append(contentsOf: bytes)
                for _ in 0..<bytes.count { newAlignments.append(align) }
            }
            lastEnd = match.upperBound
        }
        newNormalized.append(contentsOf: normalized[lastEnd...])
        newAlignments.append(contentsOf: alignments[lastEnd...])
        normalized = newNormalized
        alignments = newAlignments
    }

    /// `prepend(s)`.
    public mutating func prepend(_ s: String) {
        guard !normalized.isEmpty else { return }
        let first = UTF8Codec.scalars(normalized[0..<UTF8Codec.length(lead: normalized[0])])[0]
        var dest: [Transformation] = []
        for (i, scalar) in s.unicodeScalars.enumerated() { dest.append((scalar, i != 0 ? 1 : 0)) }
        dest.append((first.0, 1))
        transformRange(0..<first.1, dest, initialOffset: 0)
    }

    /// `slice(Range::Normalized(range))`.
    public func slice(normalized range: Range<Int>) -> NormalizedString? {
        guard let originalRange = originalRange(normalized: range) else { return nil }
        let shift = originalRange.lowerBound
        let sliceOriginal = (originalRange.lowerBound <= originalRange.upperBound && originalRange.upperBound <= original.count)
            ? Array(original[originalRange]) : []
        let sliceAlignments = alignments[range].map { ($0.0 - shift, $0.1 - shift) }
        return NormalizedString(original: sliceOriginal, normalized: Array(normalized[range]), alignments: sliceAlignments,
                                originalShift: originalShift + originalRange.lowerBound)
    }

    public enum SplitBehavior { case isolated, mergedWithNext }

    /// `split(pattern, behavior)` given the pattern's `find_matches` output (offsets cover the whole string).
    public func split(_ matches: [(Range<Int>, Bool)], behavior: SplitBehavior) -> [NormalizedString] {
        var pieces: [Range<Int>] = []
        switch behavior {
        case .isolated:
            pieces = matches.map { $0.0 }
        case .mergedWithNext:
            var previousMatch = false
            var acc: [Range<Int>] = []
            for (range, isMatch) in matches.reversed() {
                if isMatch && !previousMatch, let last = acc.last {
                    acc[acc.count - 1] = range.lowerBound..<last.upperBound
                } else {
                    acc.append(range)
                }
                previousMatch = isMatch
            }
            pieces = acc.reversed()
        }
        return pieces.compactMap { slice(normalized: $0) }
    }
}
