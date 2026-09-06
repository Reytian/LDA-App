//
//  Restorer.swift
//  LDACore
//
//  Pure deterministic restore. A single left-to-right pass over the tokenized
//  text finds every token-shaped string (using TokenGrammar.placeholderPattern),
//  substitutes each mapped token with its restored value, and records any
//  unmapped leftover token-shaped string (an orphan) the user may have mangled
//  while editing the tokenized document.
//
//  This deliberately does NOT use the position-window or fuzzy-context strategy
//  of the Python deanonymizer. It also deliberately does NOT iterate the mapping
//  dictionary and run a whole-string replacement per entry: that approach
//  re-scans text produced by earlier replacements, so a value that happens to
//  contain another entry's token cascades, and the unordered Dictionary.values
//  iteration makes the corruption nondeterministic across process runs. The
//  single forward scan emits substituted values into an output buffer and
//  advances the cursor past them, so an inserted value is never re-scanned. This
//  mirrors the already-correct DocxRedactor.replaceTokens and makes restoration
//  order-independent. The only shared contract with the rest of the system is the
//  placeholder pattern, reused from TokenGrammar so emit and restore never drift.
//
//  The same rule governs a token-style mapping that carries pseudonym entries
//  from another style: both replacement shapes are located in the INPUT text
//  and emitted in one pass (tokenStyleRestoreDecision), never one shape after
//  the other over the other's output, so a carried pseudonym cannot match
//  inside a value a brace token just restored. The DOCX run walker runs the
//  same decision over each part's whole text.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Pure deterministic restorer. No clock reads, no I/O, no fuzzy matching.
public enum Restorer {
    /// Restore a tokenized document back to its original surface values.
    ///
    /// Algorithm (a single left-to-right scan):
    /// 1. Build a token -> value lookup from `mapping.entries`.
    /// 2. Find every token-shaped string in the text with
    ///    `TokenGrammar.placeholderPattern`. For each match in document order,
    ///    copy the verbatim text since the previous match, then emit either the
    ///    mapped value (and increment `restoredCount`) or, when the token is not
    ///    in the mapping, the token verbatim while recording it as an orphan. The
    ///    cursor advances past each substitution, so an emitted value is never
    ///    re-scanned. This makes restoration order-independent and immune to a
    ///    value that contains another token, and it cannot cross-replace a longer
    ///    token because the grammar matches the full brace-delimited token
    ///    ("{PERSON_1}" is matched whole, not as a prefix of "{PERSON_12}").
    /// 3. `restoredCount` is the total number of token occurrences substituted.
    ///    `orphanTokens` holds the unique unmapped token-shaped strings in
    ///    first-seen order; these are tokens not in the mapping, or that survived
    ///    because the user broke them while editing.
    ///
    /// - Parameters:
    ///   - text: The tokenized (and possibly user-edited) text.
    ///   - mapping: The token map produced during tokenization.
    /// - Returns: A `RestoreResult` with the restored text, the count of token
    ///   occurrences replaced, any orphan tokens found during the scan, and any
    ///   near-miss suspect placeholders found by the forensics scan.
    public static func restore(text: String, mapping: Mapping) -> RestoreResult {
        // The mapping knows its own style, so restore dispatches on it: the
        // token grammar scan for .token (byte-identical to the historical
        // behavior), the literal replacement scan for the styles whose
        // replacements are ordinary strings.
        switch mapping.style {
        case .token:
            return restoreTokenStyleWithCarriedLiterals(text: text, mapping: mapping)
        case .pseudonym, .asterisk:
            return restoreLiteralStyle(text: text, mapping: mapping)
        }
    }

