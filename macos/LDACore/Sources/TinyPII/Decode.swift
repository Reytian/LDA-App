import Foundation

// Windows and decoding: ports of datagen.align (unlabelled windows) and datagen.decode (BIOES Viterbi, spans,
// window merge), with the same arithmetic order so results match the Python reference bit for bit.

public struct Window {
    public let inputIds: [Int32]
    /// Code-point offsets per input position; special and whitespace-only tokens are empty.
    public let offsets: [(Int, Int)]
    public let index: Int
    public let isLast: Bool
}

public struct Span: Equatable {
    public let start: Int
    public let end: Int
    public let label: String
    public let score: Double
}

/// CPython 3.12+ `sum()` of floats (Neumaier compensation), so span scores equal Python's mean exactly.
@inline(__always) func pythonSum(_ xs: [Double]) -> Double {
    guard let first = xs.first else { return 0 }
    var f = 0.0 + first
    var c = 0.0
    for x in xs.dropFirst() {
        let t = f + x
        if abs(f) >= abs(x) { c += (f - t) + x } else { c += (x - t) + f }
        f = t
    }
    if c != 0 && c.isFinite { f += c }
    return f
}

public struct Decoder {
    public let labelNames: [String]
    let prefixes: [Character]
    let kinds: [String?]
    let startOK: [Bool]
    let endOK: [Bool]
    let predecessors: [[Int]]

    public init(labelNames: [String]) {
        self.labelNames = labelNames
        prefixes = labelNames.map { $0 == "O" ? "O" : $0.first! }
        kinds = labelNames.map { $0 == "O" ? nil : String($0.dropFirst(2)) }
        func allowed(_ prev: Int?, _ cur: Int, prefixes: [Character], kinds: [String?]) -> Bool {
            let cp = prefixes[cur]
            guard let p = prev else { return cp == "O" || cp == "B" || cp == "S" }
            if prefixes[p] == "B" || prefixes[p] == "I" { return (cp == "I" || cp == "E") && kinds[cur] == kinds[p] }
            return cp == "O" || cp == "B" || cp == "S"
        }
        let n = labelNames.count
        let pf = prefixes, kd = kinds
        startOK = (0..<n).map { allowed(nil, $0, prefixes: pf, kinds: kd) }
        endOK = (0..<n).map { pf[$0] == "O" || pf[$0] == "E" || pf[$0] == "S" }
        predecessors = (0..<n).map { cur in (0..<n).filter { allowed($0, cur, prefixes: pf, kinds: kd) } }
    }

    /// Log-softmax of one token's logits in float64, labels in index order (as coreml_predict.py).
    @inline(__always) public static func logSoftmax(_ row: [Float]) -> [Double] {
        let values = row.map { Double($0) }
        var m = values[0]
        for v in values.dropFirst() where v > m { m = v }
        var s = 0.0
        for v in values { s += exp(v - m) }
        let lse = m + log(s)
        return values.map { $0 - lse }
    }

    /// `viterbi_bioes`: ties go to the lowest label index.
    public func viterbi(_ rows: [[Double]]) -> [Int] {
        guard !rows.isEmpty else { return [] }
        let width = labelNames.count
        var score = (0..<width).map { startOK[$0] ? rows[0][$0] : -Double.infinity }
        var backpointers: [[Int]] = []
        for row in rows.dropFirst() {
            var newScore = [Double](repeating: -Double.infinity, count: width)
            var pointer = [Int](repeating: 0, count: width)
            for j in 0..<width {
                var best = -Double.infinity, arg = -1
                for i in predecessors[j] where score[i] > best { best = score[i]; arg = i }
                if arg >= 0 { newScore[j] = best + row[j]; pointer[j] = arg }
            }
            backpointers.append(pointer)
            score = newScore
        }
        var best = -Double.infinity, last = -1
        for j in 0..<width where endOK[j] && score[j] > best { best = score[j]; last = j }
        guard last >= 0 else { return [] }
        var path = [last]
        for pointer in backpointers.reversed() { path.append(pointer[path[path.count - 1]]) }
        return path.reversed()
    }

    struct RawSpan { var start: Int; var end: Int; var label: String; var probs: [Double]; var edge: Bool = false }

