//
//  SessionTokenizer.swift
//  LDACore
//
//  Multi-document session tokenization (R12): tokenize N documents against ONE
//  shared mapping by folding the seeded Tokenizer over the document list. The
//  same surface value carries the same placeholder in every document of the
//  session, and the single union mapping restores the whole set.
//
//  Pure: no clock reads, no I/O. The caller supplies the timestamp and an
//  optional seed mapping (a client profile's stored mapping, or a previous
//  session being extended).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// One document entering a session tokenization: its display name, its full
/// text, and the (already overlap-resolved, user-reviewed) spans to tokenize.
public struct SessionDocument: Sendable {
    public var name: String
    public var text: String
    public var spans: [Span]

    public init(name: String, text: String, spans: [Span]) {
        self.name = name
        self.text = text
        self.spans = spans
    }
}

/// One document leaving a session tokenization: its name and its tokenized
/// text (the redacted Markdown intermediate handed to the external AI).
public struct SessionTokenizedDocument: Sendable {
    public var name: String
    public var tokenizedText: String

    public init(name: String, tokenizedText: String) {
        self.name = name
        self.tokenizedText = tokenizedText
    }
}

/// The session result: every tokenized document plus the ONE shared mapping
/// that restores all of them.
public struct SessionTokenizeResult: Sendable {
    public var documents: [SessionTokenizedDocument]
    public var mapping: Mapping
    /// Seams the session seam pass could not repair, one readable line each.
    ///
    /// Empty in every normal run: the pass re-folds the session until the
    /// redacted text agrees with what was emitted. A non-empty list means a
    /// document would NOT restore to itself, so the caller must surface it
    /// rather than let the mis-restore be found later in a real document.
    public var unresolvedSeams: [String]

    public init(
        documents: [SessionTokenizedDocument],
        mapping: Mapping,
        unresolvedSeams: [String] = []
    ) {
        self.documents = documents
        self.mapping = mapping
        self.unresolvedSeams = unresolvedSeams
    }
}

/// Folds the seeded Tokenizer over a document list so the whole session shares
/// one mapping.
public enum SessionTokenizer {
    /// Tokenize the documents in order against one shared mapping.
    ///
    /// Each document is tokenized with the accumulated mapping as its seed, so
    /// a value first seen in document 1 keeps its token in documents 2..N and
    /// per-type counters never collide across the set.
    ///
    /// - Parameters:
    ///   - documents: the session's documents, in tray order.
    ///   - sourceLabel: the label recorded as the mapping's sourceFile (for
    ///     example a session or client name; the mapping spans many files).
    ///   - createdAtISO8601: caller-supplied ISO-8601 timestamp.
    ///   - seedMapping: optional starting mapping (client profile or a prior
    ///     session) whose identities the session must keep using. A seed built
    ///     in a different style contributes restore entries only; its
    ///     replacements are not re-emitted (see Tokenizer).
    ///   - style: how replacements are rendered across the whole session.
    /// - Returns: the tokenized documents plus the shared union mapping.
    public static func tokenize(
        documents: [SessionDocument],
        sourceLabel: String,
        createdAtISO8601: String,
        seedMapping: Mapping? = nil,
        style: SubstitutionStyle = .token
    ) -> SessionTokenizeResult {
        tokenizeCore(
            documents: documents,
            sourceLabel: sourceLabel,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seedMapping,
            style: style,
            overrides: [:],
            uniquenessCorpus: []
        )
    }

    /// Tokenize a session with caller-forced replacement text for specific
    /// surfaces (pseudonym style only).
    ///
    /// See the override contract on Tokenizer.tokenize(overrides:). The
    /// session variant validates the override set ONCE against every
    /// document's text plus the seed mapping, then folds with the same
    /// shared-mapping semantics as the plain entry point. Validating against
    /// the full corpus up front is what makes the fold safe: every override
    /// is reserved in every document before minting, so a pseudonym minted
    /// in document 1 can never collide with an override whose surface
    /// appears only in document 2.
    ///
    /// - Throws: PseudonymOverrideError when any override is rejected.
    public static func tokenize(
        documents: [SessionDocument],
        sourceLabel: String,
        createdAtISO8601: String,
        seedMapping: Mapping? = nil,
        style: SubstitutionStyle,
        overrides: [String: String]
    ) throws -> SessionTokenizeResult {
        try PseudonymOverrideValidator.validate(
            overrides: overrides,
            style: style,
            corpus: documents.map { $0.text },
            existingEntries: seedMapping?.entries ?? [:]
        )
        return tokenizeCore(
            documents: documents,
            sourceLabel: sourceLabel,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seedMapping,
            style: style,
            overrides: overrides,
            uniquenessCorpus: []
        )
    }

