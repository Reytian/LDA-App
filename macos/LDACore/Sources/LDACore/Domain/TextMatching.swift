//
//  TextMatching.swift
//  LDACore
//
//  Shared text-comparison primitives used by the image-PII channel: the dedup
//  that separates image-origin OCR text from text-layer text, and the token-reuse
//  match that ties a re-detected surface back to an existing mapping token.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//
import Foundation

/// Pure text-comparison helpers. No IO, no clock.
public enum TextMatching {
    /// Lowercased, trimmed, internal whitespace collapsed to single spaces.
    public static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The set of "significant" words: alphanumeric-only, length >= 4, case-folded.
    /// Short words and punctuation are dropped so the overlap test is not fooled by
    /// stopwords, OCR-truncated word ends, or stray symbols.
    public static func significantWords(_ s: String) -> Set<String> {
        var words: Set<String> = []
        for raw in normalize(s).components(separatedBy: " ") {
            let alnum = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            if alnum.count >= 4 { words.insert(alnum) }
        }
        return words
    }

    /// True when the two strings share at least one significant word.
    public static func sharesSignificantWord(_ a: String, _ b: String) -> Bool {
        !significantWords(a).isDisjoint(with: significantWords(b))
    }
}