    /// Token-style restore, plus the entries carried across styles. A client
    /// mapping seeded under the pseudonym style and extended under the token
    /// style holds both replacement shapes; the grammar scan cannot see the
    /// non-brace ones, so an old pseudonym intermediate used to restore to
    /// zero replacements with no warning.
    ///
    /// Both shapes are decided against the RETURNED text in ONE pass (see
    /// tokenStyleRestoreDecision). The carried entries used to be a second
    /// pass over the OUTPUT of the token pass, and a carried pseudonym could
    /// then match inside an original value the first pass had just put back:
    /// with "Person A" carried for Alice, {COMPANY_1} restored to "Person A
    /// Holdings" and the second pass rewrote it to "Alice Holdings", reported
    /// as two restorations. A value this restore writes is never searched.
    ///
    /// Report semantics: orphans and suspects are the token scan's, and the
    /// absence of a carried literal is not an orphan (a token-style document
    /// is expected to carry braces, not the other style's replacements).
    /// ambiguousReplacements lists the carried replacements refused under the
    /// literal rules: shared by two entities, or a forced pseudonym returned
    /// more times than it was emitted.
    private static func restoreTokenStyleWithCarriedLiterals(
        text: String,
        mapping: Mapping
    ) -> RestoreResult {
        let plan = tokenStyleRestorePlan(for: mapping)
        guard !plan.carriedLiterals.allReplacements.isEmpty else {
            // Byte-identical to the historical token-only restore.
            return restoreTokenStyle(text: text, mapping: mapping)
        }

        // Decoded exactly as the token-only restore decodes, so a Markdown
        // round trip restores the same sites on both paths.
        let decoded = PlaceholderForensics.decodeMarkdownEscapedTokens(in: text)

        // A forced pseudonym returned more often than it was emitted is
        // refused everywhere, as under the literal styles. The count reads
        // the sites the first decision accepted; the decision is then taken
        // again with those replacements refused, still over the input text.
        var decision = tokenStyleRestoreDecision(in: decoded, plan: plan)
        let overReturned = userOverridesExceedingEmissionCount(
            returned: decision.sites
                .map(\.replacement)
                .filter { plan.carriedLiterals.allReplacements.contains($0) },
            mapping: mapping
        )
        if !overReturned.isEmpty {
            decision = tokenStyleRestoreDecision(
                in: decoded,
                plan: tokenStyleRestorePlan(for: mapping, refusingReplacements: overReturned)
            )
        }

        let pass = emitDecidedSites(text: decoded, sites: decision.sites)
        return RestoreResult(
            text: pass.text,
            restoredCount: pass.restoredCount,
            orphanTokens: decision.unmappedTokens,
            suspectPlaceholders: PlaceholderForensics.suspects(in: decoded, mapping: mapping),
            ambiguousReplacements: pass.refused
        )
    }

    /// The historical token-grammar restore. See restore(text:mapping:).
    private static func restoreTokenStyle(text: String, mapping: Mapping) -> RestoreResult {
        // Decode Markdown-escaped underscores inside otherwise exact tokens
        // ("{PERSON\_1}" is the exact token, Markdown-encoded) so a Markdown
        // round-trip through an external AI restores cleanly. This is a
        // deterministic decode, not a guess; genuinely mangled placeholders are
        // handled by the suspect scan below, which only ever flags.
        let text = PlaceholderForensics.decodeMarkdownEscapedTokens(in: text)

        // Token -> value lookup. mapping.entries is keyed by token already, but a
        // dedicated map keeps the lookup independent of the entry shape and skips
        // any empty-token entries defensively.
        var tokenToValue: [String: String] = [:]
        for entry in mapping.entries.values where !entry.token.isEmpty {
            tokenToValue[entry.token] = entry.value
        }

        guard let regex = try? NSRegularExpression(
            pattern: TokenGrammar.placeholderPattern
        ) else {
            // Without the grammar we cannot locate tokens; return the input
            // unchanged so we never corrupt the document.
            return RestoreResult(text: text, restoredCount: 0, orphanTokens: [])
        }

        // The scan itself is shared with DocxRedactor's per-run substitution
        // (see TokenSubstitution), so the token grammar and the "an unmapped
        // token is left verbatim, never blanked" rule cannot drift between the
        // text surface and the docx surface. Unmapped tokens come back as
        // orphans for the user to review.
        let outcome = TokenSubstitution.substitute(in: text, matching: regex) { token in
            tokenToValue[token]
        }

        // Forensics pass: find near-miss placeholder shapes (an external AI may
        // have swapped brackets, dropped a brace, changed case, stripped the
        // braces, or drifted the separators of a known TYPE name). Suspects
        // are flagged for the user and never substituted. The scan runs over
        // the decoded INPUT text, where mangled shapes still sit in their
        // original form.
        let suspects = PlaceholderForensics.suspects(in: text, mapping: mapping)

        return RestoreResult(
            text: outcome.text,
            restoredCount: outcome.substitutedCount,
            orphanTokens: outcome.unmappedTokens,
            suspectPlaceholders: suspects
        )
    }

