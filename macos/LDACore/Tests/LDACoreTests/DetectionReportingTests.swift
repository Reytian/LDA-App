//
//  DetectionReportingTests.swift
//  LDACoreTests
//
//  The reporting invariant for the AI pass.
//
//  A patterns-only run and a failed AI run produce IDENTICAL entity output. The
//  only thing separating them is what the app reports. If a requested-but-
//  unavailable AI pass reports itself as "not attempted", a lawyer cannot tell
//  a deliberately pattern-only redaction from one where the model never loaded
//  and names were never looked for. These tests exist to keep those two states
//  distinguishable forever.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDAUI

final class DetectionReportingTests: XCTestCase {

    private let sample = "Jane Roe of Acme Holdings Ltd. can be reached at jane@acme.example."

    // MARK: - attempted == false means "not asked for", nothing else

    func testPatternsOnlyRunIsNotAttemptedAndCarriesNoWarning() {
        let out = ReviewModel.llmSpans(in: sample, useLLM: false, modelPath: "/anything.gguf")
        XCTAssertFalse(out.attempted, "the user did not ask for an AI pass")
        XCTAssertNil(out.failure, "a deliberate choice is not a failure")
        XCTAssertFalse(out.cancelled)
    }

    func testAiRequestedWithNoModelReportsAttemptedAndExplains() {
        // Reachable today: pick a tier whose model is not installed.
        let out = ReviewModel.llmSpans(in: sample, useLLM: true, modelPath: nil)
        XCTAssertTrue(out.attempted,
                      "AI was requested, so this must NOT look like a patterns-only run")
        let failure = try? XCTUnwrap(out.failure)
        XCTAssertNotNil(failure, "a requested pass that could not run must say so")
        XCTAssertTrue(out.failure?.contains("were not looked for") ?? false,
                      "the message must state what was missed: \(out.failure ?? "nil")")
    }

    func testTheMissingModelFailureSentenceNamesPersonAndCompany() {
        // The post-scan half of the same disclosure as the pre-scan advisory.
        // "names, companies, and addresses were not detected" was false on the
        // address clause: the Chinese street form IS matched deterministically,
        // truncated at the street number.
        let out = ReviewModel.llmSpans(in: sample, useLLM: true, modelPath: nil)
        let failure = out.failure ?? ""
        XCTAssertTrue(
            failure.contains("people's names and company names"),
            "name what was not looked for: \(failure)"
        )
        XCTAssertTrue(
            failure.contains("Chinese street form"),
            "the address clause must say what IS matched: \(failure)"
        )
        // A model-less scan can never read as a deliberate patterns-only run.
        XCTAssertTrue(out.attempted, "the user asked, so this is not patterns only")
        XCTAssertTrue(out.spans.isEmpty, "the AI pass did not run at all")
    }

    func testAiRequestedWithAMissingFileReportsAttemptedAndNamesTheFile() {
        let out = ReviewModel.llmSpans(
            in: sample, useLLM: true, modelPath: "/nope/Missing-Model-Q4_K_M.gguf"
        )
        XCTAssertTrue(out.attempted)
        XCTAssertNotNil(out.failure)
        XCTAssertTrue(out.failure?.contains("Missing-Model-Q4_K_M.gguf") ?? false,
                      "name the file so the user can find it: \(out.failure ?? "nil")")
    }

    func testTheTwoStatesAreDistinguishableFromOutcomeAlone() {
        // The property the UI depends on. If these two ever become equal again,
        // the banner cannot tell them apart no matter how it is written.
        let deliberate = ReviewModel.llmSpans(in: sample, useLLM: false, modelPath: nil)
        let broken = ReviewModel.llmSpans(in: sample, useLLM: true, modelPath: nil)

        XCTAssertEqual(deliberate.spans.count, broken.spans.count,
                       "precondition: both produce the same entities, which is the trap")
        XCTAssertNotEqual(deliberate.attempted, broken.attempted,
                          "attempted must separate them")
        XCTAssertNil(deliberate.failure)
        XCTAssertNotNil(broken.failure)
    }

