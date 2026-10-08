import Foundation

/// Code-point classes probed from the regex engine HF tokenizers uses (export_runtime_assets.py): `\s`,
/// `[\p{P}\p{Han}]`, and Python's `str.isspace` (used when token offsets are trimmed).
public struct CharTables: Decodable {
    let space: [[UInt32]]
    let hanOrPunct: [[UInt32]]
    let pySpace: [[UInt32]]

    enum CodingKeys: String, CodingKey {
        case space
        case hanOrPunct = "han_or_punct"
        case pySpace = "py_space"
    }

    @inline(__always) private static func contains(_ ranges: [[UInt32]], _ v: UInt32) -> Bool {
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if v < ranges[mid][0] { hi = mid - 1 } else if v > ranges[mid][1] { lo = mid + 1 } else { return true }
        }
        return false
    }

    public func isRegexSpace(_ s: Unicode.Scalar) -> Bool { Self.contains(space, s.value) }
    public func isHanOrPunct(_ s: Unicode.Scalar) -> Bool { Self.contains(hanOrPunct, s.value) }
    public func isPythonSpace(_ s: Unicode.Scalar) -> Bool { Self.contains(pySpace, s.value) }
}
