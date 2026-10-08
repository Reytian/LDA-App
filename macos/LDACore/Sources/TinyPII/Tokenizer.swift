import Foundation

/// One token: its id and its [start, end) in the original text, in Unicode scalars (Python str indices) and in
/// UTF-16 code units (Swift/NSString, as LDA uses).
public struct Token: Equatable {
    public let id: Int
    public let start: Int
    public let end: Int
    public let start16: Int
    public let end16: Int
}

/// The cjk-punct-v1 tokenizer of tiny-PII (XLM-R Unigram, HF tokenizers 0.22.2 pipeline):
/// added tokens, then Precompiled + Replace(\s+ -> " ") normalization, then Split(\s?[\p{P}\p{Han}], isolated)
/// and Metaspace(prepend first, split) pre-tokenization, then Unigram.
public final class Tokenizer {
    let precompiled: Precompiled
    public let tables: CharTables
    let unigram: Unigram
    let specials: [(id: Int, bytes: [UInt8])]
    static let metaspace: Unicode.Scalar = "\u{2581}"

    public init(assets: URL) throws {
        let dir = assets.appendingPathComponent("tokenizer")
        precompiled = try Precompiled(charsmap: Array(try readLocalFile(dir.appendingPathComponent("charsmap.bin"))))
        tables = try JSONDecoder().decode(CharTables.self, from: try readLocalFile(dir.appendingPathComponent("tables.json")))
        guard let vocab = try JSONSerialization.jsonObject(with: try readLocalFile(dir.appendingPathComponent("vocab.json"))) as? [String: Any],
              let unk = vocab["unk_id"] as? Int, let rows = vocab["pieces"] as? [[Any]], let specialRows = vocab["specials"] as? [[String: Any]]
        else { throw RuntimeError("vocab.json is malformed") }
        var pieces: [(String, Double)] = []
        pieces.reserveCapacity(rows.count)
        for row in rows {
            guard let piece = row[0] as? String, let score = (row[1] as? NSNumber)?.doubleValue else { throw RuntimeError("bad vocab row") }
            pieces.append((piece, score))
        }
        unigram = Unigram(pieces: pieces, unkId: unk)
        specials = specialRows.compactMap { row in
            guard let id = row["id"] as? Int, let content = row["content"] as? String else { return nil }
            return (id, Array(content.utf8))
        }
    }

    struct Split {
        var normalized: NormalizedString
        var tokens: [(Int, Range<Int>)]?
    }

    /// Leftmost-longest matches of the added (special) tokens, as `find_matches` pieces covering the string.
    func addedTokenPieces(_ bytes: [UInt8]) -> [(Range<Int>, Int?)] {
        if bytes.isEmpty { return [(0..<0, nil)] }
        var pieces: [(Range<Int>, Int?)] = []
        var gapStart = 0
        var i = 0
        while i < bytes.count {
            var best: (len: Int, id: Int)? = nil
            for special in specials where special.bytes.count <= bytes.count - i {
                if bytes[i..<(i + special.bytes.count)].elementsEqual(special.bytes), special.bytes.count > (best?.len ?? 0) {
                    best = (special.bytes.count, special.id)
                }
            }
            if let best = best {
                if gapStart < i { pieces.append((gapStart..<i, nil)) }
                pieces.append((i..<(i + best.len), best.id))
                i += best.len
                gapStart = i
            } else {
                i += 1
            }
        }
        if gapStart < bytes.count { pieces.append((gapStart..<bytes.count, nil)) }
        return pieces
    }

