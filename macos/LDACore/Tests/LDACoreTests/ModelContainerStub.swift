//
//  ModelContainerStub.swift
//  LDACoreTests
//
//  A FileManager that reports a temporary directory as Application Support, so
//  a test can exercise the app-owned model store without writing into the real
//  container on the developer's machine.
//
//  ModelCatalog.modelsRoot(fileManager:) is the only seam that decides where
//  models live, and it asks the FileManager for the Application Support
//  directory. Overriding that one method redirects modelsRoot, installedURL,
//  isInstalled, and every path derived from them, with no production change.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

/// Redirects `.applicationSupportDirectory` to a caller-owned directory.
final class ModelContainerStub: FileManager {

    let supportRoot: URL

    init(supportRoot: URL) {
        self.supportRoot = supportRoot
        super.init()
    }

    override func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        guard directory == .applicationSupportDirectory else {
            return try super.url(
                for: directory, in: domain, appropriateFor: url, create: shouldCreate
            )
        }
        if shouldCreate {
            try createDirectory(at: supportRoot, withIntermediateDirectories: true)
        }
        return supportRoot
    }
}
