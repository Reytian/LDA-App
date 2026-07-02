//
//  LegalBoilerplate.swift
//  LDACore
//
//  Post-filter for LLM-reported fuzzy entity values (PERSON / COMPANY /
//  ADDRESS). The on-device model over-reports legal boilerplate as PII on real
//  contracts: defined terms ("Company", "AGREEMENT"), role nouns ("customers",
//  "third party"), executive titles ("PRESIDENT", "General Counsel"), statutes
//  ("SARBANES-OXLEY ACT", "NEW YORK CIVIL PRACTICE LAWS AND RULES"),
//  arbitration bodies ("JAMS"), and governing-law geography ("United States").
//  None of these identify a person or organization that anonymization should
//  hide; redacting them shreds the document.
//
//  This filter is the engine-side guardrail, independent of the prompt: even if
//  the model reports boilerplate, it is dropped before span location. It layers
//  on top of RoleLabels (contract party roles), which stays authoritative for
//  the role-label class.
//
//  Failure-mode choice: the lists are curated toward dropping KNOWN boilerplate
//  classes only. A real company whose name ends in a filtered head noun (for
//  example a firm literally named "... Law") would be a false negative; the
//  review UI's add-missed-item flow covers that rare case, whereas hundreds of
//  false positives make review unusable.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - LegalBoilerplate

/// Decides whether an LLM-reported entity value is legal boilerplate that must
/// never be redacted.
public enum LegalBoilerplate {