    /// Run the coordinated assignment repair for one direct Tokenizer call.
    ///
    /// Tokenizer invokes this only after its local seam data finds a conflict
    /// that requires changing an earlier replacement. Keeping this entry
    /// inside SessionTokenizer reuses the proven ban-and-refold direction,
    /// while fold continues to call Tokenizer.tokenizeDetailed directly and
    /// therefore cannot recurse into the public direct path.
    static func repairSingleDocument(
        text: String,
        spans: [Span],
        sourceFile: String,
        createdAtISO8601: String,
        seedMapping: Mapping?,
        style: SubstitutionStyle,
        uniquenessCorpus: [String],
        overrides: [String: String]
    ) -> TokenizeResult {
        let repaired = tokenizeCore(
            documents: [SessionDocument(name: sourceFile, text: text, spans: spans)],
            sourceLabel: sourceFile,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seedMapping,
            style: style,
            overrides: overrides,
            uniquenessCorpus: uniquenessCorpus
        )
        return TokenizeResult(
            tokenizedText: repaired.documents.first?.tokenizedText ?? text,
            mapping: repaired.mapping,
            unresolvedSeams: repaired.unresolvedSeams
        )
    }

    /// Shared core behind both entry points: fold, verify the whole
    /// assignment, and remint across every document when the redacted text
    /// disagrees with what was emitted.
    ///
    /// Overrides must already be validated against every document of the
    /// session (see the throwing entry point); the fold passes them into
    /// every per-document call.
    ///
    /// The fold alone is not enough for the literal pseudonym style. Mint
    /// time checks read one document at a time, but restore reads the whole
    /// session through one shared mapping, and a replacement REUSED in a
    /// later document, or one minted after an earlier document was already
    /// emitted, produces seams no mint time check ever looked at. So the fold
    /// is audited once it is complete and, when a seam would mis-restore, the
    /// offending pairing is banned and the whole session is folded again.
    /// Re-folding rather than patching one document is the point: the surface
    /// keeps ONE identity, it just becomes a different one everywhere at
    /// once. See SessionSeamVerifier.
    private static func tokenizeCore(
        documents: [SessionDocument],
        sourceLabel: String,
        createdAtISO8601: String,
        seedMapping: Mapping?,
        style: SubstitutionStyle,
        overrides: [String: String],
        uniquenessCorpus: [String]
    ) -> SessionTokenizeResult {
        var forbidden: [String: Set<String>] = [:]
        var passes = 0

        while true {
            let folded = fold(
                documents: documents,
                sourceLabel: sourceLabel,
                createdAtISO8601: createdAtISO8601,
                seedMapping: seedMapping,
                style: style,
                overrides: overrides,
                uniquenessCorpus: uniquenessCorpus,
                forbiddenReplacements: forbidden
            )

            // Only the pseudonym style restores by scanning the redacted text
            // for replacement strings, so only it has seams. Token style
            // restores through the brace grammar. Asterisk masks are a pure
            // function of the surface, so there is no second candidate to
            // remint to and no lever here at all; that residue is a restore
            // side decision (see RestorerPrefixAdjacencyTests).
            guard style == .pseudonym else {
                return SessionTokenizeResult(
                    documents: folded.documents,
                    mapping: folded.mapping
                )
            }

            let audit = seamAudit(in: folded, documents: documents)

            // A document the pass could not check cannot be repaired by
            // reminting: there is no matched replacement to ban, so another
            // fold would produce the identical report. Give up at once and
            // warn, rather than grinding through the repair cap to reach the
            // same place.
            //
            // Any violations found in the OTHER documents of this fold are
            // reported here rather than repaired. Repairing them would remint
            // across the whole session, which changes the very assignment we
            // already cannot verify on this document, so it would trade a
            // known report for an unknown one. Everything known is handed
            // over instead, and the user decides.
            if !audit.uncheckedDocumentIndices.isEmpty {
                return SessionTokenizeResult(
                    documents: folded.documents,
                    mapping: folded.mapping,
                    unresolvedSeams: uncheckedDescriptions(
                        of: audit.uncheckedDocumentIndices,
                        documents: documents
                    ) + descriptions(of: audit.violations, documents: documents)
                )
            }

            let violations = audit.violations
            if violations.isEmpty {
                return SessionTokenizeResult(
                    documents: folded.documents,
                    mapping: folded.mapping
                )
            }

            passes += 1
            let bans = bansToApply(for: violations, in: folded, alreadyBanned: forbidden)
            guard !bans.isEmpty, passes <= maxSeamRepairPasses else {
                // Nothing left to remint, or the backstop tripped. Hand back
                // the assignment we have WITH the warning: a silent
                // mis-restore is the failure this whole pass exists to
                // prevent.
                return SessionTokenizeResult(
                    documents: folded.documents,
                    mapping: folded.mapping,
                    unresolvedSeams: descriptions(of: violations, documents: documents)
                )
            }
            for ban in bans {
                forbidden[ban.surface, default: []].insert(ban.replacement)
            }
        }
    }

