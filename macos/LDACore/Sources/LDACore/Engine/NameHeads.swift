//
//  NameHeads.swift
//  LDACore
//
//  The Chinese company or brand values that only end a longer company or brand
//  name found in the same document: 巧克力 when 费列罗巧克力 was found, 公司
//  alongside any company.
//
//  Value mode (LLMExtractor.locate) and the recall rescan (EntityRescan) both
//  anchor a found value at every occurrence. One stray report of such a head,
//  a lone 巧克力 in "每粒金球状巧克力", therefore redacted the generic word
//  throughout a document as a company of its own. A head is kept only where it
//  was found; it is never spread.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

public enum NameHeads {

    /// The types a head can have and end: companies and brands.
    public static let nameTypes: Set<EntityType> = [.company, .trademark]

    /// The longest a head can be. Chinese full names end in a generic word
    /// (公司, 集团, 支行, or a product such as 巧克力), and a real short name
    /// is not one: it is a 字号 plus 公司, not the tail of the full name. A
    /// longer suffix is a name in its own right (费列罗巧克力 at the end of
    /// "费列罗公司费列罗巧克力") and must keep spreading.
    public static let maximumHeadCharacters = 3

    /// The values in `found` that are heads: Chinese, a company or brand, at
    /// most `maximumHeadCharacters` long, and a proper suffix of a longer
    /// company or brand value in `found`.
    public static func heads(in found: [(value: String, type: EntityType)]) -> Set<String> {
        let names = Set(found.filter { nameTypes.contains($0.type) }.map(\.value))
        return Set(names.filter { value in
            value.count <= maximumHeadCharacters
                && DefinedTermScanner.containsCJK(value)
                && names.contains { $0.count > value.count && $0.hasSuffix(value) }
        })
    }
}