    /// `token_labels_to_spans` + `window_to_spans` (edge flags).
    func windowSpans(tags: [Int], offsets: [(Int, Int)], probs: [Double], atDocStart: Bool, atDocEnd: Bool) -> [(Span, Bool)] {
        var spans: [RawSpan] = []
        var current: RawSpan? = nil
        func close() {
            if let c = current { spans.append(c); current = nil }
        }
        for (k, tag) in tags.enumerated() {
            let (start, end) = offsets[k]
            if end <= start { continue }
            let prefix = prefixes[tag]
            if prefix == "O" { close(); continue }
            let kind = kinds[tag]!
            if prefix == "B" || prefix == "S" || current == nil || current!.label != kind {
                close()
                current = RawSpan(start: start, end: end, label: kind, probs: [probs[k]])
            } else {
                current!.start = min(current!.start, start)
                current!.end = max(current!.end, end)
                current!.probs.append(probs[k])
            }
            if prefix == "E" || prefix == "S" { close() }
        }
        close()
        let content = offsets.filter { $0.1 > $0.0 }
        var out: [(Span, Bool)] = []
        for s in spans {
            var edge = false
            if let first = content.first {
                let firstStart = first.0
                let lastEnd = content.map { $0.1 }.max()!
                edge = (!atDocStart && s.start <= firstStart) || (!atDocEnd && s.end >= lastEnd)
            }
            out.append((Span(start: s.start, end: s.end, label: s.label, score: pythonSum(s.probs) / Double(s.probs.count)), edge))
        }
        return out
    }

    /// `merge_window_predictions`: exact duplicates collapse (higher score kept, cut only if every copy was cut);
    /// overlaps resolve greedily by (uncut first, higher score, longer, earlier).
    func merge(_ windows: [[(Span, Bool)]]) -> [Span] {
        struct Key: Hashable { let start: Int; let end: Int; let label: String }
        var cut: [Key: Bool] = [:]
        var best: [Key: Span] = [:]
        for window in windows {
            for (span, edge) in window {
                let key = Key(start: span.start, end: span.end, label: span.label)
                cut[key] = (cut[key] ?? true) && edge
                if let old = best[key] {
                    if span.score > old.score { best[key] = span }
                } else {
                    best[key] = span
                }
            }
        }
        let unique = best.values.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return a.label.unicodeScalars.lexicographicallyPrecedes(b.label.unicodeScalars)
        }
        let ordered = unique.sorted { a, b in
            let ca = cut[Key(start: a.start, end: a.end, label: a.label)]!, cb = cut[Key(start: b.start, end: b.end, label: b.label)]!
            if ca != cb { return !ca }
            if a.score != b.score { return -a.score < -b.score }
            if (a.start - a.end) != (b.start - b.end) { return (a.start - a.end) < (b.start - b.end) }
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return a.label.unicodeScalars.lexicographicallyPrecedes(b.label.unicodeScalars)
        }
        var accepted: [Span] = []
        for span in ordered where accepted.allSatisfy({ span.end <= $0.start || $0.end <= span.start }) {
            accepted.append(span)
        }
        return accepted.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return a.label.unicodeScalars.lexicographicallyPrecedes(b.label.unicodeScalars)
        }
    }
}

/// Unlabelled windows as `datagen.align.align_record` builds them: [CLS] + up to max_length - 2 tokens + [SEP],
/// stepping by capacity - stride, token offsets trimmed of Python whitespace.
public func makeWindows(tokens: [Token], text: String, tables: CharTables, maxLength: Int, stride: Int,
                        cls: Int, sep: Int) -> [Window] {
    let scalars = Array(text.unicodeScalars)
    let trimmed: [(Int, Int)] = tokens.map { t in
        var a = t.start, b = t.end
        while a < b && tables.isPythonSpace(scalars[a]) { a += 1 }
        while b > a && tables.isPythonSpace(scalars[b - 1]) { b -= 1 }
        return (a, b)
    }
    let capacity = maxLength - 2
    var ranges: [(Int, Int)] = []
    if tokens.isEmpty {
        ranges = [(0, 0)]
    } else {
        var start = 0
        while start < tokens.count {
            let end = min(tokens.count, start + capacity)
            ranges.append((start, end))
            if end == tokens.count { break }
            var next = max(start + 1, end - stride)
            if next <= start || next >= end { next = end }
            start = next
        }
    }
    return ranges.enumerated().map { (k, r) in
        var ids: [Int32] = [Int32(cls)]
        var offsets: [(Int, Int)] = [(0, 0)]
        for i in r.0..<r.1 {
            ids.append(Int32(tokens[i].id))
            offsets.append(trimmed[i])
        }
        ids.append(Int32(sep))
        offsets.append((0, 0))
        return Window(inputIds: ids, offsets: offsets, index: k, isLast: k == ranges.count - 1)
    }
}