    /// How many repair passes to allow before reporting instead.
    ///
    /// Every pass bans at least one more concrete (surface, replacement)
    /// pairing that the finite corpus was observed to break, and only
    /// finitely many strings are spelled by a finite corpus, so the loop
    /// terminates on its own. The cap is a backstop against an unforeseen
    /// shape turning that into a grind, not part of the termination argument.
    private static let maxSeamRepairPasses = 8

    /// One completed fold, plus the per-document emit internals the seam pass
    /// needs to tell a substitution site from a coincidence.
    private struct Folded {
        let documents: [SessionTokenizedDocument]
        let mapping: Mapping
        let replacementBySurface: [[String: String]]
        let acceptedSpans: [[Span]]
    }

    /// The historical fold: tokenize document by document against one
    /// accumulating mapping, with the requested pairings banned.
    private static func fold(
        documents: [SessionDocument],
        sourceLabel: String,
        createdAtISO8601: String,
        seedMapping: Mapping?,
        style: SubstitutionStyle,
        overrides: [String: String],
        uniquenessCorpus: [String],
        forbiddenReplacements: [String: Set<String>]
    ) -> Folded {
        var mapping = Tokenizer.resettingUserOverrideEmissions(in: seedMapping) ?? Mapping(
            entries: [:],
            createdAtISO8601: createdAtISO8601,
            sourceFile: sourceLabel,
            style: style
        )
        var tokenized: [SessionTokenizedDocument] = []
        var assignments: [[String: String]] = []
        var acceptedSpans: [[Span]] = []

        // A pseudonym minted for document K must not occur naturally in ANY
        // document of the session: the shared mapping restores every document
        // with one literal scan, so a natural occurrence in a companion
        // document would be indistinguishable from a substitution site.
        let allTexts = documents.map { $0.text }

        for (index, document) in documents.enumerated() {
            var corpus = uniquenessCorpus
            corpus += allTexts.enumerated().compactMap { otherIndex, text in
                otherIndex == index ? nil : text
            }
            let detailed = Tokenizer.tokenizeDetailed(
                text: document.text,
                spans: document.spans,
                sourceFile: sourceLabel,
                createdAtISO8601: createdAtISO8601,
                seedMapping: mapping,
                style: style,
                uniquenessCorpus: corpus,
                overrides: overrides,
                forbiddenReplacements: forbiddenReplacements
            )
            mapping = detailed.result.mapping
            tokenized.append(
                SessionTokenizedDocument(
                    name: document.name,
                    tokenizedText: detailed.result.tokenizedText
                )
            )
            assignments.append(detailed.replacementBySurface)
            acceptedSpans.append(detailed.acceptedSpans)
        }

        // Normalize the mapping header: entries accumulated across documents,
        // but the session is one unit with one label and one timestamp.
        mapping.sourceFile = sourceLabel
        mapping.createdAtISO8601 = createdAtISO8601
        mapping.style = style

        return Folded(
            documents: tokenized,
            mapping: mapping,
            replacementBySurface: assignments,
            acceptedSpans: acceptedSpans
        )
    }

    /// What the seam pass made of a whole fold: the disagreements it found,
    /// and the documents it could not check at all. The second list is not a
    /// weaker form of the first. A document in it was never examined, so
    /// nothing is known about it either way.
    private struct SeamAudit {
        var violations: [SessionSeamVerifier.Violation]
        var uncheckedDocumentIndices: [Int]
    }

