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

    func testMalformedUnbalancedJSONReturnsEmpty() {
        let output = #"{"entities":[{"value":"Jane","type":"PERSON"}"#

        XCTAssertEqual(EntityJSONParser.parse(output), [])
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
}
