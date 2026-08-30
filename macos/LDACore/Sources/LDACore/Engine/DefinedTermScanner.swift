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

// MARK: - AliasBinding

/// A short-name definition found in the document: the alias surface exactly as
/// written (quotes stripped), plus the UTF-16 offset of the opening parenthesis
/// of the defining parenthetical. The offset is the anchor the pipeline uses to
/// bind the alias to the detected entity span that immediately precedes the
/// definition ("Full Company Name (hereinafter the short name)").
public struct AliasBinding: Equatable, Sendable {
    /// The alias surface exactly as written in the document, without quotes.
    public let alias: String
    /// UTF-16 offset of the opening parenthesis of the definition.
    public let anchorOffset: Int

    public init(alias: String, anchorOffset: Int) {
        self.alias = alias
        self.anchorOffset = anchorOffset
    }
}

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
        enumerateParentheticalDefinitions(in: text) { term, _, preceding in
            if isDroppable(term: term, preceding: preceding) {
                terms.insert(normalize(term))
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

    // MARK: - Alias bindings

    /// Lead-in phrases that mark a CJK short-name definition parenthetical:
    /// （以下简称"X"）, （下称"X"）, (以下简称X), and close variants. Longer
    /// alternatives come first so the regex matches greedily.
    private static let cjkAliasLeadIn =
        "(?:以下简称|以下合称|以下统称|以下称|下称|简称|合称|统称)"

    /// Quote characters stripped from an alias term: straight and curly double
    /// and single quotes plus CJK corner brackets.
    private static let aliasQuoteCharacters = CharacterSet(
        charactersIn: "\"\u{201C}\u{201D}'\u{2018}\u{2019}\u{300C}\u{300D}\u{300E}\u{300F}"
    )

    /// Collect the document's short-name definitions.
    ///
    /// Two definition families are recognized:
    /// - CJK lead-in parentheticals: （以下简称"X"）, （下称"X"）, (以下简称X),
    ///   with fullwidth or halfwidth parentheses, straight or curly quotes or
    ///   none, an optional 为 and colon after the lead-in, and several quoted
    ///   aliases in one parenthetical (each is emitted with the same anchor).
    /// - Quoted parentheticals in the droppableTerms shape whose term is a
    ///   real-name alias of the immediately preceding text ("Meridian Works",
    ///   "IBM", or a CJK substring of the preceding name). Generic defined
    ///   terms stay out: they are vocabulary, not identity.
    ///
    /// The returned aliases are raw document surfaces. Deciding whether an
    /// alias is safe to rescan (role labels, boilerplate, length thresholds,
    /// binding to a detected entity) is the caller's job (see EntityRescan).
    public static func aliasBindings(in text: String) -> [AliasBinding] {
        let ns = text as NSString
        var bindings: [AliasBinding] = []
        var seen = Set<SeenBinding>()

        // CJK lead-in parentheticals.
        let cjkPattern = "[\u{FF08}(]\\s*" + cjkAliasLeadIn
            + "\u{4E3A}?\\s*[:\u{FF1A}]?\\s*([^\u{FF08}()\u{FF09}]{1,80}?)\\s*[)\u{FF09}]"
        if let regex = try? NSRegularExpression(pattern: cjkPattern) {
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let interior = ns.substring(with: match.range(at: 1))
                for alias in aliasTerms(inInterior: interior) {
                    let binding = AliasBinding(alias: alias, anchorOffset: match.range.location)
                    if seen.insert(SeenBinding(binding)).inserted {
                        bindings.append(binding)
                    }
                }
            }
        }

        // Quoted parentheticals whose term is a real-name alias.
        enumerateParentheticalDefinitions(in: text) { term, anchorOffset, preceding in
            guard !isDroppable(term: term, preceding: preceding) else { return }
            let binding = AliasBinding(
                alias: term.trimmingCharacters(in: .whitespacesAndNewlines),
                anchorOffset: anchorOffset
            )
            guard !binding.alias.isEmpty else { return }
            if seen.insert(SeenBinding(binding)).inserted {
                bindings.append(binding)
            }
        }

        return bindings.sorted { lhs, rhs in
            if lhs.anchorOffset != rhs.anchorOffset {
                return lhs.anchorOffset < rhs.anchorOffset
            }
            return lhs.alias < rhs.alias
        }
    }

    /// Dedup key for alias bindings (same alias at the same anchor can be found
    /// by both the CJK pattern and the quoted-parenthetical pattern).
    private struct SeenBinding: Hashable {
        let alias: String
        let anchorOffset: Int
        init(_ binding: AliasBinding) {
            self.alias = binding.alias
            self.anchorOffset = binding.anchorOffset
        }
    }

    /// Split a CJK definition parenthetical interior into individual alias
    /// terms. When the interior carries quotes, each quoted run is one term
    /// (connectors such as 或 between quoted runs are skipped naturally).
    /// Without quotes the whole interior is a single term: splitting an
    /// unquoted CJK name on connector characters would shred real names that
    /// contain them (for example 和记).
    private static func aliasTerms(inInterior interior: String) -> [String] {
        let ns = interior as NSString
        let quotedPattern = "[\"\u{201C}\u{201D}'\u{2018}\u{2019}\u{300C}\u{300E}]"
            + "([^\"\u{201C}\u{201D}'\u{2018}\u{2019}\u{300C}\u{300D}\u{300E}\u{300F}]{1,60})"
            + "[\"\u{201C}\u{201D}'\u{2018}\u{2019}\u{300D}\u{300F}]"
        if interior.rangeOfCharacter(from: aliasQuoteCharacters) != nil,
           let regex = try? NSRegularExpression(pattern: quotedPattern) {
            var terms: [String] = []
            regex.enumerateMatches(in: interior, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let term = ns.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !term.isEmpty {
                    terms.append(term)
                }
            }
            return terms
        }

        let bare = interior.trimmingCharacters(in: .whitespacesAndNewlines)
        return bare.isEmpty ? [] : [bare]
    }

    /// Enumerate every quoted parenthetical definition (`... (the "Term")`),
    /// handing the handler the raw term, the UTF-16 offset of the opening
    /// parenthesis, and the up-to-90-code-unit window of preceding text used
    /// for alias classification. Shared by droppableTerms and aliasBindings so
    /// the two views of the same definition never drift.
    private static func enumerateParentheticalDefinitions(
        in text: String,
        handler: (String, Int, String) -> Void
    ) {
        let ns = text as NSString
        let parenPattern = "[\u{FF08}(]\\s*" + leadInPattern + quoteClass
            + "([^\"\u{201C}\u{201D})\u{FF09}]{2,70})" + quoteClass
        guard let regex = try? NSRegularExpression(pattern: parenPattern, options: [.caseInsensitive]) else {
            return
        }
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let term = ns.substring(with: match.range(at: 1))
            let windowStart = max(0, match.range.location - 90)
            let preceding = ns.substring(
                with: NSRange(location: windowStart, length: match.range.location - windowStart)
            )
            handler(term, match.range.location, preceding)
        }
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
        // CJK real-name aliases: Chinese has no word delimiters, so the
        // word-subset test above cannot see that 快帆科技 is derived from
        // 杭州快帆科技有限公司. A CJK term that is a literal substring of the
        // immediately preceding text is derived from the name it follows.
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCJKContained = !trimmedTerm.isEmpty
            && containsCJK(trimmedTerm)
            && preceding.contains(trimmedTerm)

        guard isWordSubset || isAcronymAlias || isCJKContained else {
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

    // MARK: - Derivation test (shared with EntityRescan)

    /// True when an alias surface is derived from a canonical entity surface:
    /// a CJK alias that is a literal substring of the canonical name, a Latin
    /// alias whose significant words are a subset of the canonical name's
    /// words, or an acronym of them. Used by the recall rescan to keep only
    /// aliases that actually abbreviate the entity they are bound to; a
    /// non-derived defined term (目标公司, "the Target") is document
    /// vocabulary and stays unredacted, per this scanner's philosophy.
    static func isDerivedAlias(_ alias: String, of canonical: String) -> Bool {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if containsCJK(trimmed) {
            // Contiguous substrings first (the common case), then ordered
            // character subsequences: PRC practice routinely forms a short
            // name by keeping the brand and industry words and dropping the
            // middle, so 蓝鲸科技 abbreviates 蓝鲸智能科技有限公司 even though
            // 智能 interrupts the run. A contiguous-only test rejected exactly
            // these, and every mention of such a short name then leaked
            // (release QA, High). Over-acceptance is bounded elsewhere: this
            // test only ever runs on aliases BOUND by a definition
            // parenthetical, and generic terms are refused by the boilerplate
            // and role-label gates before derivation is consulted.
            if canonical.contains(trimmed) { return true }
            return isOrderedCharacterSubsequence(trimmed, of: canonical)
        }

        let aliasWords = words(of: trimmed)
        let canonicalWords = words(of: canonical)
        guard !aliasWords.isEmpty, !canonicalWords.isEmpty else { return false }

        let significant = aliasWords.filter { !connectorWords.contains($0) }
        let canonicalSet = Set(canonicalWords)
        if !significant.isEmpty, significant.allSatisfy({ canonicalSet.contains($0) }) {
            return true
        }
        return isAcronym(termWords: aliasWords, of: canonicalWords)
    }

    /// True when every character of candidate appears in container in the
    /// same order, gaps allowed. Two-pointer walk, O(container length).
    static func isOrderedCharacterSubsequence(_ candidate: String, of container: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        var remainder = container[container.startIndex...]
        for character in candidate {
            guard let found = remainder.firstIndex(of: character) else { return false }
            remainder = remainder[remainder.index(after: found)...]
        }
        return true
    }

    /// True when the string contains at least one CJK ideograph (Han ranges
    /// plus the ideographic iteration and zero marks common in names).
    /// The ONE implementation of this test: SubstitutionStyling forwards here
    /// so script decisions cannot drift between aliasing and styling.
    static func containsCJK(_ s: String) -> Bool {
        return s.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3005...0x3007,      // iteration mark, ideographic closing/zero
                 0x3400...0x4DBF,      // CJK extension A
                 0x4E00...0x9FFF,      // CJK unified ideographs
                 0xF900...0xFAFF,      // CJK compatibility ideographs
                 0x20000...0x2FA1F:    // extensions B and beyond
                return true
            default:
                return false
            }
        }
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
