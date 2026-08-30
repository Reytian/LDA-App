//
//  SubstitutionStyleTests.swift
//  LDACoreTests
//
//  Tests for the SubstitutionStyle enum, the Mapping.style persistence
//  contract (old sidecars decode as .token), the per-type pseudonym schemes,
//  and the per-type asterisk masking rules.
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

// MARK: - Mapping.style persistence

final class SubstitutionStyleTests: XCTestCase {

    private func makeEntry() -> MappingEntry {
        MappingEntry(
            token: "{PERSON_1}",
            value: "John Smith",
            type: .person,
            surfaceText: "John Smith",
            aliases: []
        )
    }

    func testLegacyMappingJSONWithoutStyleDecodesAsToken() throws {
        // A sidecar payload written before styles existed has no "style" key.
        let legacyJSON = """
        {
          "entries": {},
          "createdAtISO8601": "2026-01-01T00:00:00Z",
          "sourceFile": "old.txt"
        }
        """
        let mapping = try JSONDecoder().decode(Mapping.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(mapping.style, .token)
    }

    func testMappingStyleSurvivesEncodeDecode() throws {
        for style in SubstitutionStyle.allCases {
            let entry = makeEntry()
            let mapping = Mapping(
                entries: [entry.token: entry],
                createdAtISO8601: "2026-08-30T00:00:00Z",
                sourceFile: "doc.txt",
                style: style
            )
            let data = try JSONEncoder().encode(mapping)
            let decoded = try JSONDecoder().decode(Mapping.self, from: data)
            XCTAssertEqual(decoded.style, style)
            XCTAssertEqual(decoded, mapping)
        }
    }

    func testMappingDefaultStyleIsToken() {
        let mapping = Mapping(entries: [:], createdAtISO8601: "t", sourceFile: "f")
        XCTAssertEqual(mapping.style, .token)
    }

    func testMappingStoreRoundTripsStyle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("style-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let entry = makeEntry()
        let mapping = Mapping(
            entries: [entry.token: entry],
            createdAtISO8601: "2026-08-30T00:00:00Z",
            sourceFile: "doc.txt",
            style: .pseudonym
        )
        let url = dir.appendingPathComponent("doc.ldamap")
        try MappingStore.save(mapping, to: url, protection: .passphrase("style-test"))
        let loaded = try MappingStore.load(from: url, protection: .passphrase("style-test"))
        XCTAssertEqual(loaded.style, .pseudonym)
    }
}

// MARK: - Pseudonym generation

final class PseudonymGeneratorTests: XCTestCase {

    /// Mint `count` pseudonyms of one type with nothing blocked, using a
    /// per-call surface so the script is chosen from the given sample.
    private func mint(
        _ type: EntityType,
        surface: String,
        count: Int
    ) -> [String] {
        var generator = PseudonymGenerator()
        return (0..<count).map { _ in
            generator.mint(type: type, surface: surface, isTaken: { _ in false })
        }
    }

    func testChineseCompanySequenceUsesHeavenlyStems() {
        let names = mint(.company, surface: "\u{6DF1}\u{5733}\u{79D1}\u{6280}\u{6709}\u{9650}\u{516C}\u{53F8}", count: 12)
        XCTAssertEqual(Array(names.prefix(3)), ["甲公司", "乙公司", "丙公司"])
        XCTAssertEqual(names[9], "癸公司")
        // After the ten stems, the numbered second cycle starts.
        XCTAssertEqual(names[10], "甲一公司")
        XCTAssertEqual(names[11], "乙一公司")
    }

    func testChinesePersonSequenceUsesSurnamePlaceholders() {
        let names = mint(.person, surface: "王小明", count: 3)
        XCTAssertEqual(names, ["张某", "李某", "王某"])
    }

    func testChineseAddressSequenceUsesLetterSuffixes() {
        let names = mint(.address, surface: "北京市朝阳区建国路88号", count: 2)
        XCTAssertEqual(names, ["某地址A", "某地址B"])
    }

    func testChineseGenericFallbacksAreTypeLabeled() {
        XCTAssertEqual(mint(.date, surface: "2026年3月18日", count: 1), ["某日期1"])
        XCTAssertEqual(mint(.amount, surface: "人民币100万元", count: 1), ["某金额1"])
        XCTAssertEqual(mint(.unknown, surface: "机密项目代号", count: 2), ["某某1", "某某2"])
    }

