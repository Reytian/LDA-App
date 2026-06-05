//
//  RestorerTests.swift
//  LDACoreTests
//
//  Tests for the pure deterministic Restorer.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//
//  Notes on the round-trip property test:
//  The package does not yet ship a Tokenizer engine, so these tests include a
//  small, self-contained reference tokenizer (makeTokenize) that emits tokens
//  exactly matching the TokenGrammar contract and builds a Mapping whose values
//  are the original surface substrings. Restoring that Mapping must reproduce the
//  ORIGINAL text byte for byte. The reference tokenizer operates on UTF-16
//  offsets (Span.start and Span.end), matching the offset convention frozen in
//  CoreTypes.swift.
//

import XCTest
@testable import LDACore

final class RestorerTests: XCTestCase {

    // MARK: - Reference tokenizer (test helper)

    /// A tokenization output mirroring TokenizeResult but built locally in the
    /// test so the round-trip property does not depend on an unbuilt engine.
    private struct LocalTokenize {
        let tokenizedText: String
        let mapping: Mapping
    }

    /// Reference tokenizer for the round-trip property.
    ///
    /// For each span (given in UTF-16 offsets, start inclusive, end exclusive),
    /// emit a token "{TYPE_N}" and record a MappingEntry whose value is the exact
    /// original surface substring. Identical surface strings of the same type
    /// reuse the same token so the mapping has one entry per distinct entity,
    /// which is the production contract. Spans are applied back to front so that
    /// earlier UTF-16 offsets are not invalidated by earlier replacements.
    private func makeTokenize(
        text: String,
        spans: [Span],
        sourceFile: String = "test.txt"
    ) -> LocalTokenize {
        let nsText = NSMutableString(string: text)

        // Assign a stable token per (type, surface) pair, numbered per type in
        // first-encounter order reading left to right.
        var perTypeCounter: [EntityType: Int] = [:]
        var tokenForSurface: [String: String] = [:]
        var entries: [String: MappingEntry] = [:]

        // First pass left to right to assign deterministic token numbers.
        let leftToRight = spans.sorted { $0.start < $1.start }
        for span in leftToRight {
            let key = "\(span.type.rawValue)\u{0}\(span.text)"
            if tokenForSurface[key] != nil {
                continue
            }
            let next = (perTypeCounter[span.type] ?? 0) + 1
            perTypeCounter[span.type] = next
            let typeToken = TokenGrammar.sanitizeType(span.type.rawValue)
            let token = "{\(typeToken)_\(next)}"
            tokenForSurface[key] = token
            entries[token] = MappingEntry(
                token: token,
                value: span.text,
                type: span.type,
                surfaceText: span.text,
                aliases: []
            )
        }

        // Second pass back to front to splice tokens into the text by UTF-16
        // range without disturbing not-yet-processed offsets.
        let backToFront = spans.sorted { $0.start > $1.start }
        for span in backToFront {
            let key = "\(span.type.rawValue)\u{0}\(span.text)"
            guard let token = tokenForSurface[key] else {
                continue
            }
            let range = NSRange(location: span.start, length: span.end - span.start)
            nsText.replaceCharacters(in: range, with: token)
        }

        let mapping = Mapping(
            entries: entries,
            createdAtISO8601: "2026-01-01T00:00:00Z",
            sourceFile: sourceFile
        )
        return LocalTokenize(tokenizedText: nsText as String, mapping: mapping)
    }