    /// Byte ranges of maximal `\s+` runs.
    func spaceRuns(_ s: NormalizedString) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var pos = 0
        var runStart: Int? = nil
        for (scalar, len) in UTF8Codec.scalars(s.normalized) {
            if tables.isRegexSpace(scalar) {
                if runStart == nil { runStart = pos }
            } else if let start = runStart {
                runs.append(start..<pos)
                runStart = nil
            }
            pos += len
        }
        if let start = runStart { runs.append(start..<pos) }
        return runs
    }

    /// `find_matches` of `\s?[\p{P}\p{Han}]` (Oniguruma, leftmost, non-overlapping).
    func splitMatches(_ s: NormalizedString) -> [(Range<Int>, Bool)] {
        if s.normalized.isEmpty { return [(0..<0, false)] }
        let scalars = UTF8Codec.scalars(s.normalized)
        var starts: [Int] = []
        var pos = 0
        for (_, len) in scalars { starts.append(pos); pos += len }
        starts.append(pos)
        var out: [(Range<Int>, Bool)] = []
        var prev = 0
        var i = 0
        while i < scalars.count {
            var matchEnd: Int? = nil
            if tables.isRegexSpace(scalars[i].0), i + 1 < scalars.count, tables.isHanOrPunct(scalars[i + 1].0) {
                matchEnd = i + 2
            } else if tables.isHanOrPunct(scalars[i].0) {
                matchEnd = i + 1
            }
            if let e = matchEnd {
                let start = starts[i], end = starts[e]
                if prev != start { out.append((prev..<start, false)) }
                out.append((start..<end, true))
                prev = end
                i = e
            } else {
                i += 1
            }
        }
        if prev != pos { out.append((prev..<pos, false)) }
        return out
    }

    /// `find_matches` for a single char pattern: each occurrence is its own match.
    func charMatches(_ s: NormalizedString, _ target: Unicode.Scalar) -> [(Range<Int>, Bool)] {
        if s.normalized.isEmpty { return [(0..<0, false)] }
        var out: [(Range<Int>, Bool)] = []
        var lastOffset = 0
        var pos = 0
        for (scalar, len) in UTF8Codec.scalars(s.normalized) {
            if scalar == target {
                if lastOffset < pos { out.append((lastOffset..<pos, false)) }
                out.append((pos..<(pos + len), true))
                lastOffset = pos + len
            }
            pos += len
        }
        if pos > lastOffset { out.append((lastOffset..<pos, false)) }
        return out
    }

    func metaspace(_ input: NormalizedString) -> [NormalizedString] {
        var s = input
        let spaces = charMatches(s, " ").filter { $0.1 }.map { $0.0 }
        if !spaces.isEmpty { s.replace(matches: spaces, with: "\u{2581}") }
        let startsWithMeta = s.normalized.starts(with: UTF8Codec.bytes(Tokenizer.metaspace))
        if !startsWithMeta && s.offsetsOriginal.0 == 0 { s.prepend("\u{2581}") }
        return s.split(charMatches(s, Tokenizer.metaspace), behavior: .mergedWithNext)
    }

    static func apply(_ splits: [Split], _ f: (NormalizedString) -> [NormalizedString]) -> [Split] {
        var out: [Split] = []
        for split in splits {
            if split.tokens != nil { out.append(split); continue }
            for piece in f(split.normalized) where !piece.isEmpty { out.append(Split(normalized: piece, tokens: nil)) }
        }
        return out
    }

    /// The normalized text of `text` (Precompiled, then Replace), for debugging parity.
    public func debugNormalize(_ text: String) -> (String, [(Int, Int)]) {
        var s = NormalizedString(text)
        precompiled.normalize(&s)
        let runs = spaceRuns(s)
        if !runs.isEmpty { s.replace(matches: runs, with: " ") }
        return (String(decoding: s.normalized, as: Unicode.UTF8.self), s.alignments)
    }

    /// Tokens of `text`, without special tokens, like `tokenizer(text, add_special_tokens=False,
    /// return_offsets_mapping=True)` in Python.
    public func encode(_ text: String) -> [Token] {
        let root = NormalizedString(text)
        // 1. added tokens on the raw text
        var splits: [Split] = []
        for (range, id) in addedTokenPieces(root.normalized) {
            guard let piece = root.slice(normalized: range), !piece.isEmpty else { continue }
            splits.append(Split(normalized: piece, tokens: id.map { [($0, 0..<piece.normalized.count)] }))
        }
        // 2. normalize the other pieces, then re-slice them whole (the empty normalized-token pass)
        splits = Tokenizer.apply(splits) { piece in
            var s = piece
            precompiled.normalize(&s)
            let runs = spaceRuns(s)
            if !runs.isEmpty { s.replace(matches: runs, with: " ") }
            if s.normalized.isEmpty { return s.slice(normalized: 0..<0).map { [$0] } ?? [] }
            return s.slice(normalized: 0..<s.normalized.count).map { [$0] } ?? []
        }
        // 3. pre-tokenize: Split (isolated), then Metaspace
        splits = Tokenizer.apply(splits) { $0.split(splitMatches($0), behavior: .isolated) }
        splits = Tokenizer.apply(splits) { metaspace($0) }
        // 4. model
        for k in splits.indices where splits[k].tokens == nil {
            splits[k].tokens = unigram.tokenize(splits[k].normalized.normalized)
        }
        // 5. offsets back to the original text
        let original = Array(text.utf8)
        var byteToScalar = [Int](repeating: -1, count: original.count + 1)
        var byteToUTF16 = [Int](repeating: -1, count: original.count + 1)
        var b = 0, sc = 0, u16 = 0
        while b < original.count {
            byteToScalar[b] = sc
            byteToUTF16[b] = u16
            let n = UTF8Codec.length(lead: original[b])
            b += n
            sc += 1
            u16 += n == 4 ? 2 : 1
        }
        byteToScalar[original.count] = sc
        byteToUTF16[original.count] = u16
        var out: [Token] = []
        for split in splits {
            let shift = split.normalized.offsetsOriginal.0
            for (id, range) in split.tokens ?? [] {
                var start = range.lowerBound, end = range.upperBound
                if let r = split.normalized.originalRange(normalized: range) {
                    start = shift + r.lowerBound
                    end = shift + r.upperBound
                }
                let cs = (0...original.count).contains(start) ? byteToScalar[start] : -1
                let ce = (0...original.count).contains(end) ? byteToScalar[end] : -1
                if cs >= 0 && ce >= 0 {
                    out.append(Token(id: id, start: cs, end: ce, start16: byteToUTF16[start], end16: byteToUTF16[end]))
                } else {
                    out.append(Token(id: id, start: start, end: end, start16: start, end16: end))
                }
            }
        }
        return out
    }
}

/// Reads a file from the local disk by path. URL-taking initializers such as
/// Data(contentsOf:) will also fetch a remote URL, which LDA's network audit
/// (NetworkChokepointTests) refuses outside the model installer; a path-based
/// read cannot reach the network.
func readLocalFile(_ url: URL) throws -> Data {
    guard url.isFileURL, let data = FileManager.default.contents(atPath: url.path) else {
        throw RuntimeError("cannot read \(url.lastPathComponent)")
    }
    return data
}