    func testEmailSchemeIsAlwaysLatin() {
        let names = mint(.email, surface: "zhang.san@company.cn", count: 2)
        XCTAssertEqual(names, ["contact1@example.com", "contact2@example.com"])
    }

    func testEnglishSchemesForLatinSurfaces() {
        XCTAssertEqual(mint(.company, surface: "Acme Corp", count: 2), ["Company A", "Company B"])
        XCTAssertEqual(mint(.person, surface: "John Smith", count: 1), ["Person A"])
        XCTAssertEqual(mint(.address, surface: "1 Main St", count: 1), ["Address A"])
        XCTAssertEqual(mint(.phone, surface: "13812345678", count: 1), ["Phone 1"])
        XCTAssertEqual(mint(.nationalID, surface: "110101199001011234", count: 1), ["ID 1"])
        XCTAssertEqual(mint(.date, surface: "12 March 2026", count: 1), ["Date 1"])
    }

    func testGeneratorSkipsTakenCandidates() {
        // The document already contains the literal 甲公司, so the generator
        // must skip to 乙公司.
        var generator = PseudonymGenerator()
        let document = "本合同由甲公司代表签署。"
        let minted = generator.mint(
            type: .company,
            surface: "深圳创新科技有限公司",
            isTaken: { document.contains($0) }
        )
        XCTAssertEqual(minted, "乙公司")
    }

    func testScriptIsChosenPerSurface() {
        var generator = PseudonymGenerator()
        let zh = generator.mint(type: .company, surface: "上海某某公司", isTaken: { _ in false })
        let en = generator.mint(type: .company, surface: "Acme Corp", isTaken: { _ in false })
        XCTAssertEqual(zh, "甲公司")
        XCTAssertEqual(en, "Company A")
    }
}

// MARK: - Asterisk masking

final class AsteriskMaskingTests: XCTestCase {

    func testChinesePersonNamesFollowPRCConvention() {
        XCTAssertEqual(AsteriskMasking.mask("张三", type: .person), "张*")
        XCTAssertEqual(AsteriskMasking.mask("张伟明", type: .person), "张*明")
        XCTAssertEqual(AsteriskMasking.mask("欧阳娜娜", type: .person), "欧**娜")
    }

    func testLatinPersonNamesKeepInitials() {
        XCTAssertEqual(AsteriskMasking.mask("John Smith", type: .person), "J*** S****")
    }

    func testPhoneKeepsFirstThreeAndLastFour() {
        XCTAssertEqual(AsteriskMasking.mask("13812345678", type: .phone), "138****5678")
    }

    func testNationalIDKeepsFirstThreeAndLastTwo() {
        XCTAssertEqual(
            AsteriskMasking.mask("110101199001011234", type: .nationalID),
            "110" + String(repeating: "*", count: 13) + "34"
        )
    }

    func testGenericStringsMaskTheMiddleSixtyPercent() {
        // 12 characters: keep floor(12 * 0.2) = 2 on each side, mask 8.
        XCTAssertEqual(
            AsteriskMasking.mask("阿里巴巴网络技术有限公司", type: .company),
            "阿里" + String(repeating: "*", count: 8) + "公司"
        )
    }

    func testShortStringsAreFullyMasked() {
        XCTAssertEqual(AsteriskMasking.mask("AB", type: .company), "**")
        XCTAssertEqual(AsteriskMasking.mask("X", type: .amount), "*")
    }

    func testMaskAlwaysHidesAtLeastOneCharacter() {
        let samples: [(String, EntityType)] = [
            ("张三", .person),
            ("J", .person),
            ("13812345678", .phone),
            ("110101199001011234", .nationalID),
            ("hello@example.com", .email),
            ("2026-03-18", .date),
            ("北京市海淀区中关村大街1号", .address)
        ]
        for (surface, type) in samples {
            let masked = AsteriskMasking.mask(surface, type: type)
            XCTAssertNotEqual(masked, surface, "mask must never return the input unchanged")
            XCTAssertTrue(masked.contains("*"), "mask must contain the mask character")
        }
    }

    func testMaskPreservesCharacterCountForSensitiveDigits() {
        // Per-character masking keeps the surface length recognizable, which
        // is the convention courts and regulators expect for numbers.
        XCTAssertEqual(
            AsteriskMasking.mask("13812345678", type: .phone).count,
            "13812345678".count
        )
    }
}