    func testAModellessInstallReportsTheFailureRatherThanDemotingItself() {
        // Regression lock on the anti-auto-demotion ruling. It is tempting to
        // set the level to patternsOnly when no model file exists, because the
        // outcome is the same either way. It is wrong: patternsOnly sets
        // usesLLM == false, which makes this pass report attempted == false and
        // no failure, and that state is reserved for "the user did not ask".
        // Demoting would turn a reported failure into a silent one.
        let (defaults, name) = TestNamespace.defaults("no-auto-demotion")
        defer { defaults.removePersistentDomain(forName: name) }

        let level = AISettings.detectionLevel(defaults: defaults)
        XCTAssertEqual(level, .quick, "the default rung must not demote itself")
        XCTAssertTrue(level.usesLLM)

        let out = ReviewModel.llmSpans(in: sample, useLLM: level.usesLLM, modelPath: nil)
        XCTAssertTrue(out.attempted)
        XCTAssertNotNil(out.failure)
    }

    // MARK: - The one-time lda-v2 migration offer

    private func freshDefaults() -> UserDefaults {
        let suite = TestNamespace.suiteName("detection-migration")
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testAUserOnTheBundledDefaultIsNeverPrompted() {
        // The overwhelming majority. They just receive the better model.
        XCTAssertFalse(AISettings.shouldOfferLdaV2Switch(defaults: freshDefaults()))
    }

    func testAUserWhoExplicitlyChoseLdaV2IsOfferedTheSwitch() {
        let d = freshDefaults()
        d.set("/Users/x/Developer/lda-models/lda-v2-Q4_K_M.gguf",
              forKey: AISettings.customModelPathKey)
        XCTAssertTrue(AISettings.shouldOfferLdaV2Switch(defaults: d))
    }

    func testAUserWithSomeOtherCustomModelIsNotPrompted() {
        let d = freshDefaults()
        d.set("/Users/x/models/our-own-firm-tune.gguf", forKey: AISettings.customModelPathKey)
        XCTAssertFalse(AISettings.shouldOfferLdaV2Switch(defaults: d),
                       "the notice is specific to the retired model")
    }

    func testTheOfferAppearsOnlyOnce() {
        let d = freshDefaults()
        d.set("/x/lda-v2-Q4_K_M.gguf", forKey: AISettings.customModelPathKey)
        XCTAssertTrue(AISettings.shouldOfferLdaV2Switch(defaults: d))
        AISettings.dismissLdaV2Notice(defaults: d)
        XCTAssertFalse(AISettings.shouldOfferLdaV2Switch(defaults: d),
                       "keeping the model must not re-prompt on every launch")
    }

    func testKeepingLdaV2LeavesItRunning() {
        // Never silently override an explicit choice.
        let d = freshDefaults()
        d.set("/x/lda-v2-Q4_K_M.gguf", forKey: AISettings.customModelPathKey)
        AISettings.dismissLdaV2Notice(defaults: d)
        XCTAssertEqual(d.string(forKey: AISettings.customModelPathKey),
                       "/x/lda-v2-Q4_K_M.gguf")
    }

    // MARK: - The settings layer must produce the requesting state

    func testSelectingAnUninstalledTierAsksForAiSoTheFailureIsReported() {
        let suite = TestNamespace.suiteName("detection-reporting")
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }

        AISettings.setDetectionLevel(.mostThorough, defaults: d)
        let path = AISettings.resolveModelPath(defaults: d)
        XCTAssertNil(path, "an uninstalled tier must not borrow another model")
        XCTAssertTrue(AISettings.isModelMissing(defaults: d))

        // useLLM stays true, which is what makes the failure visible.
        XCTAssertTrue(AISettings.detectionLevel(defaults: d).usesLLM)
        let out = ReviewModel.llmSpans(in: sample, useLLM: true, modelPath: path)
        XCTAssertTrue(out.attempted)
        XCTAssertNotNil(out.failure)
    }
}