    // MARK: - Literal styles (pseudonym, asterisk)

    /// Restore for the styles whose replacements are ordinary strings.
    ///
    /// A single left-to-right pass substitutes every literal occurrence of a
    /// mapping replacement with its original value. At each position the
    /// longest matching replacement wins (a pseudonym may be a prefix of a
    /// longer one), an emitted value is never re-scanned, and the pass is
    /// deterministic regardless of dictionary order.
    ///
    /// Report semantics per the style contract:
    /// - restoredCount counts substituted occurrences.
    /// - orphanTokens lists mapping replacements that were never substituted
    ///   (the edited text no longer contains them).
    /// - ambiguousReplacements lists the replacements whose sites could not
    ///   be attributed to one entity: a replacement two entities share
    ///   outright, and under the asterisk style a replacement that a shorter
    ///   replacement also matches at the same position, or a user-forced
    ///   pseudonym returned more times than this handoff emitted it. Those
    ///   sites are left verbatim, never guessed.
    /// - suspectPlaceholders stays empty: there is no token grammar to
    ///   mangle in these styles.
    private static func restoreLiteralStyle(text: String, mapping: Mapping) -> RestoreResult {
        let valuesByReplacement = distinctValuesByReplacement(mapping)
        let sharedByTwoEntities = Set(
            valuesByReplacement.filter { $0.value.count > 1 }.map { $0.key }
        )
        let accepted = acceptedLiteralMatches(
            in: text,
            replacements: Array(valuesByReplacement.keys)
        )
        let overReturnedUserOverrides = userOverridesExceedingEmissionCount(
            returned: accepted.map(\.replacement),
            mapping: mapping
        )
        let pass = emitLiteralRestore(
            text: text,
            accepted: accepted,
            valuesByReplacement: valuesByReplacement,
            refusedEverywhere: sharedByTwoEntities.union(overReturnedUserOverrides),
            refusingPrefixConflicts: refusesPrefixConflicts(mapping)
        )

        // Mapping replacements that never substituted anywhere: the edited
        // text no longer contains them (or a longer replacement shadowed
        // every occurrence). Ambiguity is reported separately above.
        let orphans = valuesByReplacement.keys
            .filter { !pass.substituted.contains($0) && !pass.refusedSeen.contains($0) }
            .sorted()

        return RestoreResult(
            text: pass.text,
            restoredCount: pass.restoredCount,
            orphanTokens: orphans,
            suspectPlaceholders: [],
            ambiguousReplacements: pass.refusedReported
        )
    }

    /// replacement -> the distinct original values behind it. Entry keys are
    /// visited in sorted order so value order is deterministic.
    private static func distinctValuesByReplacement(
        _ mapping: Mapping
    ) -> [String: [String]] {
        var valuesByReplacement: [String: [String]] = [:]
        for key in mapping.entries.keys.sorted() {
            guard let entry = mapping.entries[key], !entry.token.isEmpty else { continue }
            if !(valuesByReplacement[entry.token]?.contains(entry.value) ?? false) {
                valuesByReplacement[entry.token, default: []].append(entry.value)
            }
        }
        return valuesByReplacement
    }

    /// Forced pseudonyms carry the number of sites emitted in this handoff.
    /// When the reply contains more, no occurrence can be attributed safely:
    /// the AI may have moved or rewritten the sentence, so even the first N
    /// sites are uncertain. Refuse that replacement everywhere.
    private static func userOverridesExceedingEmissionCount(
        returned: [String],
        mapping: Mapping
    ) -> Set<String> {
        var returnedCounts: [String: Int] = [:]
        for replacement in returned {
            returnedCounts[replacement, default: 0] += 1
        }

        var refused: Set<String> = []
        for entry in mapping.entries.values {
            guard let emitted = entry.userOverrideEmissionCount else { continue }
            if returnedCounts[entry.token, default: 0] > max(0, emitted) {
                refused.insert(entry.token)
            }
        }
        return refused
    }

    /// What one literal restore pass produced, before the orphan report.
    private struct LiteralRestorePass {
        var text = ""
        var restoredCount = 0
        /// Replacements substituted at least once.
        var substituted: Set<String> = []
        /// Replacements refused at least once.
        var refusedSeen: Set<String> = []
        /// The refused replacements in first-seen order, for the report.
        var refusedReported: [String] = []
    }

