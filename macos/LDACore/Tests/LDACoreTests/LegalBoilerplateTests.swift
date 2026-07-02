//
//  LegalBoilerplateTests.swift
//  LDACoreTests
//
//  Verifies the boilerplate post-filter using the exact junk values the model
//  reported on the Meridian Works employment agreements, plus the real PII
//  values that must survive.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LegalBoilerplateTests: XCTestCase {

    // MARK: - Observed junk values must drop

    func testObservedPersonJunkIsDropped() {
        let junk: [String] = [
            "PRESIDENT", "CEO", "customers", "third party", "General Counsel",
            "other person", "suppliers", "licensors", "licensees",
            "collaborators", "Associated Third Parties", "Associated Third", "laint"
        ]
        for value in junk {
            XCTAssertTrue(
                LegalBoilerplate.shouldDrop(value, type: .person),
                "expected PERSON junk to drop: \(value)"
            )
        }
    }

    func testObservedCompanyJunkIsDropped() {
        let junk: [String] = [
            "AGREEMENT", "Company", "the Company", "Company Confidential Information",
            "Former Employer", "entity", "subsidiaries", "United States",
            "SARBANES-OXLEY ACT", "JAMS", "NEW YORK CIVIL PRACTICE LAWS AND RULES",
            "NEW YORK LAW", "Delaware", "State of New York", "Supreme Court"
        ]
        for value in junk {
            XCTAssertTrue(
                LegalBoilerplate.shouldDrop(value, type: .company),
                "expected COMPANY junk to drop: \(value)"
            )
        }
    }

    func testLowercaseGenericNounPhrasesDropForPersonAndCompany() {
        for value in ["laint", "customers and suppliers", "any other entity"] {
            XCTAssertTrue(LegalBoilerplate.shouldDrop(value, type: .person))
            XCTAssertTrue(LegalBoilerplate.shouldDrop(value, type: .company))
        }
    }

    func testTooShortValuesDrop() {
        XCTAssertTrue(LegalBoilerplate.shouldDrop("J", type: .person))
        XCTAssertTrue(LegalBoilerplate.shouldDrop("  ", type: .company))
        // Two-character surnames are real names and must stay redactable.
        XCTAssertFalse(LegalBoilerplate.shouldDrop("Li", type: .person))
        XCTAssertFalse(LegalBoilerplate.shouldDrop("Wu", type: .person))
    }

    // MARK: - Leak guards from adversarial review

    func testSurnamesThatAreAlsoHeadNounsSurviveAsPerson() {
        for value in ["Jonathan Law", "Margaret Court", "Ann Rule", "Nancy Plan"] {
            XCTAssertFalse(
                LegalBoilerplate.shouldDrop(value, type: .person),
                "real PERSON must survive: \(value)"
            )
        }
        // The COMPANY set still kills the observed statute junk.
        XCTAssertTrue(LegalBoilerplate.shouldDrop("NEW YORK LAW", type: .company))
        XCTAssertTrue(LegalBoilerplate.shouldDrop("Supreme Court", type: .company))
    }

    func testJurisdictionNamesSurviveAsPerson() {
        for value in ["Virginia", "Washington", "Georgia", "Montana"] {
            XCTAssertFalse(
                LegalBoilerplate.shouldDrop(value, type: .person),
                "PERSON name colliding with a jurisdiction must survive: \(value)"
            )
            XCTAssertTrue(
                LegalBoilerplate.shouldDrop(value, type: .company),
                "bare jurisdiction as COMPANY is boilerplate: \(value)"
            )
        }
    }

    func testRomanizedNamesEndingInShortSyllablesSurvive() {
        for value in ["Nguyen Van An", "Johnnie To", "Ronen Or", "Chan Kwok On"] {
            XCTAssertFalse(
                LegalBoilerplate.shouldDrop(value, type: .person),
                "romanized PERSON name must survive: \(value)"
            )
        }
    }

    func testOrdinalShortCompanyNamesSurvive() {
        XCTAssertFalse(LegalBoilerplate.shouldDrop("Fifth Third", type: .company))
        XCTAssertFalse(LegalBoilerplate.shouldDrop("Health First", type: .company))
    }

    func testStateOfPrefixOnlyDropsRealJurisdictions() {
        XCTAssertTrue(LegalBoilerplate.shouldDrop("State of New York", type: .company))
        XCTAssertTrue(LegalBoilerplate.shouldDrop("Commonwealth of Massachusetts", type: .company))
        XCTAssertFalse(LegalBoilerplate.shouldDrop("State of Mind Media", type: .company))
    }

    func testVenuePhrasesDrop() {
        for value in [
            "Southern District of New York",
            "United States District Court for the Southern District of New York",
            "Delaware Court of Chancery", "FINRA", "Attorney General"
        ] {
            XCTAssertTrue(
                LegalBoilerplate.shouldDrop(value, type: .company),
                "venue/agency boilerplate must drop: \(value)"
            )
        }
    }

    func testLowercaseDomainSurvives() {
        XCTAssertFalse(LegalBoilerplate.shouldDrop("meridianworks.com", type: .company))
    }

    func testEquityPlanTermsDropForCompanyButGrantSurvivesAsPerson() {
        for value in ["Units", "Shares", "Options", "Awards", "RSUs", "Restricted Stock Units"] {
            XCTAssertTrue(
                LegalBoilerplate.shouldDrop(value, type: .company),
                "equity-plan term must drop: \(value)"
            )
        }
        XCTAssertFalse(LegalBoilerplate.shouldDrop("Grant", type: .person))
        XCTAssertFalse(LegalBoilerplate.shouldDrop("Cary Grant", type: .person))
    }

    func testVenueCountyAndIRSCenterDrop() {
        XCTAssertTrue(LegalBoilerplate.shouldDrop("New York County", type: .company))
        XCTAssertTrue(LegalBoilerplate.shouldDrop("Internal Revenue Service Center", type: .company))
        // A county not named after a jurisdiction stays untouched.
        XCTAssertFalse(LegalBoilerplate.shouldDrop("Orange County Choppers", type: .company))
    }

    func testEmploymentStatuteShorthandsDropForCompanyButAdaSurvivesAsPerson() {
        for value in ["ADEA", "FMLA", "USERRA", "Title VII"] {
            XCTAssertTrue(
                LegalBoilerplate.shouldDrop(value, type: .company),
                "statute shorthand must drop: \(value)"
            )
        }
        XCTAssertTrue(LegalBoilerplate.shouldDrop("ADA", type: .company))
        XCTAssertFalse(LegalBoilerplate.shouldDrop("Ada", type: .person))
    }

    // MARK: - Real PII must survive

    func testRealPersonNamesSurvive() {
        for value in ["Jordan Lee", "Jordan Alexander Lee", "Rene\u{0301} Martin"] {
            XCTAssertFalse(
                LegalBoilerplate.shouldDrop(value, type: .person),
                "real PERSON must survive: \(value)"
            )
        }
    }

    func testRealCompanyNamesSurvive() {
        for value in [
            "Meridian Works, LLC", "Acme Holdings Inc.", "Beijing Kunlun Tech Co., Ltd.",
            "China Mobile Limited"
        ] {
            XCTAssertFalse(
                LegalBoilerplate.shouldDrop(value, type: .company),
                "real COMPANY must survive: \(value)"
            )
        }
    }

    func testCJKNamesSurvive() {
        // Two-character CJK personal names must not be dropped by the length
        // gate, and CJK-only values must not be dropped by the lowercase rule.
        XCTAssertFalse(LegalBoilerplate.shouldDrop("张三", type: .person))
        XCTAssertFalse(LegalBoilerplate.shouldDrop("上海某某科技有限公司", type: .company))
    }

    func testCJKGenericTermsDrop() {
        XCTAssertTrue(LegalBoilerplate.shouldDrop("公司", type: .company))
        XCTAssertTrue(LegalBoilerplate.shouldDrop("本协议", type: .company))
        XCTAssertTrue(LegalBoilerplate.shouldDrop("第三方", type: .person))
    }

    func testStreetAddressesSurviveTheAddressType() {
        // The instrument head-noun and lowercase rules apply to PERSON and
        // COMPANY only; a street address must never be dropped by them.
        XCTAssertFalse(LegalBoilerplate.shouldDrop(
            "1201 Third Avenue, Suite 2200, Seattle, WA 98101", type: .address
        ))
        // But a bare jurisdiction reported as an address is boilerplate.
        XCTAssertTrue(LegalBoilerplate.shouldDrop("United States", type: .address))
        XCTAssertTrue(LegalBoilerplate.shouldDrop("New York", type: .address))
    }

    func testFullNameContainingAStateWordSurvives() {
        // The geo list matches whole values only: a person named Washington
        // with a full name is not filtered.
        XCTAssertFalse(LegalBoilerplate.shouldDrop("Denzel Washington", type: .person))
    }

    func testRoleLabelsStillDropThroughThisFilter() {
        XCTAssertTrue(LegalBoilerplate.shouldDrop("Disclosing Party", type: .company))
        XCTAssertTrue(LegalBoilerplate.shouldDrop("甲方", type: .company))
    }

    func testFederalAgenciesDrop() {
        for value in [
            "Equal Employment Opportunity Commission", "EQUAL EMPLOYMENT OPPORTUNITY COMMISSION",
            "National Labor Relations Board", "Occupational Safety and Health Administration",
            "FAA", "OSHA", "NLRB", "the Securities and Exchange Commission"
        ] {
            XCTAssertTrue(
                LegalBoilerplate.shouldDrop(value, type: .company),
                "expected agency to drop: \(value)"
            )
        }
    }

    func testDocumentPartReferencesDropForAllTypes() {
        for value in ["Exhibit A", "EXHIBIT A", "Schedule 2", "Appendix B-1", "the Exhibit C"] {
            XCTAssertTrue(LegalBoilerplate.shouldDrop(value, type: .address), "expected drop: \(value)")
            XCTAssertTrue(LegalBoilerplate.shouldDrop(value, type: .company), "expected drop: \(value)")
        }
        // A real street address containing a long identifier is untouched.
        XCTAssertFalse(LegalBoilerplate.shouldDrop("Exhibit Street 22, Springfield", type: .address))
    }
}
