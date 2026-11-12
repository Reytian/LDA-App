//
//  OutputNames.swift
//  LDACore
//
//  The name a new set of redacted outputs takes in a folder that may already
//  hold an earlier set.
//
//  Review 2026-11-11 (T7): `lda anonymize` wrote <base>_redacted.<ext> and
//  its .ldamap over whatever an earlier run left in the folder, so a
//  redacted copy already sent lost the only mapping that restores it. Save
//  Redacted and a multi-document session already took the next free name;
//  this is the one rule all three use now.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

public enum OutputNames {

    /// The first of base, base_2, base_3, ... for which none of the files
    /// `artifacts` names for it exists in `directory`.
    public static func firstFreeBaseName(
        _ base: String,
        in directory: URL,
        artifacts: (String) -> [String]
    ) -> String {
        let fileManager = FileManager.default
        func taken(_ name: String) -> Bool {
            artifacts(name).contains { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
        guard taken(base) else { return base }
        var counter = 2
        while taken("\(base)_\(counter)") { counter += 1 }
        return "\(base)_\(counter)"
    }

    /// The review PDF's base name for a redacted base name: <source>_review,
    /// with the same counter (contract_redacted_2 gives contract_review_2).
    public static func reviewBaseName(sourceBase: String, redactedBase: String) -> String {
        let prefix = sourceBase + "_redacted"
        guard redactedBase.hasPrefix(prefix) else { return redactedBase + "_review" }
        return sourceBase + "_review" + redactedBase.dropFirst(prefix.count)
    }

    /// Every file a single-document anonymize of `input` writes under a
    /// redacted base name: the edit surface, the mapping, the review PDF of a
    /// PDF and the redacted image of an image.
    public static func anonymizeArtifacts(forInput input: URL, redactedBase: String) -> [String] {
        let ext = input.pathExtension.lowercased()
        let sourceBase = input.deletingPathExtension().lastPathComponent
        var names = ["\(redactedBase).ldamap", "\(redactedBase).\(ext == "docx" ? "docx" : "txt")"]
        if ext == "pdf" {
            names.append("\(reviewBaseName(sourceBase: sourceBase, redactedBase: redactedBase)).pdf")
        }
        if ImageTextExtractor.shouldTreatAsImage(input, extension: ext) {
            names.append("\(redactedBase).png")
        }
        return names
    }
}