    /// Emit the restored text: substitute the sites that belong to exactly
    /// one entity, leave every other site verbatim, and record both.
    private static func emitLiteralRestore(
        text: String,
        accepted: [AcceptedLiteralMatch],
        valuesByReplacement: [String: [String]],
        refusedEverywhere: Set<String>,
        refusingPrefixConflicts: Bool
    ) -> LiteralRestorePass {
        let nsText = text as NSString
        var pass = LiteralRestorePass()
        var cursor = 0

        for match in accepted {
            if match.range.location > cursor {
                pass.text += nsText.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
            }
            cursor = match.range.location + match.range.length

            if refusesSite(
                match,
                refusedEverywhere: refusedEverywhere,
                refusingPrefixConflicts: refusingPrefixConflicts
            ) {
                pass.text += nsText.substring(with: match.range)
                if pass.refusedSeen.insert(match.replacement).inserted {
                    pass.refusedReported.append(match.replacement)
                }
            } else if let value = valuesByReplacement[match.replacement]?.first {
                pass.text += value
                pass.restoredCount += 1
                pass.substituted.insert(match.replacement)
            } else {
                pass.text += nsText.substring(with: match.range)
            }
        }

        if cursor < nsText.length {
            pass.text += nsText.substring(from: cursor)
        }
        return pass
    }

    /// Whether this site cannot be attributed to one entity.
    ///
    /// Two shapes refuse. Either two entities share the replacement outright
    /// (the historical asterisk collision), or a shorter replacement also
    /// matches at this exact position and the style cannot rule it out: an
    /// asterisk mask is a pure function of the surface, so 张三 masks to 张*
    /// and 张伟明 masks to 张*明, and the site 张*明 is spelled by both the
    /// longer mask and the shorter mask followed by an ordinary 明. Guessing
    /// either would swap one real person for another, so the site keeps its
    /// bytes and is flagged instead.
    private static func refusesSite(
        _ match: AcceptedLiteralMatch,
        refusedEverywhere: Set<String>,
        refusingPrefixConflicts: Bool
    ) -> Bool {
        if refusedEverywhere.contains(match.replacement) {
            return true
        }
        return refusingPrefixConflicts && match.shadowsShorterReplacement
    }

    // MARK: - Shared literal scanning

    /// One accepted literal occurrence of a replacement string.
    internal struct AcceptedLiteralMatch {
        let range: NSRange
        let replacement: String
        /// True when a shorter replacement also matches at this exact start
        /// position, so the site's text spells two different replacements and
        /// only the longest-wins rule chose between them.
        let shadowsShorterReplacement: Bool
    }

    /// Find the non-overlapping literal occurrences of the given replacement
    /// strings, in document order, with the longest replacement winning at
    /// any shared start position. Deterministic regardless of input order.
    internal static func acceptedLiteralMatches(
        in text: String,
        replacements: [String]
    ) -> [AcceptedLiteralMatch] {
        acceptLongestAtEachPosition(
            allLiteralMatches(in: text, replacements: replacements)
        )
    }

    /// Every literal occurrence of every replacement, in no useful order.
    private static func allLiteralMatches(
        in text: String,
        replacements: [String]
    ) -> [AcceptedLiteralMatch] {
        let nsText = text as NSString
        var found: [AcceptedLiteralMatch] = []
        for replacement in replacements where !replacement.isEmpty {
            var searchLocation = 0
            while searchLocation < nsText.length {
                let range = nsText.range(
                    of: replacement,
                    options: [.literal],
                    range: NSRange(location: searchLocation, length: nsText.length - searchLocation)
                )
                guard range.location != NSNotFound, range.length > 0 else { break }
                found.append(
                    AcceptedLiteralMatch(
                        range: range,
                        replacement: replacement,
                        shadowsShorterReplacement: false
                    )
                )
                searchLocation = range.location + range.length
            }
        }
        return found
    }

