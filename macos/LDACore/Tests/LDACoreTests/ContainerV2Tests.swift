//
//  ContainerV2Tests.swift
//  LDACoreTests
//
//  Container format version 2: the header is bound as AES-GCM additional
//  authenticated data and the PBKDF2 iteration count is stored explicitly.
//  Version 1 files, which had neither, must still open.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import CryptoKit
import CommonCrypto
@testable import LDACore

final class ContainerV2Tests: XCTestCase {

    private let magic = Array("LDAV2T".utf8)
    private var container: EncryptedContainer!
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = EncryptedContainer(
            magic: magic,
            keychainService: "ai.openclaw.lda.v2test",
            containerDescription: "V2 test container"
        )
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerV2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    private func url(_ name: String = "c.bin") -> URL {
        workDir.appendingPathComponent(name)
    }

    // MARK: - Version stamp

    func testNewContainersAreWrittenAsVersion2() throws {
        let target = url()
        try container.save(Data("payload".utf8), to: target, protection: .passphrase("pass phrase"))

        let bytes = [UInt8](try Data(contentsOf: target))
        XCTAssertEqual(
            bytes[magic.count], 2,
            "a freshly written container should carry format version 2"
        )
        XCTAssertEqual(EncryptedContainer.containerVersion, 2)
        XCTAssertEqual(EncryptedContainer.readableVersions, [1, 2])
    }

    func testVersion2PassphraseRoundTrip() throws {
        let target = url()
        let payload = Data("counsel-only material".utf8)
        try container.save(payload, to: target, protection: .passphrase("pass phrase"))
        let recovered = try container.load(from: target, protection: .passphrase("pass phrase"))
        XCTAssertEqual(recovered, payload)
    }

    // MARK: - Stored iteration count

    func testIterationCountIsRecordedInTheHeader() throws {
        let target = url()
        try container.save(Data("x".utf8), to: target, protection: .passphrase("pass phrase"))

        let bytes = [UInt8](try Data(contentsOf: target))
        // magic | version | tag | saltLen | salt(16) | iterations(4)
        let iterationOffset = magic.count + 3 + 16
        let iterations = bytes[iterationOffset ..< iterationOffset + 4]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(
            iterations, 600_000,
            "new containers should record the current OWASP iteration count"
        )
    }

    func testImplausibleIterationCountIsRefusedBeforeDeriving() throws {
        // The count must be USED to derive the key before the header AAD can be
        // verified, so without a cap a hostile container declaring UInt32.max
        // pins a core for half an hour per open attempt. The cap rejects it as
        // corrupt before any derivation work happens.
        let target = url("hostile-iterations.bin")
        try container.save(Data("x".utf8), to: target, protection: .passphrase("pass phrase"))

        var bytes = [UInt8](try Data(contentsOf: target))
        let iterationOffset = magic.count + 3 + 16
        bytes.replaceSubrange(
            iterationOffset ..< iterationOffset + 4,
            with: [0xFF, 0xFF, 0xFF, 0xFF]
        )
        try Data(bytes).write(to: target)

        // Must return promptly: the guard fires before PBKDF2 runs.
        let started = Date()
        XCTAssertThrowsError(
            try container.load(from: target, protection: .passphrase("pass phrase"))
        ) { error in
            guard case DocumentIOError.corrupt = error else {
                XCTFail("Expected corrupt for an implausible iteration count, got \(error)")
                return
            }
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "the refusal must happen before deriving, not after minutes of PBKDF2"
        )
    }

