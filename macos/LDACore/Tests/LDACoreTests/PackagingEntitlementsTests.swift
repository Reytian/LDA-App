import Foundation
import XCTest
@testable import LDACore

final class PackagingEntitlementsTests: XCTestCase {

    /// One packaging plist, parsed. Found relative to this test file so the
    /// check follows the repository rather than a hardcoded path.
    private func plist(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("packaging")
            .appendingPathComponent(name)
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: try Data(contentsOf: url), format: nil)
                as? [String: Any]
        )
    }

    func testInfoPlistDeclaresTheWorkspaceDocumentType() throws {
        // Double-click delivery depends entirely on this declaration. Without
        // it a .ldawork file is a generic document that opens in nothing, and
        // the format's "hand it to a colleague" promise stops at the Finder.
        let info = try plist("Info.plist")

        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let workspace = try XCTUnwrap(documentTypes.first {
            ($0["LSItemContentTypes"] as? [String])?
                .contains(WorkspaceArchive.uniformTypeIdentifier) == true
        })
        XCTAssertEqual(workspace["CFBundleTypeRole"] as? String, "Editor")
        XCTAssertEqual(workspace["LSHandlerRank"] as? String, "Owner")

        let exported = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(exported.first {
            $0["UTTypeIdentifier"] as? String == WorkspaceArchive.uniformTypeIdentifier
        })
        // public.data and nothing more: the file is ciphertext, so no other app
        // should be told it can read into it.
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.data"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(
            tags["public.filename-extension"] as? [String],
            [WorkspaceArchive.fileExtension],
            "the declared extension must match the one the app writes"
        )
    }

    func testInfoPlistDeclaresTheReportDocumentType() throws {
        // The encrypted report needs LDA to open it, so the app has to be the
        // thing a double-click reaches. Without this declaration the format's
        // "hand it to a colleague" promise stops at the Finder.
        let info = try plist("Info.plist")

        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let report = try XCTUnwrap(documentTypes.first {
            ($0["LSItemContentTypes"] as? [String])?
                .contains(ComplianceReportArchive.uniformTypeIdentifier) == true
        })
        XCTAssertEqual(report["LSHandlerRank"] as? String, "Owner")

        let exported = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(exported.first {
            $0["UTTypeIdentifier"] as? String == ComplianceReportArchive.uniformTypeIdentifier
        })
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.data"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(
            tags["public.filename-extension"] as? [String],
            [ComplianceReportArchive.fileExtension],
            "the declared extension must match the one the app writes"
        )
    }

    func testInfoPlistDeclaresTheMappingSidecarAsARelatedItemType() throws {
        // Export for AI writes <base>.ldamap next to the .md the user chose in
        // a save panel, and Restore reads the .ldamap next to the file chosen
        // in an open panel. Under App Sandbox the Powerbox grant covers the
        // chosen file only; it extends to a sibling with a declared related
        // item type, accessed through file coordination. Without this entry
        // the sidecar write is denied in the packaged app.
        let info = try plist("Info.plist")

        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let mapping = try XCTUnwrap(documentTypes.first {
            ($0["LSItemContentTypes"] as? [String])?
                .contains(MappingStore.uniformTypeIdentifier) == true
        })
        XCTAssertEqual(mapping["NSIsRelatedItemType"] as? Bool, true)
        XCTAssertEqual(
            mapping["CFBundleTypeExtensions"] as? [String],
            [MappingStore.fileExtension],
            "the related item is matched by extension, so the extension must be declared"
        )
        XCTAssertEqual(mapping["LSHandlerRank"] as? String, "Owner")

        let exported = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(exported.first {
            $0["UTTypeIdentifier"] as? String == MappingStore.uniformTypeIdentifier
        })
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.data"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(
            tags["public.filename-extension"] as? [String],
            [MappingStore.fileExtension],
            "the declared extension must match the one the app writes"
        )
    }

    // MARK: - The two entitlements files, pinned against each other

    private static let restrictedKeys = [
        "com.apple.application-identifier",
        "com.apple.developer.team-identifier",
        "keychain-access-groups"
    ]

    private func packagingPlist(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("packaging")
            .appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "\(name) must be a dictionary plist"
        )
    }

    /// A restricted entitlement is honoured only with an embedded Developer ID
    /// provisioning profile. The ad hoc build has none, and a binary that
    /// claims one without it is SIGKILLed at exec (measured, three runs). So
    /// these keys must never appear in the file the ad hoc path signs with.
    func testTheAdHocEntitlementsCarryNoRestrictedKey() throws {
        let base = try packagingPlist("LDA.entitlements")
        for key in Self.restrictedKeys {
            XCTAssertNil(
                base[key],
                "\(key) in LDA.entitlements would make every ad hoc dev build die at "
                    + "launch. It belongs only in LDA-distribution.entitlements."
            )
        }
    }

    /// The distribution file is the base file plus exactly the three restricted
    /// keys, with values DERIVED from Info.plist and the team rather than
    /// restated, so the two files cannot drift apart unnoticed and the bundle
    /// id cannot be renamed without this test saying so.
    func testTheDistributionEntitlementsAreTheBasePlusExactlyThreeRestrictedKeys() throws {
        let base = try packagingPlist("LDA.entitlements")
        let dist = try packagingPlist("LDA-distribution.entitlements")
        let info = try packagingPlist("Info.plist")
        let bundleID = try XCTUnwrap(info["CFBundleIdentifier"] as? String)

        // Every base key is present with the same value.
        for (key, value) in base {
            XCTAssertEqual(
                dist[key] as? Bool, value as? Bool,
                "distribution must carry base key \(key) with the same value"
            )
        }
        // And exactly the three restricted keys on top, no others.
        let extra = Set(dist.keys).subtracting(base.keys)
        XCTAssertEqual(
            extra, Set(Self.restrictedKeys),
            "the distribution file may add exactly the three Touch ID keys and nothing else"
        )

        let team = try XCTUnwrap(dist["com.apple.developer.team-identifier"] as? String)
        XCTAssertFalse(team.isEmpty)
        XCTAssertEqual(
            dist["com.apple.application-identifier"] as? String, "\(team).\(bundleID)",
            "the application identifier is <team>.<CFBundleIdentifier>, derived, never typed twice"
        )
        XCTAssertEqual(
            dist["keychain-access-groups"] as? [String], ["\(team).\(bundleID)"],
            "the one keychain group is the app's own identifier; it must sit inside the "
                + "profile's <team>.* allowlist, which package-app.sh verifies at build time"
        )
    }

    func testSandboxEntitlementsAreExactlyWhatWeIntend() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = packageRoot
            .appendingPathComponent("packaging")
            .appendingPathComponent("LDA.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(
            plist["com.apple.security.files.user-selected.read-write"] as? Bool,
            true
        )
        XCTAssertEqual(
            plist["com.apple.security.files.bookmarks.app-scope"] as? Bool,
            true
        )
        // network.client is now PRESENT, deliberately. It was added so Manage
        // Models can download detection models the user asks for. This test
        // previously asserted its absence, which was correct until that
        // decision; the assertion is inverted rather than deleted so the
        // entitlement stays a conscious, tested choice.
        //
        // What must never change: nothing may connect INTO the app, and the
        // single-network-chokepoint invariant is enforced separately by
        // NetworkChokepointTests.
        XCTAssertEqual(plist["com.apple.security.network.client"] as? Bool, true,
                       "model downloads need outbound access")
        XCTAssertNil(plist["com.apple.security.network.server"],
                     "nothing may connect into this app")
    }
}
