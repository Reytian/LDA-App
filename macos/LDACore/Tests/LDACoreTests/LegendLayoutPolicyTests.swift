//
//  LegendLayoutPolicyTests.swift
//  LDACoreTests
//
//  The document pane legend: which types it lists (present in this document,
//  in sidebar order, with the same distinct-value count the sidebar header
//  shows), how it collapses (labeled chips, compact dots, or one menu button,
//  forced to the menu on a narrow window), where the overflow chip starts,
//  and the strings that make it readable without color.
//
//  House rules: English only. Fixture strings may be Chinese. No em-dash or
//  en-dash-as-separator.
//

import XCTest
@testable import LDAUI
import LDACore

@MainActor
final class LegendLayoutPolicyTests: XCTestCase {

    private static let text = "张三 and 张三 met 李四 at Acme on 2026-03-01 and 2026-03-02."

    private static func entity(_ surface: String, _ type: EntityType, occurrence: Int = 0, accepted: Bool = true) -> ReviewEntity {
        let ns = text as NSString
        var searchStart = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = ns.range(of: surface, range: NSRange(location: searchStart, length: ns.length - searchStart))
            precondition(found.location != NSNotFound, "fixture surface missing: \(surface)")
            searchStart = found.location + found.length
        }
        return ReviewEntity(
            span: Span(start: found.location, end: NSMaxRange(found), type: type, text: surface, source: .llm, confidence: 0.9, priority: 30),
            accepted: accepted
        )
    }

    private func makeModel() -> ReviewModel {
        let model = ReviewModel(modelPath: nil)
        model.documentText = Self.text
        model.entities = [
            Self.entity("张三", .person, occurrence: 0),
            Self.entity("张三", .person, occurrence: 1),
            Self.entity("李四", .person, accepted: false),
            Self.entity("Acme", .company, accepted: false),
            Self.entity("2026-03-01", .date),
            Self.entity("2026-03-02", .date, accepted: false)
        ]
        return model
    }

    // MARK: - Items

    func testItemsListPresentTypesInSidebarOrderWithDistinctValueCounts() {
        let model = makeModel()
        let items = LegendLayoutPolicy.items(groups: model.entityGroups)

        XCTAssertEqual(items.map(\.type), [.person, .company, .date], "sidebar order, present types only")
        XCTAssertEqual(items.map(\.valueCount), [2, 1, 2], "distinct values, the sidebar header number")
        XCTAssertEqual(items.map(\.occurrenceCount), [3, 1, 2])
        XCTAssertEqual(items.map(\.isAllKeptVisible), [false, true, false])

        for item in items {
            XCTAssertEqual(item.valueCount, model.groups(of: item.type).count, "\(item.type.rawValue) matches the sidebar")
        }
    }

    func testNoEntitiesMeansNoItems() {
        let model = ReviewModel(modelPath: nil)
        XCTAssertTrue(LegendLayoutPolicy.items(groups: model.entityGroups).isEmpty)
    }

    // MARK: - Tiers

    func testNarrowWindowForcesTheMenuAndNoTypesHidesTheLegend() {
        XCTAssertEqual(LegendLayoutPolicy.tier(isNarrow: true, typeCount: 4, availableWidth: 2_000), .menu)
        XCTAssertEqual(LegendLayoutPolicy.tier(isNarrow: false, typeCount: 0, availableWidth: 2_000), .hidden)
        XCTAssertEqual(LegendLayoutPolicy.tier(isNarrow: true, typeCount: 0, availableWidth: 2_000), .hidden)
    }

    func testTiersFollowTheEstimatedChipWidths() {
        let labeled = LegendLayoutPolicy.labeledChipWidthEstimate
        let compact = LegendLayoutPolicy.compactChipWidthEstimate
        let spacing = LegendLayoutPolicy.chipSpacing

        let fourLabeled = 4 * labeled + 3 * spacing
        XCTAssertEqual(LegendLayoutPolicy.tier(isNarrow: false, typeCount: 4, availableWidth: fourLabeled), .labeled)
        XCTAssertEqual(LegendLayoutPolicy.tier(isNarrow: false, typeCount: 4, availableWidth: fourLabeled - 1), .compact)

        let fourCompact = 4 * compact + 3 * spacing
        XCTAssertEqual(LegendLayoutPolicy.tier(isNarrow: false, typeCount: 4, availableWidth: fourCompact), .compact)
        XCTAssertEqual(LegendLayoutPolicy.tier(isNarrow: false, typeCount: 4, availableWidth: fourCompact - 1), .menu)
    }

    func testOverflowChipIsBudgetedWhenMoreThanSixTypesArePresent() {
        let labeled = LegendLayoutPolicy.labeledChipWidthEstimate
        let overflow = LegendLayoutPolicy.overflowChipWidthEstimate
        let spacing = LegendLayoutPolicy.chipSpacing
        let maxInline = LegendLayoutPolicy.maxInlineChips
        XCTAssertEqual(maxInline, 6)

        // Eight types: six labeled chips plus the (+2) chip, seven gaps.
        let needed = CGFloat(maxInline) * labeled + overflow + CGFloat(maxInline) * spacing
        XCTAssertEqual(LegendLayoutPolicy.tier(isNarrow: false, typeCount: 8, availableWidth: needed), .labeled)
        XCTAssertEqual(LegendLayoutPolicy.tier(isNarrow: false, typeCount: 8, availableWidth: needed - 1), .compact)
    }

    func testInlineSplitShowsAtMostSixChipsAndCountsTheRest() {
        let items = EntityType.allCases.prefix(8).map {
            LegendItem(type: $0, valueCount: 1, occurrenceCount: 1, isAllKeptVisible: false)
        }
        let split = LegendLayoutPolicy.inlineSplit(items)
        XCTAssertEqual(split.shown.map(\.type), Array(EntityType.allCases.prefix(6)))
        XCTAssertEqual(split.overflow.map(\.type), Array(EntityType.allCases[6..<8]))

        let few = LegendLayoutPolicy.inlineSplit(Array(items.prefix(3)))
        XCTAssertEqual(few.shown.count, 3)
        XCTAssertTrue(few.overflow.isEmpty)
    }

    // MARK: - Strings

    func testLegendStringsCarryCountsAndTheKeptVisibleState() {
        let person = EntityTypePresentation.localizedName(for: .person)
        let live = LegendItem(type: .person, valueCount: 12, occurrenceCount: 31, isAllKeptVisible: false)
        let dimmed = LegendItem(type: .person, valueCount: 2, occurrenceCount: 2, isAllKeptVisible: true)

        let tooltip = LegendPresentation.tooltip(for: live)
        XCTAssertTrue(tooltip.contains("12") && tooltip.contains("31"), tooltip)

        let label = LegendPresentation.accessibilityLabel(for: live)
        XCTAssertTrue(label.contains(person) && label.contains("12") && label.contains("31"), label)
        XCTAssertNotEqual(LegendPresentation.accessibilityLabel(for: dimmed), label)
        XCTAssertTrue(LegendPresentation.accessibilityLabel(for: dimmed).hasPrefix(label.replacingOccurrences(of: "12", with: "2").replacingOccurrences(of: "31", with: "2")))

        XCTAssertTrue(LegendPresentation.accessibilityHint(for: live).contains(person))
        XCTAssertEqual(LegendPresentation.menuButtonLabel(typeCount: 1), L10n.string("1 type"))
        XCTAssertEqual(LegendPresentation.menuButtonLabel(typeCount: 6), String(format: L10n.string("%lld types"), Int64(6)))
        XCTAssertTrue(LegendPresentation.menuButtonAccessibilityLabel(typeCount: 6).contains("6"))
    }

    // MARK: - Selection

    func testSelectingALegendTypeSelectsEveryGroupOfThatTypeAndRevealsTheFirst() {
        let model = makeModel()
        LegendLayoutPolicy.select(type: .person, in: model)

        let personGroups = model.groups(of: .person)
        XCTAssertEqual(model.selectedGroupIDs, Set(personGroups.map(\.id)))
        XCTAssertEqual(model.groupToReveal, personGroups.first?.id)
    }
}
