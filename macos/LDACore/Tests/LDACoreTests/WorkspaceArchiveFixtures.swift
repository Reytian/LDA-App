//
//  WorkspaceArchiveFixtures.swift
//  LDACoreTests
//
//  Builders for workspace archives the shipping writer would never emit: a
//  future format version, a missing manifest, a traversing document path.
//  Every negative test needs one, so they live in one place.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation
@testable import LDACore

enum WorkspaceArchiveFixtures {

    /// The inner zip bytes for exact member contents.
    static func rawArchive(members: [String: Data]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for (path, data) in members.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate,
                provider: { position, size in
                    let start = Int(position)
                    return data.subdata(in: start ..< min(start + size, data.count))
                }
            )
        }
        guard let bytes = archive.data else {
            throw DocumentIOError.corrupt("the fixture archive produced no data")
        }
        return bytes
    }

    /// Seal exact member contents into a .ldawork file the way the format does.
    static func write(members: [String: Data], to url: URL, passphrase: String) throws {
        try WorkspaceArchive.container.save(
            try rawArchive(members: members),
            to: url,
            protection: .passphrase(passphrase)
        )
    }
}
