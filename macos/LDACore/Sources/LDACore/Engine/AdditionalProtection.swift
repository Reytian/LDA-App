import Foundation
import CryptoKit

/// Local manual choices can expand protection, but cannot shrink an existing finding.
public enum AdditionalProtection {
    public enum ReviewError: Error { case documentChangedSinceReview }

    public static func textDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func merge(text: String, detected: [Span], patterns: [CustomPattern]) -> [Span] {
        guard !patterns.isEmpty else { return detected }
        let source = text as NSString
        let combined = (detected + CustomPatternEngine.detect(text, patterns: patterns)).sorted {
            $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start
        }
        var result: [Span] = []
        for span in combined {
            guard span.start >= 0, span.end > span.start, span.end <= source.length else { continue }
            if var previous = result.last, span.start < previous.end {
                result.removeLast()
                previous.end = max(previous.end, span.end)
                previous.text = source.substring(with: NSRange(location: previous.start, length: previous.end - previous.start))
                if span.source == .manual { previous.type = span.type }
                previous.source = .manual
                previous.priority = max(previous.priority, span.priority)
                result.append(previous)
            } else { result.append(span) }
        }
        return result
    }
}
