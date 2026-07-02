//
//  DefinedTermScanner.swift
//  LDACore
//
//  Collects the document's own quoted defined terms so the LLM entity filter
//  can drop them. Contracts define their terms of art inline:
//
//      Meridian Works, LLC (the "Company")
//      "Electronic Media Systems" means ...
//      (collectively, "Associated Third Parties")
//
//  The model routinely reports these defined terms as PERSON/COMPANY entities,
//  but they are document vocabulary, not identifying information. A static
//  denylist cannot enumerate them (every contract invents its own), so this
//  scanner reads them out of the document itself.
//
//  Alias safety (leak guard): a defined term that is derived from the real
//  name it abbreviates MUST stay redactable. In
//
//      Meridian Works, LLC ("Meridian Works")
//      International Business Machines ("IBM")
//
//  the terms "Meridian Works" and "IBM" are aliases of a real company and
//  dropping them would leak the name everywhere the alias is used. A term is
//  treated as an alias (and NOT droppable) when its words are a subset of the
//  words immediately preceding the definition, or when it is an acronym of
//  their initials, UNLESS that preceding phrase is itself boilerplate (for
//  example "Federal Arbitration Act ("FAA")", where the parent is a statute,
//  so the acronym is boilerplate too).
//
//  Residual risk, chosen deliberately: a contract that defines a term
//  containing the client's name WITHOUT the name appearing right before the
//  definition parenthetical would have that term dropped. This is rare in
//  practice, and the review UI surfaces every kept and dropped value for
//  one-click correction.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - DefinedTermScanner

/// Scans a document for quoted defined terms that are safe to drop from LLM
/// entity reports.
public enum DefinedTermScanner {

    /// Quote characters accepted around a defined term: straight and curly
    /// double quotes.
    private static let quoteClass = "[\"\u{201C}\u{201D}]"

    /// Lead-in words allowed between "(" and the opening quote.
    private static let leadInPattern =
        "(?:the|this|such|each|together|collectively|hereinafter|individually|a|an)?[,]?\\s*"

    /// Connector words ignored when comparing a value against the defined-term
    /// vocabulary. These never carry identity on their own.
    static let connectorWords: Set<String> = [
        "or", "and", "the", "a", "an", "of", "any", "all", "other", "such",
        "company", "companys"
    ]

    /// Collect the lowercased droppable defined terms in the text.
    ///
    /// Two definition shapes are recognized:
    /// - Parenthetical: `... (the "Term")`. Droppable unless the term is an
    ///   alias of a real name in the preceding text (see alias safety above).
    /// - Meaning clause: `"Term" means ...` / `"Term" shall mean ...`.
    ///   Always droppable: real-name aliases are not defined via "means".
    public static func droppableTerms(in text: String) -> Set<String> {
        let ns = text as NSString
        var terms: Set<String> = []

        // Parenthetical definitions.
        let parenPattern = "\\(\\s*" + leadInPattern + quoteClass + "([^\"\u{201C}\u{201D})]{2,70})" + quoteClass
        if let regex = try? NSRegularExpression(pattern: parenPattern, options: [.caseInsensitive]) {
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let termRange = match.range(at: 1)
                let term = ns.substring(with: termRange)
                let windowStart = max(0, match.range.location - 90)
                let preceding = ns.substring(
                    with: NSRange(location: windowStart, length: match.range.location - windowStart)
                )
                if isDroppable(term: term, preceding: preceding) {
                    terms.insert(normalize(term))
                }
            }
        }