    /// Keep one match per position, scanning left to right.
    ///
    /// Earliest position first; at the same position the longest replacement
    /// wins; ties break on the string for determinism. A match starting
    /// before the previous accepted end overlaps it (a shorter replacement
    /// nested in a longer one, or two occurrences crossing) and is dropped.
    ///
    /// A dropped match that STARTS where the accepted one starts is recorded
    /// on it as a shadowed shorter replacement. Those are exactly the sites
    /// whose text spells more than one replacement, which is what lets a
    /// style refuse them rather than take the longest.
    private static func acceptLongestAtEachPosition(
        _ found: [AcceptedLiteralMatch]
    ) -> [AcceptedLiteralMatch] {
        let ordered = found.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            if lhs.range.length != rhs.range.length {
                return lhs.range.length > rhs.range.length
            }
            return lhs.replacement < rhs.replacement
        }

        var accepted: [AcceptedLiteralMatch] = []
        var cursor = 0
        var index = 0
        while index < ordered.count {
            let match = ordered[index]
            guard match.range.location >= cursor else {
                index += 1
                continue
            }
            var next = index + 1
            var shadowsShorter = false
            while next < ordered.count, ordered[next].range.location == match.range.location {
                shadowsShorter = shadowsShorter || ordered[next].replacement != match.replacement
                next += 1
            }
            accepted.append(
                AcceptedLiteralMatch(
                    range: match.range,
                    replacement: match.replacement,
                    shadowsShorterReplacement: shadowsShorter
                )
            )
            cursor = match.range.location + match.range.length
            index = next
        }
        return accepted
    }

    // MARK: - Restoring on another surface

    /// What a caller substituting literal replacements on its own surface
    /// (the DOCX run walker) needs to reach the same verdicts as the
    /// reporting scan.
    public struct LiteralRestorePlan: Sendable {
        /// replacement -> value for every replacement carried by exactly one
        /// entity. A replacement absent from here is never substituted.
        public let replacementToValue: [String: String]
        /// Every replacement in the mapping, the ambiguous ones included.
        /// Those are never substituted, but the scan still has to recognize
        /// them: a site that also spells an ambiguous replacement is itself
        /// ambiguous, and dropping it from the scan would make that site look
        /// safe to substitute.
        public let allReplacements: Set<String>
        /// Whether a shorter replacement matching at the same position
        /// refuses the site (asterisk masks) or merely loses the longest
        /// match (pseudonyms). See refusesPrefixConflicts(_:).
        public let refusesPrefixConflicts: Bool
    }

    /// Build the restore plan for a literal-style mapping. The single place
    /// the style's ambiguity policy is decided, so a surface that substitutes
    /// on its own cannot drift from the report. A caller that already scanned
    /// the whole return surface passes its reported ambiguous replacements so
    /// package writers leave those sites verbatim too.
    public static func literalRestorePlan(
        for mapping: Mapping,
        refusingReplacements: Set<String> = []
    ) -> LiteralRestorePlan {
        var replacements = unambiguousReplacementMap(mapping)
        for refused in refusingReplacements {
            replacements[refused] = nil
        }
        return LiteralRestorePlan(
            replacementToValue: replacements,
            allReplacements: Set(
                mapping.entries.values.map(\.token).filter { !$0.isEmpty }
            ),
            refusesPrefixConflicts: refusesPrefixConflicts(mapping)
        )
    }

    /// One decided restore site on a surface that substitutes on its own.
    ///
    /// The decision is already taken: `value` is the original text to write,
    /// or nil when the site keeps its bytes because the style refuses it or
    /// no single entity owns the replacement.
    internal struct LiteralRestoreSite {
        /// Where the site sits in the scanned text, in UTF-16 offsets.
        let range: NSRange
        /// The replacement the text spells at this site.
        let replacement: String
        /// The original value to write, or nil to leave the site verbatim.
        let value: String?
    }

    /// Decide every literal restore site in `text` under `plan`.
    ///
    /// The single decision function every literal surface shares. The report
    /// scan, the plain-string substitution, and the DOCX run walker all run
    /// it over the SAME text, so one site can never be substituted on one
    /// surface and refused on another. Deciding on a smaller slice (one docx
    /// run rather than the whole part) is exactly the drift this prevents: an
    /// isolated run can hide the longer replacement that makes the site
    /// ambiguous, and the walker would then write a name the report says was
    /// never guessed.
    internal static func literalRestoreSites(
        in text: String,
        plan: LiteralRestorePlan
    ) -> [LiteralRestoreSite] {
        acceptedLiteralMatches(
            in: text,
            replacements: Array(plan.allReplacements)
        ).map { match in
            let refused = plan.refusesPrefixConflicts && match.shadowsShorterReplacement
            return LiteralRestoreSite(
                range: match.range,
                replacement: match.replacement,
                value: refused ? nil : plan.replacementToValue[match.replacement]
            )
        }
    }

    /// Substitute every literal replacement in a plain string that belongs to
    /// exactly one entity, leaving every other site verbatim.
    ///
    /// The single-pass emit mirrors restoreLiteralStyle without the report.
    internal static func substituteLiteralReplacements(
        in text: String,
        plan: LiteralRestorePlan
    ) -> String {
        emitDecidedSites(text: text, sites: literalRestoreSites(in: text, plan: plan)).text
    }

    /// What one emit over decided sites produced.
    private struct DecidedSitesPass {
        var text = ""
        var restoredCount = 0
        /// The refused replacements in first-seen order, for the report.
        var refused: [String] = []
    }

    /// Emit `text` with every decided site applied: a site carrying a value
    /// is substituted, a refused site keeps its bytes and is recorded once.
    /// The cursor only ever advances over offsets of `text`, so an emitted
    /// value is never re-scanned. Sites must be in document order and
    /// non-overlapping, which is what every decision function here returns.
    private static func emitDecidedSites(
        text: String,
        sites: [LiteralRestoreSite]
    ) -> DecidedSitesPass {
        let nsText = text as NSString
        var pass = DecidedSitesPass()
        var refusedSeen: Set<String> = []
        var cursor = 0
        for site in sites {
            if site.range.location > cursor {
                pass.text += nsText.substring(
                    with: NSRange(location: cursor, length: site.range.location - cursor)
                )
            }
            if let value = site.value {
                pass.text += value
                pass.restoredCount += 1
            } else {
                pass.text += nsText.substring(with: site.range)
                if refusedSeen.insert(site.replacement).inserted {
                    pass.refused.append(site.replacement)
                }
            }
            cursor = site.range.location + site.range.length
        }
        if cursor < nsText.length {
            pass.text += nsText.substring(from: cursor)
        }
        return pass
    }

    // MARK: - Token style on another surface

    /// What a token-style surface that substitutes on its own (the DOCX run
    /// walker) needs to reach the same sites as the text restore.
    public struct TokenStyleRestorePlan: Sendable {
        /// Brace token -> value for every grammar-shaped entry of the mapping.
        public let tokenToValue: [String: String]
        /// The entries carried in from another style (a pseudonym seed under
        /// a token-style run), decided under the literal rules. Empty for a
        /// pure token mapping.
        public let carriedLiterals: LiteralRestorePlan
    }

    /// Build the token-style restore plan for a mapping. A caller that already
    /// scanned the whole return surface passes its reported ambiguous
    /// replacements so package writers leave those sites verbatim too.
    public static func tokenStyleRestorePlan(
        for mapping: Mapping,
        refusingReplacements: Set<String> = []
    ) -> TokenStyleRestorePlan {
        var tokenToValue: [String: String] = [:]
        var carried = mapping
        carried.entries = [:]
        for (key, entry) in mapping.entries where !entry.token.isEmpty {
            if TokenGrammar.isPlaceholderShaped(entry.token) {
                tokenToValue[entry.token] = entry.value
            } else {
                carried.entries[key] = entry
            }
        }
        return TokenStyleRestorePlan(
            tokenToValue: tokenToValue,
            carriedLiterals: literalRestorePlan(
                for: carried,
                refusingReplacements: refusingReplacements
            )
        )
    }

    /// The plan for a bare token -> value table with nothing carried.
    public static func tokenStyleRestorePlan(
        tokenToValue: [String: String]
    ) -> TokenStyleRestorePlan {
        TokenStyleRestorePlan(
            tokenToValue: tokenToValue.filter { TokenGrammar.isPlaceholderShaped($0.key) },
            carriedLiterals: LiteralRestorePlan(
                replacementToValue: [:],
                allReplacements: [],
                refusesPrefixConflicts: false
            )
        )
    }

    /// Everything the token-style decision knows about one text.
    internal struct TokenStyleRestoreDecision {
        /// Every site restore substitutes or refuses, in document order.
        let sites: [LiteralRestoreSite]
        /// Token-shaped strings no entry resolves, first seen first, once each.
        let unmappedTokens: [String]
    }

    /// Decide every token-style restore site in `text` under `plan`, in ONE
    /// pass over the input text.
    ///
    /// Brace tokens come from the grammar scan; a mapped one is a site, an
    /// unmapped one is reported and left alone. The carried literals are
    /// decided over the SAME text under the literal rules, and a literal
    /// match that overlaps any token-shaped string is dropped: a token is
    /// grammar, never a pseudonym site, so the token wins. Because both
    /// shapes are located in the input, no site can ever sit inside a value
    /// another site restores. The text restore and the DOCX run walker both
    /// run this over the whole surface they hold, so one site cannot be
    /// substituted on one surface and left alone on the other.
    internal static func tokenStyleRestoreDecision(
        in text: String,
        plan: TokenStyleRestorePlan
    ) -> TokenStyleRestoreDecision {
        guard let regex = try? NSRegularExpression(
            pattern: TokenGrammar.placeholderPattern
        ) else {
            return TokenStyleRestoreDecision(sites: [], unmappedTokens: [])
        }
        let nsText = text as NSString
        let tokenRanges = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        ).map(\.range)

        var tokenSites: [LiteralRestoreSite] = []
        var unmapped: [String] = []
        var seenUnmapped = Set<String>()
        for range in tokenRanges {
            let token = nsText.substring(with: range)
            if let value = plan.tokenToValue[token] {
                tokenSites.append(
                    LiteralRestoreSite(range: range, replacement: token, value: value)
                )
            } else if seenUnmapped.insert(token).inserted {
                unmapped.append(token)
            }
        }
        guard !plan.carriedLiterals.allReplacements.isEmpty else {
            return TokenStyleRestoreDecision(sites: tokenSites, unmappedTokens: unmapped)
        }

        let literalSites = literalRestoreSites(in: text, plan: plan.carriedLiterals)
        let sites = (tokenSites + dropOverlapping(literalSites, tokenRanges))
            .sorted { $0.range.location < $1.range.location }
        return TokenStyleRestoreDecision(sites: sites, unmappedTokens: unmapped)
    }

    /// The token-style sites alone, for a surface that substitutes on its own.
    internal static func tokenStyleRestoreSites(
        in text: String,
        plan: TokenStyleRestorePlan
    ) -> [LiteralRestoreSite] {
        tokenStyleRestoreDecision(in: text, plan: plan).sites
    }

    /// Drop every site that intersects one of `ranges`. Both lists are in
    /// document order and internally non-overlapping, so one sweep decides.
    private static func dropOverlapping(
        _ sites: [LiteralRestoreSite],
        _ ranges: [NSRange]
    ) -> [LiteralRestoreSite] {
        var kept: [LiteralRestoreSite] = []
        var index = 0
        for site in sites {
            let siteEnd = site.range.location + site.range.length
            while index < ranges.count,
                  ranges[index].location + ranges[index].length <= site.range.location {
                index += 1
            }
            if index < ranges.count, ranges[index].location < siteEnd {
                continue
            }
            kept.append(site)
        }
        return kept
    }

    /// Whether this mapping's style refuses a prefix conflict at a match site
    /// instead of taking the longest match.
    ///
    /// Asterisk masks are a pure function of the surface, so two entities
    /// sharing a surname collide by prefix (张三 masks to 张*, 张伟明 masks to
    /// 张*明) and nothing at mint time can separate them; the conflict can
    /// only be settled at restore time, by refusing. Pseudonyms are minted
    /// clear of that shape by PseudonymSeamGuard and the token grammar
    /// matches a whole token, so both keep longest match wins.
    internal static func refusesPrefixConflicts(_ mapping: Mapping) -> Bool {
        mapping.style == .asterisk
    }

    /// The unambiguous replacement -> value map for a literal-style mapping:
    /// every replacement carried by exactly one distinct value. Ambiguous
    /// replacements (asterisk collisions) are excluded so a caller doing its
    /// own substitution can never guess.
    internal static func unambiguousReplacementMap(_ mapping: Mapping) -> [String: String] {
        var valuesByReplacement: [String: Set<String>] = [:]
        for entry in mapping.entries.values where !entry.token.isEmpty {
            valuesByReplacement[entry.token, default: []].insert(entry.value)
        }
        var map: [String: String] = [:]
        for (replacement, values) in valuesByReplacement where values.count == 1 {
            map[replacement] = values.first
        }
        return map
    }
}