    func testTamperedIterationCountFailsAuthentication() throws {
        let target = url()
        try container.save(Data("x".utf8), to: target, protection: .passphrase("pass phrase"))

        // Rewrite the iteration count to the old 200k. Before the header became
        // AAD this would simply have derived a different key and surfaced as a
        // decrypt failure; now the tag itself catches the edit. Either way the
        // requirement is that no plaintext comes back.
        var bytes = [UInt8](try Data(contentsOf: target))
        let iterationOffset = magic.count + 3 + 16
        bytes[iterationOffset] = 0x00
        bytes[iterationOffset + 1] = 0x03
        bytes[iterationOffset + 2] = 0x0D
        bytes[iterationOffset + 3] = 0x40
        try Data(bytes).write(to: target)

        XCTAssertThrowsError(
            try container.load(from: target, protection: .passphrase("pass phrase"))
        ) { error in
            guard case DocumentIOError.decryptionFailed = error else {
                XCTFail("Expected decryptionFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Header binding (AAD)

    func testTamperedSaltIsRejectedByHeaderAuthentication() throws {
        let target = url()
        try container.save(Data("payload".utf8), to: target, protection: .passphrase("pass phrase"))

        var bytes = [UInt8](try Data(contentsOf: target))
        // Flip one salt byte. The salt is part of the authenticated header, so
        // AES-GCM must refuse the box outright.
        bytes[magic.count + 3] ^= 0xFF
        try Data(bytes).write(to: target)

        XCTAssertThrowsError(
            try container.load(from: target, protection: .passphrase("pass phrase"))
        ) { error in
            guard case DocumentIOError.decryptionFailed = error else {
                XCTFail("Expected decryptionFailed for a tampered salt, got \(error)")
                return
            }
        }
    }

    func testHeaderBytesAreExactlyTheFilePrefix() throws {
        // The header IS the AAD, so it must be byte-identical to the file
        // prefix; if the two ever diverge every container stops opening.
        let target = url()
        try container.save(Data("payload".utf8), to: target, protection: .passphrase("pass phrase"))
        let bytes = [UInt8](try Data(contentsOf: target))
        XCTAssertEqual(Array(bytes[0 ..< magic.count]), magic)
        XCTAssertEqual(bytes[magic.count + 1], 1, "passphrase protection tag")
        XCTAssertEqual(bytes[magic.count + 2], 16, "salt length")
    }

    // MARK: - Version 1 backward compatibility

    /// Build a version 1 passphrase container by hand: no iteration-count
    /// field, no AAD, PBKDF2 at the implicit 200k. This is what earlier builds
    /// wrote, and it must still open.
    private func makeLegacyV1Container(payload: Data, passphrase: String) throws -> Data {
        let salt = [UInt8](repeating: 0xA5, count: 16)
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordData = Data(passphrase.utf8)
        let status = passwordData.withUnsafeBytes { passwordBytes -> Int32 in
            salt.withUnsafeBufferPointer { saltBuffer in
                derived.withUnsafeMutableBufferPointer { derivedBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordData.count,
                        saltBuffer.baseAddress,
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        200_000,
                        derivedBuffer.baseAddress,
                        derivedBuffer.count
                    )
                }
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess))

        let key = SymmetricKey(data: Data(derived))
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else {
            throw DocumentIOError.corrupt("no combined box")
        }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(UInt8(1))            // version 1
        out.append(UInt8(1))            // passphrase tag
        out.append(UInt8(salt.count))
        out.append(contentsOf: salt)
        out.append(combined)            // no iteration field, no AAD
        return out
    }

    func testVersion1ContainerStillOpens() throws {
        let payload = Data("written by an older build".utf8)
        let passphrase = "legacy pass phrase"
        let target = url("legacy.bin")
        try makeLegacyV1Container(payload: payload, passphrase: passphrase).write(to: target)

        let recovered = try container.load(from: target, protection: .passphrase(passphrase))
        XCTAssertEqual(
            recovered, payload,
            "a version 1 container must still open at its implicit 200k iterations"
        )
    }

    func testVersion1ContainerWithWrongPassphraseStillFails() throws {
        let target = url("legacy2.bin")
        try makeLegacyV1Container(payload: Data("x".utf8), passphrase: "right").write(to: target)
        XCTAssertThrowsError(
            try container.load(from: target, protection: .passphrase("wrong"))
        ) { error in
            guard case DocumentIOError.decryptionFailed = error else {
                XCTFail("Expected decryptionFailed, got \(error)")
                return
            }
        }
    }

    func testUnknownVersionIsRejected() throws {
        let target = url("v9.bin")
        try container.save(Data("x".utf8), to: target, protection: .passphrase("pass phrase"))
        var bytes = [UInt8](try Data(contentsOf: target))
        bytes[magic.count] = 9
        try Data(bytes).write(to: target)

        XCTAssertThrowsError(
            try container.load(from: target, protection: .passphrase("pass phrase"))
        ) { error in
            guard case DocumentIOError.corrupt = error else {
                XCTFail("Expected corrupt for an unknown version, got \(error)")
                return
            }
        }
    }

    func testTruncatedIterationFieldIsRejected() throws {
        let target = url("short.bin")
        try container.save(Data("x".utf8), to: target, protection: .passphrase("pass phrase"))
        // Keep magic | version | tag | saltLen | salt and drop the rest, so the
        // declared version 2 header is cut off inside the iteration field.
        let bytes = [UInt8](try Data(contentsOf: target))
        let cut = magic.count + 3 + 16 + 2
        try Data(bytes[0 ..< cut]).write(to: target)

        XCTAssertThrowsError(
            try container.load(from: target, protection: .passphrase("pass phrase"))
        ) { error in
            guard case DocumentIOError.corrupt = error else {
                XCTFail("Expected corrupt for a truncated header, got \(error)")
                return
            }
        }
    }
}
