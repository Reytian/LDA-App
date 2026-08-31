//
//  PseudonymOverrideValidator.swift
//  LDACore
//
//  Validation for user-supplied pseudonym replacement text (overrides): a
//  caller may force the replacement string for a specific surface in a
//  pseudonym-style run, for example replacing one company name with 买受人
//  everywhere. An override is rejected, never adjusted, whenever emitting it
//  verbatim could break the literal restore scan: restore substitutes every
//  literal occurrence of a mapping replacement, so a replacement that occurs
//  naturally in the session corpus, or that two entities share, would make
//  substitution sites indistinguishable from ordinary text.
//
//  Overrides are a pseudonym-style feature only. Under the token style a
//  non-brace replacement is invisible to the token-grammar restore scan and
//  the original value would silently fail to restore; the validator rejects
//  that combination with a typed error instead of ever allowing it.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// A typed reason one user-supplied override was rejected. The UI surfaces
/// these per row, so every case carries the offending surface text.
public enum PseudonymOverrideError: Error, LocalizedError, Equatable, Sendable {
    /// Overrides exist only for the pseudonym style. Any other style is
    /// rejected outright; see the file header for why token style is a trap.
    case styleNotPseudonym(SubstitutionStyle)
    /// The surface or its replacement text is empty.
    case empty(surface: String)
    /// The replacement contains "{" or "}", which would collide with the
    /// brace token grammar used by the token style and its forensics scans.
    case containsBraces(surface: String, replacement: String)
    /// The replacement is already used by another entity: another override,
    /// or an existing mapping entry for a different surface.
    case collidesWithExistingReplacement(surface: String, replacement: String)
    /// The replacement already occurs in a session document's natural text,
    /// so the literal restore scan could not tell a substitution site from
    /// the natural occurrence.
    case occursNaturallyInCorpus(surface: String, replacement: String)

    public var errorDescription: String? {
        switch self {
        case .styleNotPseudonym(let style):
            return "Custom replacement text requires the pseudonym style; the current style is \(style.rawValue)."
        case .empty(let surface):
            return surface.isEmpty
                ? "A custom replacement needs a non-empty original text."
                : "The custom replacement for \"\(surface)\" must not be empty."
        case .containsBraces(let surface, _):
            return "The custom replacement for \"\(surface)\" must not contain braces."
        case .collidesWithExistingReplacement(let surface, let replacement):
            return "The custom replacement \"\(replacement)\" for \"\(surface)\" is already used for another entity."
        case .occursNaturallyInCorpus(let surface, let replacement):
            return "The custom replacement \"\(replacement)\" for \"\(surface)\" already appears in the session documents."
        }
    }
}

/// Pure validation for pseudonym overrides. No clock reads, no I/O.
public enum PseudonymOverrideValidator {

    /// Validate a full override set against the session corpus and any
    /// replacements already spoken for.
    ///
    /// - Parameters:
    ///   - overrides: exact surface text mapped to the forced replacement
    ///     text the caller wants emitted verbatim.
    ///   - style: the substitution style of the run. Anything but .pseudonym
    ///     is rejected when overrides are present. An empty override set is
    ///     always valid, so one call site can serve every style and only
    ///     constrains itself when the user actually forces text.
    ///   - corpus: the natural text the replacement must not occur in. Pass
    ///     every document of the session, originals not tokenized output.
    ///     Occurrence uses substring semantics, matching the pseudonym
    ///     uniqueness contract in SubstitutionStyling.
    ///   - existingEntries: mapping entries whose replacements are already
    ///     taken (a seed mapping). An entry that maps the SAME surface to the
    ///     SAME replacement is reuse, not a collision, which is what keeps
    ///     re-running a build with unchanged overrides idempotent.
    /// - Throws: PseudonymOverrideError for the first offending override in
    ///   sorted-surface order (deterministic across runs).
    public static func validate(
        overrides: [String: String],
        style: SubstitutionStyle,
        corpus: [String],
        existingEntries: [String: MappingEntry] = [:]
    ) throws {
        guard !overrides.isEmpty else {
            return
        }
        guard style == .pseudonym else {
            throw PseudonymOverrideError.styleNotPseudonym(style)
        }
        var claimed = Set<String>()
        for surface in overrides.keys.sorted() {
            let replacement = overrides[surface] ?? ""
            try validate(
                surface: surface,
                replacement: replacement,
                corpus: corpus,
                existingEntries: existingEntries,
                claimed: &claimed
            )
        }
    }

    /// Validate one override pair, recording its replacement in the claimed
    /// set so a later pair cannot reuse it.
    private static func validate(
        surface: String,
        replacement: String,
        corpus: [String],
        existingEntries: [String: MappingEntry],
        claimed: inout Set<String>
    ) throws {
        guard !surface.isEmpty, !replacement.isEmpty else {
            throw PseudonymOverrideError.empty(surface: surface)
        }
        if replacement.contains("{") || replacement.contains("}") {
            throw PseudonymOverrideError.containsBraces(
                surface: surface,
                replacement: replacement
            )
        }
        if claimed.contains(replacement)
            || isForeignReplacement(replacement, surface: surface, in: existingEntries) {
            throw PseudonymOverrideError.collidesWithExistingReplacement(
                surface: surface,
                replacement: replacement
            )
        }
        claimed.insert(replacement)
        if corpus.contains(where: { $0.contains(replacement) }) {
            throw PseudonymOverrideError.occursNaturallyInCorpus(
                surface: surface,
                replacement: replacement
            )
        }
    }

    /// True when an existing entry already uses this replacement for a
    /// DIFFERENT surface. An entry that already maps this surface is reuse.
    private static func isForeignReplacement(
        _ replacement: String,
        surface: String,
        in entries: [String: MappingEntry]
    ) -> Bool {
        entries.values.contains { entry in
            entry.token == replacement && !covers(entry, surface: surface)
        }
    }

    /// Whether this entry already maps the given surface: its value, its
    /// recorded surface text, or one of its aliases. This mirrors the surface
    /// list the Tokenizer seed loop reuses replacements for.
    private static func covers(_ entry: MappingEntry, surface: String) -> Bool {
        entry.value == surface
            || entry.surfaceText == surface
            || entry.aliases.contains(surface)
    }
}
