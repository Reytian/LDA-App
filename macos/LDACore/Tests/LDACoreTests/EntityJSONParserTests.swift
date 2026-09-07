//
//  EntityJSONParserTests.swift
//  LDACoreTests
//
//  Tests for EntityJSONParser.parse: it robustly extracts entities from the v2
//  model's raw text output across clean object, bare array, prose-wrapped, and
//  fenced code block shapes, maps types case-insensitively, skips empty values,
//  and returns [] on garbage. Fixtures are hermetic string literals.
//
//  House rules: English only, no em-dash and no en-dash-as-separator.
//

import XCTest
@testable import LDACore

final class EntityJSONParserTests: XCTestCase {

    // MARK: Clean object shape

    func testCleanObjectShapeWithEntitiesAndRedactedText() {
        let output = """
        {"entities":[{"value":"Jane Roe","type":"PERSON"},\
        {"value":"Acme Corporation","type":"COMPANY"}],\
        "redacted_text":"{PERSON_1} works at {COMPANY_1}."}
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Jane Roe", type: .person),
            ExtractedEntity(value: "Acme Corporation", type: .company)
        ])
    }

    // MARK: Bare array shape

    func testBareArrayOfEntities() {
        let output = """
        [{"value":"John Doe","type":"PERSON"},\
        {"value":"123 Main St, Albany NY","type":"ADDRESS"}]
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "John Doe", type: .person),
            ExtractedEntity(value: "123 Main St, Albany NY", type: .address)
        ])
    }

    // MARK: JSON wrapped in prose

    func testJSONWrappedInProse() {
        let output = """
        Sure, here are the entities I found in the document:
        {"entities":[{"value":"Maria Chen","type":"PERSON"}],\
        "redacted_text":"{PERSON_1} signed."}
        Let me know if you need anything else.
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Maria Chen", type: .person)
        ])
    }

    // MARK: JSON in a fenced code block

    func testJSONInFencedCodeBlock() {
        let output = """
        Here is the result:
        ```json
        {"entities":[{"value":"Globex LLC","type":"COMPANY"}],\
        "redacted_text":"{COMPANY_1}"}
        ```
        Done.
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Globex LLC", type: .company)
        ])
    }

    func testBareArrayInFencedCodeBlockWithoutLanguageTag() {
        let output = """
        ```
        [{"value":"Sam Patel","type":"PERSON"}]
        ```
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Sam Patel", type: .person)
        ])
    }

    // MARK: Case-insensitive type mapping

    func testCaseInsensitiveTypeMapping() {
        let output = """
        [{"value":"Jane Roe","type":"person"},\
        {"value":"Acme","type":"Company"},\
        {"value":"1 Plaza","type":"address"},\
        {"value":"a@b.com","type":"email"},\
        {"value":"+1 555 0100","type":"Phone"},\
        {"value":"Jan 1 2024","type":"date"},\
        {"value":"$10","type":"amount"},\
        {"value":"X1","type":"national_id"},\
        {"value":"91110000","type":"uscc"},\
        {"value":"0001","type":"bank_account"}]
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities.map { $0.type }, [
            .person, .company, .address, .email, .phone,
            .date, .amount, .nationalID, .uscc, .bankAccount
        ])
    }

    func testUnknownTypeMapsToUnknown() {
        let output = #"[{"value":"mystery","type":"SOMETHING_ELSE"}]"#

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "mystery", type: .unknown)
        ])
    }

    func testMissingTypeMapsToUnknown() {
        let output = #"[{"value":"no type field"}]"#

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "no type field", type: .unknown)
        ])
    }

    // MARK: Empty-value skipping

    func testEmptyValueEntitiesAreSkipped() {
        let output = """
        [{"value":"","type":"PERSON"},\
        {"value":"   ","type":"COMPANY"},\
        {"value":"Real Name","type":"PERSON"}]
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Real Name", type: .person)
        ])
    }

    func testEntriesMissingValueAreSkipped() {
        let output = """
        [{"type":"PERSON"},{"value":"Kept","type":"PERSON"}]
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Kept", type: .person)
        ])
    }

    // MARK: Garbage input

    func testGarbageInputReturnsEmpty() {
        XCTAssertEqual(EntityJSONParser.parse("this is not json at all"), [])
    }

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(EntityJSONParser.parse(""), [])
    }

    func testTruncatedJSONSalvagesCompleteLeadingEntities() {
        // A completion cut off mid-array (the model hit its token cap) is NOT
        // genuine emptiness: one complete entity object was already emitted before
        // the cut. The salvage path (LJE-001) must recover it rather than discard
        // the whole payload. (This previously asserted [], which encoded the
        // silent-leak bug; it is updated intentionally now that parse salvages.)
        let output = #"{"entities":[{"value":"Jane","type":"PERSON"}"#

        XCTAssertEqual(
            EntityJSONParser.parse(output),
            [ExtractedEntity(value: "Jane", type: .person)]
        )
    }

    func testEmptyEntitiesArrayReturnsEmpty() {
        XCTAssertEqual(
            EntityJSONParser.parse(#"{"entities":[],"redacted_text":"x"}"#),
            []
        )
    }

    // MARK: Brace-matching fallback with braces inside string values

    func testBracesInsideStringValuesDoNotBreakScan() {
        // The redacted_text contains literal braces from tokens. A naive depth
        // count that ignores string literals would mis-balance here; the parser
        // must still recover the entities.
        let output = """
        Result below.
        {"entities":[{"value":"Lee Wong","type":"PERSON"}],\
        "redacted_text":"Token {PERSON_1} and {COMPANY_2} appear here."}
        Trailing prose.
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Lee Wong", type: .person)
        ])
    }

    // MARK: Realistic multi-entity sample

    func testRealisticMultiEntitySample() {
        let output = """
        I have analyzed the engagement letter. Here is the JSON:

        ```json
        {
          "entities": [
            {"value": "Margaret O'Brien", "type": "PERSON"},
            {"value": "Sterling & Cooper LLP", "type": "COMPANY"},
            {"value": "450 Park Avenue, New York, NY 10022", "type": "ADDRESS"},
            {"value": "margaret.obrien@sterlingcooper.com", "type": "EMAIL"},
            {"value": "+1 (212) 555-0173", "type": "PHONE"},
            {"value": "March 14, 2024", "type": "DATE"},
            {"value": "$25,000.00", "type": "AMOUNT"},
            {"value": "", "type": "PERSON"}
          ],
          "redacted_text": "{PERSON_1} of {COMPANY_1} at {ADDRESS_1}."
        }
        ```

        That covers all the sensitive fields.
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Margaret O'Brien", type: .person),
            ExtractedEntity(value: "Sterling & Cooper LLP", type: .company),
            ExtractedEntity(
                value: "450 Park Avenue, New York, NY 10022",
                type: .address
            ),
            ExtractedEntity(
                value: "margaret.obrien@sterlingcooper.com",
                type: .email
            ),
            ExtractedEntity(value: "+1 (212) 555-0173", type: .phone),
            ExtractedEntity(value: "March 14, 2024", type: .date),
            ExtractedEntity(value: "$25,000.00", type: .amount)
        ])
    }

    // MARK: LJE-002: largest balanced region, not the first

    func testStrayBalancedBraceBeforeRealObjectStillRecoversEntities() {
        // A chatty reasoning model prefixes its JSON with prose that itself
        // contains a small balanced brace pair and a small balanced bracket pair.
        // The first balanced {..} is the prose noise; the real entities object is
        // larger and comes later. The parser must reach the real payload.
        let output = """
        Here is a list [item one, item two] and a note {ignore this}.
        {"entities":[{"value":"Jane Roe","type":"PERSON"},\
        {"value":"Acme Corp","type":"COMPANY"}],"redacted_text":"x"}
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Jane Roe", type: .person),
            ExtractedEntity(value: "Acme Corp", type: .company)
        ])
    }

    func testRealisticReasoningProseWithStrayPunctuationRecoversEntities() {
        let output = """
        The parties [Buyer, Seller, Guarantor] are identified below; terms \
        {as set out in Schedule A} apply.
        {"entities":[{"value":"Jane Roe","type":"PERSON"},\
        {"value":"Acme Corp","type":"COMPANY"}],"redacted_text":"x"}
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Jane Roe", type: .person),
            ExtractedEntity(value: "Acme Corp", type: .company)
        ])
    }

    // MARK: LJE-003: decode the raw output before stripping code fences

    func testBacktickInsideStringValueDoesNotMangleValidJSON() {
        // A valid JSON object whose redacted_text value literally contains a "```"
        // sequence. stripCodeFences must NOT treat that inner backtick run as an
        // opening fence; the raw valid JSON must decode first.
        let output = """
        {"entities":[{"value":"Jane Roe","type":"PERSON"}],\
        "redacted_text":"see ```code``` block {PERSON_1}"}
        """

        let entities = EntityJSONParser.parse(output)

        XCTAssertEqual(entities, [
            ExtractedEntity(value: "Jane Roe", type: .person)
        ])
    }

    // MARK: LJE-001: parseDetailed distinguishes truncation from emptiness

    func testParseDetailedSalvagesLeadingEntitiesAndSignalsTruncation() {
        // Five complete entity objects, then a sixth cut off at the token cap.
        // The salvage path must recover all five AND report truncation.
        let output = """
        {"entities":[\
        {"value":"Jane Roe","type":"PERSON"},\
        {"value":"Acme Corporation","type":"COMPANY"},\
        {"value":"450 Park Avenue","type":"ADDRESS"},\
        {"value":"John Smith","type":"PERSON"},\
        {"value":"Globex LLC","type":"COMPANY"},\
        {"value":"Maria Ch
        """

        let result = EntityJSONParser.parseDetailed(output)

        XCTAssertEqual(result.entities, [
            ExtractedEntity(value: "Jane Roe", type: .person),
            ExtractedEntity(value: "Acme Corporation", type: .company),
            ExtractedEntity(value: "450 Park Avenue", type: .address),
            ExtractedEntity(value: "John Smith", type: .person),
            ExtractedEntity(value: "Globex LLC", type: .company)
        ])
        XCTAssertTrue(result.truncated, "a cut-off completion must signal truncation")
    }

    func testParseDetailedOnCompleteJSONIsNotTruncated() {
        let output = """
        {"entities":[{"value":"Jane Roe","type":"PERSON"},\
        {"value":"Acme Corp","type":"COMPANY"}],"redacted_text":"x"}
        """

        let result = EntityJSONParser.parseDetailed(output)

        XCTAssertEqual(result.entities, [
            ExtractedEntity(value: "Jane Roe", type: .person),
            ExtractedEntity(value: "Acme Corp", type: .company)
        ])
        XCTAssertFalse(result.truncated, "well-formed JSON must not be flagged as truncated")
    }

    func testParseDetailedSignalsTruncationWhenArrayNeverCloses() {
        // The completion ended right after a complete object but before the
        // closing "]" (and "}"). The object is recovered, and because the array
        // never closed this must still be flagged truncated so the extractor
        // retries rather than treating it as a fully-scanned result.
        let output = #"{"entities":[{"value":"Jane Roe","type":"PERSON"}"#

        let result = EntityJSONParser.parseDetailed(output)

        XCTAssertEqual(result.entities, [ExtractedEntity(value: "Jane Roe", type: .person)])
        XCTAssertTrue(result.truncated, "an array that never closed must be flagged truncated")
    }

    func testParseDetailedOnGenuinelyEmptyIsNotTruncated() {
        // The model genuinely found no PII: empty entities, well-formed. This must
        // stay empty AND not be flagged as truncated, so a clean document is not
        // mislabeled incomplete.
        let result = EntityJSONParser.parseDetailed(#"{"entities":[],"redacted_text":"x"}"#)

        XCTAssertEqual(result.entities, [])
        XCTAssertFalse(result.truncated, "genuine emptiness is not truncation")
    }

    func testParseDetailedOnGarbageIsInvalidNotTruncatedAndNotEmpty() {
        // Non-JSON prose with no entities array is not a mid-array cut, so it must
        // not claim truncation (no leading entities exist to lose). It is also not
        // genuine emptiness: the model never answered about the text, and the
        // extractor must treat the segment as unscanned, not as clean.
        let result = EntityJSONParser.parseDetailed("this is not json at all")

        XCTAssertEqual(result.entities, [])
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(result.invalid, "prose is a non-answer, not an empty entities array")
        XCTAssertFalse(result.isComplete)
    }

    func testParseDetailedDistinguishesTheThreeStates() {
        let refusal = EntityJSONParser.parseDetailed("I cannot process this text.")
        XCTAssertTrue(refusal.invalid)
        XCTAssertFalse(refusal.truncated)

        let empty = EntityJSONParser.parseDetailed("")
        XCTAssertTrue(empty.invalid, "an empty completion is not an empty entities array")

        let otherShape = EntityJSONParser.parseDetailed(#"{"error":"context window exceeded"}"#)
        XCTAssertTrue(otherShape.invalid, "valid JSON without an entities array is a schema failure")

        let bareStrings = EntityJSONParser.parseDetailed(#"["no entities"]"#)
        XCTAssertTrue(bareStrings.invalid, "a bare array must consist of entity objects")

        let cut = EntityJSONParser.parseDetailed(#"{"entities":[{"value":"Jane Roe","type":"PERSON"},{"value":"Ac"#)
        XCTAssertTrue(cut.truncated)
        XCTAssertFalse(cut.invalid)

        let none = EntityJSONParser.parseDetailed(#"{"entities":[],"redacted_text":"x"}"#)
        XCTAssertTrue(none.isComplete, "an empty entities array is a complete, clean answer")

        let bareEmpty = EntityJSONParser.parseDetailed("[]")
        XCTAssertTrue(bareEmpty.isComplete)

        let fenced = EntityJSONParser.parseDetailed("```json\n{\"entities\":[]}\n```")
        XCTAssertTrue(fenced.isComplete, "a fenced empty array is still a complete answer")
    }

    func testEntitiesArrayWhoseObjectsCarryAnotherSchemaIsInvalid() {
        // Every object has content but none has a value: the model answered in
        // a different schema. That is not "found nothing", and treating it as
        // an empty finding would pass a document full of names as clean.
        let wrapped = EntityJSONParser.parseDetailed(
            #"{"entities":[{"text":"Jane Roe","label":"PERSON"},{"text":"Acme","label":"COMPANY"}]}"#
        )
        XCTAssertTrue(wrapped.invalid, "objects without a value are another schema, not an empty finding")
        XCTAssertEqual(wrapped.entities, [])

        let bare = EntityJSONParser.parseDetailed(#"[{"text":"Jane Roe","label":"PERSON"}]"#)
        XCTAssertTrue(bare.invalid)

        // A mixed list keeps the usable entries as SALVAGE but is not a
        // complete answer (R1). Calling it complete exported "Acme" in the
        // clear: the row was silently skipped and coverage still read full.
        let mixed = EntityJSONParser.parseDetailed(
            #"{"entities":[{"value":"Jane Roe","type":"PERSON"},{"text":"Acme","label":"COMPANY"}]}"#
        )
        XCTAssertFalse(mixed.isComplete, "one unreadable row leaves the segment partly classified")
        XCTAssertTrue(mixed.invalid)
        XCTAssertEqual(mixed.entities, [ExtractedEntity(value: "Jane Roe", type: .person)])
    }
}