        // Meaning-clause definitions.
        let meansPattern = quoteClass + "([^\"\u{201C}\u{201D}]{2,70})" + quoteClass + "\\s*(?:means|shall mean)"
        if let regex = try? NSRegularExpression(pattern: meansPattern, options: [.caseInsensitive]) {
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                terms.insert(normalize(ns.substring(with: match.range(at: 1))))
            }
        }

        return terms
    }

    /// True when an LLM-reported value is covered by the document's droppable
    /// defined-term vocabulary: either it equals a droppable term, or every
    /// significant word of it appears in the union of the droppable terms'
    /// words plus connector words. The union test catches the model's
    /// recombinations of defined terms ("Electronic Media Equipment or Company
    /// Electronic Media Systems") and sub-phrases ("Electronic Media Systems"
    /// out of the defined "Company Electronic Media Systems").
    public static func covers(_ value: String, terms: Set<String>) -> Bool {
        guard !terms.isEmpty else { return false }
        let normalized = normalize(value)
        if terms.contains(normalized) {
            return true
        }

        let valueWords = words(of: normalized)
        guard !valueWords.isEmpty else { return false }
        var vocabulary = Set<String>()
        for term in terms {
            vocabulary.formUnion(words(of: term))
        }
        vocabulary.formUnion(connectorWords)
        return valueWords.allSatisfy { vocabulary.contains($0) }
    }

    // MARK: - Alias detection

    /// Decide whether a parenthetically defined term is droppable. Alias terms
    /// (word subset or acronym of the immediately preceding phrase) stay
    /// redactable UNLESS the preceding phrase is itself boilerplate.
    private static func isDroppable(term: String, preceding: String) -> Bool {
        let termWords = words(of: normalize(term))
        guard !termWords.isEmpty else { return true }

        // Case-preserved words of the preceding text: the boilerplate check
        // below MUST see original casing, because LegalBoilerplate treats an
        // all-lowercase phrase as generic and would wrongly flag a real name.
        let precedingOriginal = casePreservingWords(of: preceding)
        let precedingLower = precedingOriginal.map { $0.lowercased() }
        let precedingSet = Set(precedingLower)

        let significant = termWords.filter { !connectorWords.contains($0) }
        let isWordSubset = !significant.isEmpty && significant.allSatisfy { precedingSet.contains($0) }
        let isAcronymAlias = isAcronym(termWords: termWords, of: precedingLower)

        guard isWordSubset || isAcronymAlias else {
            // Not derived from the preceding text: a generic defined term.
            return true
        }

        // Alias of the preceding phrase. Droppable only when that phrase is
        // itself boilerplate (statute, agency, generic term), in which case the
        // alias carries no identity either. Testing the tail windows of the
        // preceding phrase (original casing) approximates the canonical name,
        // which sits right before the "(" (e.g. "... Federal Arbitration Act (").
        let tail = Array(precedingOriginal.suffix(6))
        guard !tail.isEmpty else { return true }
        let minWindow = min(max(1, significant.count), tail.count)
        for windowSize in minWindow...tail.count {
            let phrase = tail.suffix(windowSize).joined(separator: " ")
            if LegalBoilerplate.shouldDrop(phrase, type: .company) {
                return true
            }
        }
        return false
    }

    /// True when the single-word term is an acronym of the trailing significant
    /// words before the definition ("FAA" from "Federal Arbitration Act").
    private static func isAcronym(termWords: [String], of precedingLower: [String]) -> Bool {
        guard termWords.count == 1, let acronym = termWords.first, acronym.count >= 2 else {
            return false
        }
        let letters = Array(acronym)
        let candidates = precedingLower.filter { !connectorWords.contains($0) }
        guard candidates.count >= letters.count else { return false }
        let tail = candidates.suffix(letters.count)
        for (letter, word) in zip(letters, tail) {
            guard let initial = word.first, initial == letter else { return false }
        }
        return true
    }

    // MARK: - Normalization

    /// Lowercase and strip a leading article so "the Company" and "Company"
    /// normalize identically.
    private static func normalize(_ s: String) -> String {
        var lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for article in ["the ", "an ", "a "] where lower.hasPrefix(article) {
            lower = String(lower.dropFirst(article.count))
            break
        }
        return lower
    }

    /// Letters-only words (digits and punctuation split and drop, so a page
    /// number artifact inside a PDF-extracted term does not break matching).
    private static func words(of s: String) -> [String] {
        return s.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Letters-only words with original casing preserved, for boilerplate
    /// checks that are casing-sensitive.
    private static func casePreservingWords(of s: String) -> [String] {
        return s
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