    /// Run the seam pass over every document of a completed fold.
    private static func seamAudit(
        in folded: Folded,
        documents: [SessionDocument]
    ) -> SeamAudit {
        // Exactly what the restore scan will search for: every replacement of
        // the shared mapping, including entries contributed by the seed.
        let replacements = Array(
            Set(folded.mapping.entries.values.map { $0.token }).filter { !$0.isEmpty }
        )
        var found: [SessionSeamVerifier.Violation] = []
        var unchecked: [Int] = []
        for index in documents.indices {
            let report = SessionSeamVerifier.report(
                documentIndex: index,
                tokenizedText: folded.documents[index].tokenizedText,
                originalText: documents[index].text,
                acceptedSpans: folded.acceptedSpans[index],
                replacementBySurface: folded.replacementBySurface[index],
                replacements: replacements
            )
            if report.couldNotVerify {
                unchecked.append(index)
            }
            found += report.violations
        }
        return SeamAudit(violations: found, uncheckedDocumentIndices: unchecked)
    }

    /// Readable lines for documents the pass could not check.
    ///
    /// Deliberately says what is and is not known. The document may well be
    /// fine; the point is that nothing verified it, and the user is the only
    /// one positioned to decide what to do about that.
    private static func uncheckedDescriptions(
        of indices: [Int],
        documents: [SessionDocument]
    ) -> [String] {
        indices.map { index in
            let name = documents.indices.contains(index)
                ? documents[index].name
                : "document \(index + 1)"
            return "\(name): the seam check could not run on this document, so "
                + "it is NOT known whether restoring it returns the original "
                + "text. Read the restored output before relying on it."
        }
    }

    /// One pairing to remint, as a surface and the replacement it must lose.
    private struct Ban {
        let surface: String
        let replacement: String
    }

    /// Choose what to remint for each violation.
    ///
    /// Always the replacement the scan MATCHED, never the site it swallowed.
    /// That direction is what terminates: the matched string is one the finite
    /// redacted text spells, so moving its surface to the next candidate
    /// escapes it, and a finite corpus spells only finitely many strings.
    /// Banning the swallowed site instead can be inescapable, because a ban
    /// only moves a candidate and the next candidate may share the part that
    /// forms the seam: every Chinese address pseudonym starts with 某, so an
    /// emitted 张某 sitting in front of an address site keeps spelling 张某
    /// whichever address candidate is chosen.
    ///
    /// The swallowed site is only a fallback, for a matched replacement no
    /// surface of this session owns: an entry carried in from a seed built in
    /// another style is in the mapping, and therefore scanned, but nothing
    /// here emits it and no remint can move it.
    ///
    /// The cost of the rule is that a surface can change identity even when
    /// it came from the caller's seed mapping, so a client may see a party
    /// renamed between sessions. A pseudonym the client recognizes is worth
    /// less than a document that restores to the wrong party, and the remint
    /// stays coordinated: the re-fold hands the surface its new identity in
    /// every document at once.
    private static func bansToApply(
        for violations: [SessionSeamVerifier.Violation],
        in folded: Folded,
        alreadyBanned: [String: Set<String>]
    ) -> [Ban] {
        // Replacement to the surface that emitted it. Surfaces are visited in
        // sorted order so the choice is deterministic even in the degenerate
        // case of two surfaces sharing a replacement.
        var surfaceByReplacement: [String: String] = [:]
        for assignment in folded.replacementBySurface {
            for surface in assignment.keys.sorted() {
                guard let replacement = assignment[surface],
                      surfaceByReplacement[replacement] == nil else {
                    continue
                }
                surfaceByReplacement[replacement] = surface
            }
        }

        var chosen: [Ban] = []
        var seen = Set<String>()
        for violation in violations {
            let candidates = [
                violation.matchedReplacement,
                violation.shadowedReplacement
            ].compactMap { $0 }

            for replacement in candidates {
                guard let surface = surfaceByReplacement[replacement],
                      alreadyBanned[surface]?.contains(replacement) != true else {
                    continue
                }
                // U+0000 cannot occur in either half, so the joined key is
                // unambiguous.
                let key = "\(surface)\u{0}\(replacement)"
                if seen.insert(key).inserted {
                    chosen.append(Ban(surface: surface, replacement: replacement))
                }
                break
            }
        }
        return chosen
    }

    /// Readable lines for seams the pass could not repair.
    private static func descriptions(
        of violations: [SessionSeamVerifier.Violation],
        documents: [SessionDocument]
    ) -> [String] {
        violations.map { violation in
            let name = documents.indices.contains(violation.documentIndex)
                ? documents[violation.documentIndex].name
                : "document \(violation.documentIndex + 1)"
            guard let shadowed = violation.shadowedReplacement else {
                return "\(name): the redacted text spells \(violation.matchedReplacement) "
                    + "where it was never substituted, so restore would replace it there."
            }
            return "\(name): the redacted text spells \(violation.matchedReplacement) across the "
                + "site holding \(shadowed), so that site would restore to the wrong entity."
        }
    }
}