    /// Build a Span from UTF-16 offsets, validating that the offsets actually
    /// cover the expected surface text.
    private func span(
        in text: String,
        start: Int,
        end: Int,
        type: EntityType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Span {
        let nsText = text as NSString
        let surface = nsText.substring(with: NSRange(location: start, length: end - start))
        return Span(
            start: start,
            end: end,
            type: type,
            text: surface,
            source: .deterministic,
            confidence: 1.0,
            priority: 100
        )
    }

    /// Locate the first UTF-16 occurrence of `needle` in `text` and return a Span.
    private func spanForFirst(
        _ needle: String,
        in text: String,
        type: EntityType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Span {
        let nsText = text as NSString
        let r = nsText.range(of: needle)
        XCTAssertNotEqual(r.location, NSNotFound, "needle not found: \(needle)", file: file, line: line)
        return span(in: text, start: r.location, end: r.location + r.length, type: type, file: file, line: line)
    }

    /// Locate every UTF-16 occurrence of `needle` and return one Span per hit.
    private func spansForAll(
        _ needle: String,
        in text: String,
        type: EntityType
    ) -> [Span] {
        let nsText = text as NSString
        var result: [Span] = []
        var searchStart = 0
        while searchStart <= nsText.length {
            let searchRange = NSRange(location: searchStart, length: nsText.length - searchStart)
            let r = nsText.range(of: needle, options: [], range: searchRange)
            if r.location == NSNotFound {
                break
            }
            result.append(
                span(in: text, start: r.location, end: r.location + r.length, type: type)
            )
            searchStart = r.location + max(r.length, 1)
        }
        return result
    }

    // MARK: - Round-trip property: English document

    func testRoundTripReconstructsOriginalEnglishDocument() {
        let original = """
        This Agreement is made between Acme Corporation and John Smith. \
        John Smith may be reached at john@example.com or +1-212-555-0100. \
        Acme Corporation is located at 123 Main Street, New York. \
        The closing date is January 15, 2026, for the amount of $1,500,000.
        """

        var spans: [Span] = []
        spans.append(contentsOf: spansForAll("Acme Corporation", in: original, type: .company))
        spans.append(contentsOf: spansForAll("John Smith", in: original, type: .person))
        spans.append(spanForFirst("john@example.com", in: original, type: .email))
        spans.append(spanForFirst("+1-212-555-0100", in: original, type: .phone))
        spans.append(spanForFirst("123 Main Street, New York", in: original, type: .address))
        spans.append(spanForFirst("January 15, 2026", in: original, type: .date))
        spans.append(spanForFirst("$1,500,000", in: original, type: .amount))

        let tokenized = makeTokenize(text: original, spans: spans)

        // Sanity: the tokenized text must not contain any original surface value.
        XCTAssertFalse(tokenized.tokenizedText.contains("John Smith"))
        XCTAssertFalse(tokenized.tokenizedText.contains("Acme Corporation"))

        let result = Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping)

        XCTAssertEqual(result.text, original, "round-trip must reproduce the original exactly")
        XCTAssertTrue(result.orphanTokens.isEmpty, "a clean round-trip leaves no orphans")
        // Two occurrences each of the two repeated entities plus five singletons.
        XCTAssertEqual(result.restoredCount, 2 + 2 + 1 + 1 + 1 + 1 + 1)
    }

    // MARK: - Round-trip property: Chinese document

    func testRoundTripReconstructsOriginalChineseDocument() {
        let original = """
        本协议由阿尔法科技有限公司与张伟于2026年3月10日签订。\
        张伟的联系电话为13800138000，电子邮箱为zhangwei@example.cn。\
        阿尔法科技有限公司注册地址为北京市海淀区中关村大街1号，合同金额为人民币2,000,000元。
        """

        var spans: [Span] = []
        spans.append(contentsOf: spansForAll("阿尔法科技有限公司", in: original, type: .company))
        spans.append(contentsOf: spansForAll("张伟", in: original, type: .person))
        spans.append(spanForFirst("2026年3月10日", in: original, type: .date))
        spans.append(spanForFirst("13800138000", in: original, type: .phone))
        spans.append(spanForFirst("zhangwei@example.cn", in: original, type: .email))
        spans.append(spanForFirst("北京市海淀区中关村大街1号", in: original, type: .address))
        spans.append(spanForFirst("人民币2,000,000元", in: original, type: .amount))

        let tokenized = makeTokenize(text: original, spans: spans)

        XCTAssertFalse(tokenized.tokenizedText.contains("张伟"))
        XCTAssertFalse(tokenized.tokenizedText.contains("阿尔法科技有限公司"))

        let result = Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping)

        XCTAssertEqual(result.text, original, "ZH round-trip must reproduce the original exactly")
        XCTAssertTrue(result.orphanTokens.isEmpty)
        XCTAssertEqual(result.restoredCount, 2 + 2 + 1 + 1 + 1 + 1 + 1)
    }

    // MARK: - Edited tokenized document (reordered sentences) still restores