    /// True when the value should be dropped for the given entity type.
    ///
    /// Layers, in order:
    /// 1. Empty / single-character values (two-character names, Latin or CJK,
    ///    stay redactable: "Li", "Wu", "张三" are real surnames and dropping
    ///    them would leak every occurrence).
    /// 2. RoleLabels (contract party roles, EN + ZH).
    /// 3. The curated boilerplate list (case-insensitive, article-stripped):
    ///    generic party nouns and plurals, executive titles, document terms,
    ///    tribunal and agency names, statute shorthands.
    /// 4. Geography (countries, US states) for COMPANY / ADDRESS only: a bare
    ///    jurisdiction name there is governing-law boilerplate. PERSON is
    ///    exempt because many jurisdictions are also personal names (Virginia,
    ///    Washington, Georgia); a junk jurisdiction typed PERSON is preferable
    ///    to leaking a real name.
    /// 5. Statute / document head-noun rule, split by type: COMPANY uses the
    ///    full set ("act", "law", "rules", "code", "agreement", "court", ...);
    ///    PERSON uses a reduced set without the entries that collide with real
    ///    surnames (Law, Court, Rule, Code, Plan are all attested surnames).
    /// 6. Dangling-tail rule, split by type: a value ending in a function word
    ///    is a phrase clipped at a window edge, not a name. PERSON keeps only
    ///    tails that never end romanized names (An, To, Or, On are common final
    ///    syllables of Vietnamese, Cantonese, and Hebrew names); COMPANY drops
    ///    the bare ordinals too, except that real short names like "Fifth
    ///    Third" are protected by not including ordinals at all.
    /// 7. Lowercase heuristic for PERSON / COMPANY: a value containing no
    ///    uppercase letter and no CJK is a generic noun phrase ("customers",
    ///    "third party"), not a proper name as written in a legal document.
    ///    Domain-like values ("meridianworks.com") are exempt: a lowercase
    ///    domain identifies its owner.
    public static func shouldDrop(_ value: String, type: EntityType) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }

        let utf16Length = (trimmed as NSString).length
        if utf16Length < 2 {
            return true
        }

        if RoleLabels.isRoleLabel(trimmed) {
            return true
        }

        let lower = trimmed.lowercased()
        let bare = strippingLeadingArticle(from: lower)

        if boilerplateTerms.contains(lower) || boilerplateTerms.contains(bare) {
            return true
        }

        // Document part references: "Exhibit A", "Schedule 2", "Appendix B-1".
        if isDocumentPartReference(bare) {
            return true
        }

        if type != .person {
            // Employment-statute shorthands that collide with given names
            // ("Ada", "Cora") are scoped away from PERSON.
            if statuteAcronymsNonPerson.contains(bare) {
                return true
            }
            if geographicTerms.contains(lower) || geographicTerms.contains(bare) {
                return true
            }
            // "State of New York" style values: only when the remainder is a
            // known jurisdiction, so a company named "State of Mind Media"
            // stays redactable.
            for prefix in ["state of ", "commonwealth of "] where bare.hasPrefix(prefix) {
                let remainder = String(bare.dropFirst(prefix.count))
                if geographicTerms.contains(remainder) {
                    return true
                }
            }
            // Venue counties named after a jurisdiction: "New York County".
            if bare.hasSuffix(" county") {
                let stem = String(bare.dropLast(" county".count))
                if geographicTerms.contains(stem) {
                    return true
                }
            }
        }

        guard type == .person || type == .company else {
            return false
        }

        // Venue phrases: "Southern District of New York", "United States
        // District Court for the ...". Anchored on the "district" idiom plus a
        // known jurisdiction, so no realistic party name is affected.
        if bare.contains("district court") {
            return true
        }
        if let range = bare.range(of: " district of ", options: [.backwards]) {
            let remainder = String(bare[range.upperBound...])
            if geographicTerms.contains(remainder) {
                return true
            }
        }

        if let head = lastWord(of: bare) {
            let headNouns = type == .person ? instrumentHeadNounsPerson : instrumentHeadNounsCompany
            if headNouns.contains(head) {
                return true
            }
            let tails = type == .person ? danglingTailWordsPerson : danglingTailWordsCompany
            if tails.contains(head) {
                return true
            }
        }

        if !containsUppercaseOrCJK(trimmed) && !isDomainLike(trimmed) {
            return true
        }

        return false
    }

    // MARK: - Helpers

    /// True for values like "exhibit a", "schedule 2", "appendix b-1": a
    /// document-part word followed by a short identifier.
    private static func isDocumentPartReference(_ bare: String) -> Bool {
        let parts = bare.split(separator: " ")
        guard parts.count == 2 else { return false }
        let heads: Set<String> = ["exhibit", "schedule", "appendix", "annex", "attachment", "section", "article"]
        guard heads.contains(String(parts[0])) else { return false }
        let identifier = parts[1]
        return identifier.count <= 4 && identifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }

    private static func strippingLeadingArticle(from s: String) -> String {
        for article in ["the ", "an ", "a "] where s.hasPrefix(article) {
            return String(s.dropFirst(article.count))
        }
        return s
    }

    /// The final whitespace-separated word, stripped of trailing punctuation.
    private static func lastWord(of s: String) -> String? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard let last = parts.last else { return nil }
        let cleaned = last.filter { $0.isLetter }
        return cleaned.isEmpty ? nil : String(cleaned)
    }

    /// True for values shaped like a bare domain ("meridianworks.com"): a dot
    /// between non-space characters and no whitespace anywhere. Such values
    /// identify their owner even when written all-lowercase.
    private static func isDomainLike(_ s: String) -> Bool {
        guard !s.contains(where: { $0.isWhitespace }) else { return false }
        guard let dotIndex = s.firstIndex(of: "."), dotIndex != s.startIndex else { return false }
        let afterDot = s.index(after: dotIndex)
        return afterDot != s.endIndex && s[afterDot].isLetter
    }

    private static func containsUppercaseOrCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if scalar.properties.isUppercase {
                return true
            }
            // CJK Unified Ideographs and extensions, Hiragana/Katakana, Hangul.
            switch scalar.value {
            case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F,
                 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                continue
            }
        }
        return false
    }

    // MARK: - Curated lists

    /// Boilerplate values (lowercased). Compared against the value with and
    /// without a leading article, so "the Agreement" and "Agreement" both hit
    /// the single entry "agreement".
    private static let boilerplateTerms: Set<String> = [
        // Generic party and group nouns (plurals of RoleLabels entries plus
        // groups the model reports on real contracts).
        "company", "companies", "corporation", "corporations",
        "employer", "employers", "former employer", "former employers",
        "employee", "employees", "executive", "executives",
        "customer", "customers", "supplier", "suppliers",
        "vendor", "vendors", "licensor", "licensors",
        "licensee", "licensees", "collaborator", "collaborators",
        "consultant", "consultants", "contractor", "contractors",
        "subcontractor", "subcontractors",
        "third party", "third parties", "third-party",
        "associated third party", "associated third parties", "associated third",
        "other person", "other persons", "such person", "such persons",
        "person", "persons", "individual", "individuals",
        "entity", "entities", "subsidiary", "subsidiaries",
        "affiliate", "affiliates", "parent company",
        "successor", "successors", "assign", "assigns",
        "representative", "representatives", "agent", "agents",
        "attorney", "attorneys", "counsel", "party", "parties",
        "user", "users", "client", "clients", "clients and customers",
        "recipient", "recipients", "signatory", "signatories",
        "witness", "witnesses", "arbitrator", "arbitrators", "mediator",
        "buyers", "sellers", "lenders", "borrowers", "tenants", "landlords",
        "guarantors", "trustees", "beneficiaries",
        // Executive titles and corporate organs.
        "president", "vice president", "presidents",
        "ceo", "cfo", "coo", "cto", "cio",
        "chief executive officer", "chief financial officer",
        "chief operating officer", "chief technology officer",
        "chairman", "chairwoman", "chairperson", "chair",
        "secretary", "treasurer", "general counsel",
        "managing director", "executive officer",
        "board of directors", "board", "human resources",
        // Document-structure and defined terms.
        "agreement", "agreements", "this agreement",
        "contract", "contracts", "exhibit", "exhibits",
        "schedule", "schedules", "appendix", "appendices",
        "addendum", "addenda", "amendment", "amendments",
        "section", "sections", "article", "articles",
        "recital", "recitals", "whereas",
        "confidential information", "company confidential information",
        "proprietary information", "trade secret", "trade secrets",
        "intellectual property", "invention", "inventions",
        "work product", "services", "effective date",
        // Tribunals, ADR bodies, and agencies commonly named in contracts.
        "jams", "aaa", "american arbitration association",
        "icc", "lcia", "siac", "hkiac", "cietac",
        "sec", "securities and exchange commission",
        "irs", "internal revenue service", "internal revenue service center",
        "eeoc", "equal employment opportunity commission",
        "nlrb", "national labor relations board",
        "osha", "occupational safety and health administration",
        "dol", "department of labor", "department of justice", "doj",
        "ftc", "federal trade commission",
        "fcc", "federal communications commission",
        "faa", "federal aviation administration",
        "cftc", "commodity futures trading commission",
        "finra", "financial industry regulatory authority",
        "ssa", "social security administration",
        "attorney general",
        "supreme court", "district court",
        "court of chancery", "delaware court of chancery",
        "court of appeals", "new york court of appeals",
        "southern district of new york", "eastern district of new york",
        // Statute shorthands that do not end in a filtered head noun and do
        // not collide with personal names.
        "erisa", "cobra", "hipaa", "gdpr", "ccpa", "flsa", "dtsa", "cplr",
        "adea", "fmla", "userra", "title vii",
        // Chinese generic terms mirroring the English classes.
        "公司", "本公司", "本协议", "协议", "合同", "本合同",
        "员工", "客户", "供应商", "第三方", "关联方", "子公司", "附属公司",
        "董事会", "董事长", "总经理", "首席执行官", "法定代表人"
    ]

    /// Statute shorthands and equity-plan terms that are also plausible
    /// personal names or surnames, applied to COMPANY and ADDRESS only so
    /// "Ada" or "Grant" the person stays redactable. The equity terms are the
    /// defined instruments of award agreements ("Units" x19 was observed as
    /// COMPANY junk on a real incentive award agreement).
    private static let statuteAcronymsNonPerson: Set<String> = [
        "ada",
        "unit", "units", "share", "shares", "option", "options",
        "award", "awards", "grant", "grants", "warrant", "warrants",
        "restricted stock unit", "restricted stock units", "rsu", "rsus",
        "stock option", "stock options", "incentive award"
    ]

    /// Jurisdiction names that appear as governing-law or venue boilerplate.
    /// Countries commonly cited in cross-border contracts plus all US states.
    private static let geographicTerms: Set<String> = [
        "united states", "united states of america", "us", "usa", "u.s.", "u.s.a.",
        "america", "district of columbia", "eu", "european union",
        "china", "people's republic of china", "prc", "hong kong", "macau",
        "taiwan", "singapore", "japan", "south korea", "korea", "india",
        "united kingdom", "uk", "england", "england and wales", "wales",
        "scotland", "ireland", "canada", "australia", "new zealand",
        "germany", "france", "switzerland", "netherlands", "luxembourg",
        "cayman islands", "british virgin islands", "bvi", "bermuda",
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado",
        "connecticut", "delaware", "florida", "georgia", "hawaii", "idaho",
        "illinois", "indiana", "iowa", "kansas", "kentucky", "louisiana",
        "maine", "maryland", "massachusetts", "michigan", "minnesota",
        "mississippi", "missouri", "montana", "nebraska", "nevada",
        "new hampshire", "new jersey", "new mexico", "new york",
        "north carolina", "north dakota", "ohio", "oklahoma", "oregon",
        "pennsylvania", "rhode island", "south carolina", "south dakota",
        "tennessee", "texas", "utah", "vermont", "virginia", "washington",
        "west virginia", "wisconsin", "wyoming"
    ]

    /// Head nouns whose presence as the FINAL word marks a COMPANY value as a
    /// legal instrument, tribunal, or document rather than a party name
    /// ("NEW YORK LAW", "SARBANES-OXLEY ACT", "Supreme Court").
    private static let instrumentHeadNounsCompany: Set<String> = [
        "act", "acts", "law", "laws", "rule", "rules",
        "code", "codes", "regulation", "regulations",
        "statute", "statutes", "ordinance", "ordinances",
        "agreement", "agreements", "contract", "contracts",
        "policy", "policies", "plan", "plans",
        "court", "courts", "tribunal", "tribunals",
        "information", "exhibit", "exhibits",
        "schedule", "schedules", "section", "sections",
        "article", "articles", "amendment", "amendments",
        "notice", "notices", "addendum", "release"
    ]

    /// Reduced head-noun set for PERSON values. Entries that are attested
    /// surnames (Law, Court, Rule, Code, Plan) are removed so real people like
    /// "Jonathan Law" or "Margaret Court" stay redactable; a statute reported
    /// as PERSON is rare and the COMPANY set still catches the observed junk.
    private static let instrumentHeadNounsPerson: Set<String> = [
        "act", "acts", "regulation", "regulations",
        "statute", "statutes", "ordinance", "ordinances",
        "agreement", "agreements", "contract", "contracts",
        "policy", "policies", "tribunal", "tribunals",
        "information", "exhibit", "exhibits",
        "schedule", "schedules", "section", "sections",
        "article", "articles", "amendment", "amendments",
        "notice", "notices", "addendum", "release"
    ]

    /// Final words that mark a COMPANY value as a phrase clipped at a window
    /// edge rather than a complete name. Bare ordinals are intentionally NOT
    /// listed: "Fifth Third" and "Health First" are real company short names.
    /// The observed ordinal clip ("Associated Third") is covered by the
    /// explicit boilerplate entries and by DefinedTermScanner.
    private static let danglingTailWordsCompany: Set<String> = [
        "and", "or", "of", "the", "a", "an", "to", "for", "with", "by",
        "in", "on", "at", "any", "all", "each", "such", "other"
    ]

    /// Dangling tails for PERSON values, keeping only words that never end a
    /// romanized personal name. "An", "To", "Or", "On", "The", "A", "In" are
    /// common final syllables of Vietnamese, Cantonese, Korean, and Hebrew
    /// names and must stay redactable.
    private static let danglingTailWordsPerson: Set<String> = [
        "and", "of", "for", "with", "by", "any", "all", "each", "such", "other"
    ]
}
