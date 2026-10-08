// The SentencePiece precompiled charsmap normalizer: a port of `spm_precompiled` (double-array trie) and of HF
// tokenizers 0.22.2 `normalizers/precompiled.rs`.

public struct Precompiled {
    let units: [UInt32]
    let normalizedBlob: [UInt8]

    public init(charsmap: [UInt8]) throws {
        guard charsmap.count >= 4 else { throw RuntimeError("charsmap too short") }
        let trieSize = Int(UInt32(charsmap[0]) | UInt32(charsmap[1]) << 8 | UInt32(charsmap[2]) << 16 | UInt32(charsmap[3]) << 24)
        let count = trieSize / 4
        guard charsmap.count >= 4 + trieSize else { throw RuntimeError("charsmap trie truncated") }
        var units = [UInt32](repeating: 0, count: count)
        for k in 0..<count {
            let b = 4 + 4 * k
            units[k] = UInt32(charsmap[b]) | UInt32(charsmap[b + 1]) << 8 | UInt32(charsmap[b + 2]) << 16 | UInt32(charsmap[b + 3]) << 24
        }
        self.units = units
        self.normalizedBlob = Array(charsmap[(4 + trieSize)...])
    }

    @inline(__always) private func hasLeaf(_ u: UInt64) -> Bool { (u >> 8) & 1 == 1 }
    @inline(__always) private func value(_ u: UInt64) -> Int { Int(u & ((1 << 31) - 1)) }
    @inline(__always) private func label(_ u: UInt64) -> UInt64 { u & ((1 << 31) | 0xFF) }
    @inline(__always) private func offset(_ u: UInt64) -> Int { Int((u >> 10) << ((u & (1 << 9)) >> 6)) }

    /// Values of every key that is a prefix of `key`, shortest first.
    func commonPrefixSearch<C: Collection>(_ key: C) -> [Int] where C.Element == UInt8 {
        var results: [Int] = []
        var nodePos = 0
        guard !units.isEmpty else { return results }
        var unit = UInt64(units[nodePos])
        nodePos ^= offset(unit)
        for c in key {
            if c == 0 { break }
            nodePos ^= Int(c)
            guard nodePos >= 0, nodePos < units.count else { return results }
            unit = UInt64(units[nodePos])
            if label(unit) != UInt64(c) { return results }
            nodePos ^= offset(unit)
            guard nodePos >= 0, nodePos < units.count else { return results }
            if hasLeaf(unit) { results.append(value(UInt64(units[nodePos]))) }
        }
        return results
    }

    /// `Precompiled::transform`: the replacement for the whole chunk, chosen by its shortest key prefix.
    func transform<C: Collection>(_ chunk: C) -> [Unicode.Scalar]? where C.Element == UInt8 {
        let results = commonPrefixSearch(chunk)
        guard let start = results.first else { return nil }
        var end = start
        while end < normalizedBlob.count && normalizedBlob[end] != 0 { end += 1 }
        return Array(String(decoding: normalizedBlob[start..<end], as: Unicode.UTF8.self).unicodeScalars)
    }

    private static func replace(_ transformations: inout [Transformation], oldCount: Int, new: [Unicode.Scalar]) {
        let diff = new.count - oldCount
        transformations.append(contentsOf: new.map { ($0, 0) })
        if diff > 0 {
            let n = transformations.count
            for k in max(0, n - diff)..<n { transformations[k].change = 1 }
        } else if diff < 0, !transformations.isEmpty {
            transformations[transformations.count - 1].change += diff
        }
    }

    /// `Normalizer::normalize` for Precompiled: grapheme by grapheme (Rust `graphemes(true)`).
    public func normalize(_ s: inout NormalizedString) {
        var transformations: [Transformation] = []
        transformations.reserveCapacity(s.normalized.count)
        var modified = false
        let text = String(decoding: s.normalized, as: Unicode.UTF8.self)
        for grapheme in text {
            let gBytes = Array(String(grapheme).utf8)
            let gScalars = Array(grapheme.unicodeScalars)
            if gBytes.count < 6, let norm = transform(gBytes) {
                modified = true
                Precompiled.replace(&transformations, oldCount: gScalars.count, new: norm)
                continue
            }
            for scalar in gScalars {
                let part = UTF8Codec.bytes(scalar)
                if let norm = transform(part) {
                    modified = true
                    Precompiled.replace(&transformations, oldCount: 1, new: norm)
                } else {
                    transformations.append((scalar, 0))
                }
            }
        }
        if modified { s.transform(transformations, initialOffset: 0) }
    }
}

public struct RuntimeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