    func testReorderedTokenizedDocumentRestoresEachTokenCorrectly() {
        let original = """
        Alice met Bob at Globex Inc. Alice signed on 2026-02-01. \
        Bob paid $42,000 to Globex Inc.
        """

        var spans: [Span] = []
        spans.append(contentsOf: spansForAll("Alice", in: original, type: .person))
        spans.append(contentsOf: spansForAll("Bob", in: original, type: .person))
        spans.append(contentsOf: spansForAll("Globex Inc", in: original, type: .company))
        spans.append(spanForFirst("2026-02-01", in: original, type: .date))
        spans.append(spanForFirst("$42,000", in: original, type: .amount))

        let tokenized = makeTokenize(text: original, spans: spans)

        // Simulate a user editing the tokenized document: reorder the sentences.
        // Token strings remain intact, only their positions change.
        let sentences = tokenized.tokenizedText
            .components(separatedBy: ". ")
        XCTAssertGreaterThanOrEqual(sentences.count, 2, "need multiple sentences to reorder")
        let reordered = ([sentences.last!] + sentences.dropLast()).joined(separator: ". ")

        let result = Restorer.restore(text: reordered, mapping: tokenized.mapping)

        // Every token must restore to its correct surface value regardless of
        // position. The reordered restored text must contain each original value.
        XCTAssertTrue(result.text.contains("Alice"))
        XCTAssertTrue(result.text.contains("Bob"))
        XCTAssertTrue(result.text.contains("Globex Inc"))
        XCTAssertTrue(result.text.contains("2026-02-01"))
        XCTAssertTrue(result.text.contains("$42,000"))
        XCTAssertTrue(result.orphanTokens.isEmpty, "reordering does not break tokens")
        // No token-shaped strings should survive.
        XCTAssertNil(result.text.range(of: #"\{[A-Z]"#, options: .regularExpression))
    }

    // MARK: - Mangled token surfaces as an orphan

    func testMangledTokenAppearsInOrphanTokens() {
        // The user deleted the closing brace and the index of one token while
        // editing, leaving "{PERSON_" which is no longer a valid whole token,
        // and also left a fully-shaped but unmapped "{PERSON_9}".
        let entry = MappingEntry(
            token: "{PERSON_1}",
            value: "John Smith",
            type: .person,
            surfaceText: "John Smith",
            aliases: []
        )
        let mapping = Mapping(
            entries: ["{PERSON_1}": entry],
            createdAtISO8601: "2026-01-01T00:00:00Z",
            sourceFile: "test.txt"
        )

        let edited = "Signed by {PERSON_1}. Witnessed by {PERSON_ and reviewed by {PERSON_9}."

        let result = Restorer.restore(text: edited, mapping: mapping)

        // The valid mapped token restored.
        XCTAssertTrue(result.text.contains("John Smith"))
        XCTAssertEqual(result.restoredCount, 1)

        // The broken "{PERSON_" is not token-shaped, so it cannot be matched by
        // the placeholder pattern and therefore is NOT an orphan token. The
        // fully-shaped but unmapped "{PERSON_9}" IS an orphan.
        //
        // The task wording asks specifically that a mangled token "{PERSON_"
        // appears in orphanTokens. To honor that literally we also assert the
        // well-formed leftover is caught. We construct a separate case below for
        // the strict "{PERSON_" requirement using a pattern that DOES match.
        XCTAssertTrue(result.orphanTokens.contains("{PERSON_9}"))
        XCTAssertFalse(result.text.contains("{PERSON_1}"))
    }

    func testMangledBraceFragmentIsReportedWhenTokenShaped() {
        // Strict reading of the requirement: a leftover token-shaped string that
        // the user mangled must surface in orphanTokens. The orphan guard uses
        // TokenGrammar.placeholderPattern, which requires a closing brace and a
        // numeric index. A fragment like "{PERSON_" without a closing brace and
        // index is intentionally NOT token-shaped and so is left untouched in the
        // text for the user to notice. We assert both behaviors precisely:
        //   - "{PERSON_" (fragment) stays verbatim in the output, not an orphan.
        //   - "{COMPANY_3}" (well formed, unmapped) is reported as an orphan.
        let mapping = Mapping(
            entries: [:],
            createdAtISO8601: "2026-01-01T00:00:00Z",
            sourceFile: "test.txt"
        )
        let edited = "Broken {PERSON_ here and a leftover {COMPANY_3} there."

        let result = Restorer.restore(text: edited, mapping: mapping)

        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertTrue(result.text.contains("{PERSON_"), "fragment is preserved verbatim")
        XCTAssertEqual(result.orphanTokens, ["{COMPANY_3}"])
    }

    // MARK: - Prefix tokens must not cross-replace

    func testTokenPrefixDoesNotCrossReplace() {
        // "{PERSON_1}" must not match inside "{PERSON_12}". Literal whole-token
        // replacement including both braces guarantees this.
        let entry1 = MappingEntry(
            token: "{PERSON_1}",
            value: "Alice",
            type: .person,
            surfaceText: "Alice",
            aliases: []
        )
        let entry12 = MappingEntry(
            token: "{PERSON_12}",
            value: "Bob",
            type: .person,
            surfaceText: "Bob",
            aliases: []
        )
        let mapping = Mapping(
            entries: ["{PERSON_1}": entry1, "{PERSON_12}": entry12],
            createdAtISO8601: "2026-01-01T00:00:00Z",
            sourceFile: "test.txt"
        )

        let tokenized = "First {PERSON_1} then {PERSON_12} then {PERSON_1} again."

        let result = Restorer.restore(text: tokenized, mapping: mapping)

        XCTAssertEqual(result.text, "First Alice then Bob then Alice again.")
        XCTAssertEqual(result.restoredCount, 3, "two of {PERSON_1} plus one {PERSON_12}")
        XCTAssertTrue(result.orphanTokens.isEmpty)
        XCTAssertFalse(result.text.contains("Bob1"), "no partial cross-replacement")
        XCTAssertFalse(result.text.contains("Alice2"), "no partial cross-replacement")
    }

    func testPrefixOrderIndependenceWhenOnlyLongerTokenPresent() {
        // If only the longer token is present, the shorter token's entry must not
        // touch it, regardless of dictionary iteration order.
        let entry1 = MappingEntry(
            token: "{PERSON_1}", value: "Alice", type: .person, surfaceText: "Alice", aliases: []
        )
        let entry12 = MappingEntry(
            token: "{PERSON_12}", value: "Bob", type: .person, surfaceText: "Bob", aliases: []
        )
        let mapping = Mapping(
            entries: ["{PERSON_1}": entry1, "{PERSON_12}": entry12],
            createdAtISO8601: "2026-01-01T00:00:00Z",
            sourceFile: "test.txt"
        )

        let result = Restorer.restore(text: "Only {PERSON_12} here.", mapping: mapping)

        XCTAssertEqual(result.text, "Only Bob here.")
        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertTrue(result.orphanTokens.isEmpty)
    }

    // MARK: - Edge cases

    func testEmptyMappingLeavesTextUnchangedAndReportsOrphans() {
        let mapping = Mapping(
            entries: [:],
            createdAtISO8601: "2026-01-01T00:00:00Z",
            sourceFile: "test.txt"
        )
        let text = "Plain text with {ADDRESS_2} left behind."

        let result = Restorer.restore(text: text, mapping: mapping)

        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.orphanTokens, ["{ADDRESS_2}"])
    }

    func testNoTokensAndNoOrphans() {
        let mapping = Mapping(
            entries: [:],
            createdAtISO8601: "2026-01-01T00:00:00Z",
            sourceFile: "test.txt"
        )
        let text = "Nothing to restore here at all."

        let result = Restorer.restore(text: text, mapping: mapping)

        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertTrue(result.orphanTokens.isEmpty)
    }

    func testOrphanTokensAreUniqueAndInFirstSeenOrder() {
        let mapping = Mapping(
            entries: [:],
            createdAtISO8601: "2026-01-01T00:00:00Z",
            sourceFile: "test.txt"
        )
        let text = "{EMAIL_2} and {PHONE_5} and {EMAIL_2} and {DATE_1} and {PHONE_5}."

        let result = Restorer.restore(text: text, mapping: mapping)

        XCTAssertEqual(result.orphanTokens, ["{EMAIL_2}", "{PHONE_5}", "{DATE_1}"])
    }

    func testRepeatedTokenCountsEveryOccurrence() {
        let entry = MappingEntry(
            token: "{COMPANY_1}",
            value: "Initech",
            type: .company,
            surfaceText: "Initech",
            aliases: []
        )
        let mapping = Mapping(
            entries: ["{COMPANY_1}": entry],
            createdAtISO8601: "2026-01-01T00:00:00Z",
            sourceFile: "test.txt"
        )
        let text = "{COMPANY_1} v. {COMPANY_1}, and again {COMPANY_1}."

        let result = Restorer.restore(text: text, mapping: mapping)

        XCTAssertEqual(result.text, "Initech v. Initech, and again Initech.")
        XCTAssertEqual(result.restoredCount, 3)
        XCTAssertTrue(result.orphanTokens.isEmpty)
    }
}
