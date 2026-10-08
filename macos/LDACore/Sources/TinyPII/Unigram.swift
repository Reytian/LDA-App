import Foundation

/// The Unigram model: a port of HF tokenizers 0.22.2 `Unigram::encode_optimized` and `Model::tokenize`
/// (fuse_unk on, no byte fallback). Candidates are visited in the same order as the Rust trie (shortest first),
/// so ties resolve the same way. Pieces are keyed by their UTF-8 bytes: Swift `String` equality and hashing
/// follow canonical equivalence (ハ+゚ == パ), which the byte-wise Rust trie does not.
public final class Unigram {
    public let pieces: [String]
    let scores: [Double]
    let ids: [[UInt8]: Int]
    let unkId: Int
    let unkScore: Double
    let maxPieceBytes: Int

    public init(pieces: [(String, Double)], unkId: Int) {
        self.pieces = pieces.map { $0.0 }
        self.scores = pieces.map { $0.1 }
        var ids: [[UInt8]: Int] = [:]
        ids.reserveCapacity(pieces.count)
        var maxBytes = 1
        var minScore = Double.infinity
        for (i, (piece, score)) in pieces.enumerated() {
            ids[Array(piece.utf8)] = i  // as in Rust, a later duplicate wins
            maxBytes = max(maxBytes, piece.utf8.count)
            if score < minScore { minScore = score }
        }
        self.ids = ids
        self.unkId = unkId
        self.unkScore = minScore - 10.0
        self.maxPieceBytes = maxBytes
    }

    /// Tokens of one pre-token as (id, byte range in `sentence`).
    public func tokenize(_ sentence: [UInt8]) -> [(Int, Range<Int>)] {
        let pieces = encode(sentence)
        var out: [(Int, Range<Int>)] = []
        var offset = 0
        for piece in pieces {
            let len = piece.count
            out.append((ids[piece] ?? unkId, offset..<(offset + len)))
            offset += len
        }
        return out
    }

    func encode(_ sentence: [UInt8]) -> [[UInt8]] {
        let size = sentence.count
        if size == 0 { return [] }
        var bestScore = [Double](repeating: 0, count: size + 1)
        var bestStart = [Int](repeating: -1, count: size + 1)
        var bestId = [Int](repeating: 0, count: size + 1)
        var startsAt = 0
        while startsAt < size {
            let till = bestScore[startsAt]
            var hasSingleNode = false
            let mblen = UTF8Codec.length(lead: sentence[startsAt])
            // Every vocabulary piece that is a prefix of sentence[startsAt...], shortest first (char boundaries only:
            // pieces are valid UTF-8, so no piece can end inside a char).
            var end = startsAt
            while end < size && end - startsAt < maxPieceBytes {
                end += UTF8Codec.length(lead: sentence[end])
                if end - startsAt > maxPieceBytes { break }
                guard let id = ids[Array(sentence[startsAt..<end])] else { continue }
                let candidate = scores[id] + till
                if bestStart[end] < 0 || candidate > bestScore[end] {
                    bestScore[end] = candidate
                    bestStart[end] = startsAt
                    bestId[end] = id
                }
                if !hasSingleNode && end - startsAt == mblen { hasSingleNode = true }
            }
            if !hasSingleNode {
                let target = startsAt + mblen
                let candidate = unkScore + till
                if bestStart[target] < 0 || candidate > bestScore[target] {
                    bestScore[target] = candidate
                    bestStart[target] = startsAt
                    bestId[target] = unkId
                }
            }
            startsAt += mblen
        }
        var results: [[UInt8]] = []
        var fused: [[UInt8]] = []
        var endsAt = size
        while endsAt > 0 {
            let start = bestStart[endsAt]
            let piece = Array(sentence[start..<endsAt])
            if bestId[endsAt] == unkId {
                fused.append(piece)
            } else {
                if !fused.isEmpty {
                    results.append(Array(fused.reversed().joined()))
                    fused = []
                }
                results.append(piece)
            }
            endsAt = start
        }
        if !fused.isEmpty { results.append(Array(fused.reversed().joined())) }
        return results.reversed()
    }
}
