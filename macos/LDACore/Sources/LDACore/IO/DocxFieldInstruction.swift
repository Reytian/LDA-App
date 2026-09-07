//
//  DocxFieldInstruction.swift
//  LDACore
//
//  A complex field's instruction, assembled across the runs Word split it
//  into, scrubbed as the one string it is, and projected back onto those runs.
//
//  Why. WordprocessingML writes a complex field as a run carrying
//  fldChar begin, one or more runs carrying w:instrText, a fldChar separate,
//  the cached result as ordinary run text, and a fldChar end. The instruction
//  is ONE logical string, and Word is free to break it across instrText runs
//  at any character; rsid tracking and editing history decide where. Judging
//  each run alone therefore reads a string no consumer ever reads:
//
//    run 1: ' HYPERLINK "mailto:'      run 2: 'client@example.test" '
//
//  The old per-run scrub rewrote run 1 to ' HYPERLINK "about:blank' and left
//  run 2 untouched, so the neutralized scheme made the output look scrubbed
//  while the whole address rode out in the next run. Split the scheme itself
//  three ways and nothing was rewritten at all.
//
//  Projection follows the rule the run redactor already uses for a span that
//  crosses runs (DocxRedactor.planRunEdits): the replacement text goes into
//  the FIRST segment the edit overlaps, and the covered text is deleted from
//  every other one. Run structure, run properties, and every byte outside the
//  covered range survive.
//
//  Grouping stops at a field boundary. Two fields in one paragraph are two
//  instructions, and assembling across the boundary would let one field's
//  instruction text be written into another field's runs.
//
//  Offsets here are UTF-16 code units into the RAW element content, which is
//  what the scrub patterns match: an instruction may spell its quotes
//  literally in element content or as &quot; in a w:instr attribute.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

enum DocxFieldInstruction {

    /// One rewrite of an assembled instruction: replace `range` with `text`.
    struct AssembledEdit: Equatable {
        var range: NSRange
        var text: String
    }

    /// One instruction element's raw content, located in the part.
    private struct Segment {
        /// The element name, so a live instruction and a tracked-deletion one
        /// are never assembled into the same string.
        var element: String
        /// Range of the element's raw content in the part.
        var contentRange: NSRange
        /// That raw content.
        var content: String
    }

    /// A complex-field instruction element with its content, in either the
    /// live (w:instrText) or the tracked-deletion (w:delInstrText) spelling.
    /// The close tag is a backreference so the two never pair up crosswise.
    /// Instruction content is character data, so it cannot contain "<" and
    /// the content group is a linear character class.
    private static let instructionRegex = try? NSRegularExpression(
        pattern: #"<w:(instrText|delInstrText)\b[^>]*>([^<]*)</w:\1>"#
    )

    /// A field boundary marker. Any fldChar between two instruction elements,
    /// begin, separate, or end, ends the instruction being assembled.
    private static let fieldCharRegex = try? NSRegularExpression(
        pattern: #"<w:fldChar\b[^>]*>"#
    )

    /// Rewrite every complex-field instruction in `xml`: assemble each field's
    /// instruction across its runs, ask `edits` what to change in that whole
    /// string, and write the result back onto the same runs.
    static func rewriteAssembled(
        in xml: String,
        edits: (String) -> [AssembledEdit]
    ) -> String {
        let ns = xml as NSString
        let groups = self.groups(in: xml, ns: ns)
        guard !groups.isEmpty else { return xml }

        var result = ""
        var cursor = 0
        for group in groups {
            let assembled = group.map(\.content).joined()
            let rewritten = project(edits(assembled), onto: group)
            for (segment, content) in zip(group, rewritten) {
                if segment.contentRange.location > cursor {
                    result += ns.substring(
                        with: NSRange(
                            location: cursor,
                            length: segment.contentRange.location - cursor
                        )
                    )
                }
                result += content
                cursor = segment.contentRange.location + segment.contentRange.length
            }
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    // MARK: - Grouping

    /// The instruction elements of `xml`, grouped per field in document order.
    private static func groups(in xml: String, ns: NSString) -> [[Segment]] {
        guard let instructionRegex else { return [] }
        let full = NSRange(location: 0, length: ns.length)
        let boundaries = fieldCharRegex?
            .matches(in: xml, range: full)
            .map(\.range.location) ?? []

        var groups: [[Segment]] = []
        var current: [Segment] = []
        var previousEnd = 0

        for match in instructionRegex.matches(in: xml, range: full) {
            let segment = Segment(
                element: ns.substring(with: match.range(at: 1)),
                contentRange: match.range(at: 2),
                content: ns.substring(with: match.range(at: 2))
            )
            let start = match.range.location
            let separated = current.isEmpty
                || current[current.count - 1].element != segment.element
                || boundaries.contains { $0 >= previousEnd && $0 < start }
            if separated, !current.isEmpty {
                groups.append(current)
                current = []
            }
            current.append(segment)
            previousEnd = match.range.location + match.range.length
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    // MARK: - Projection

    /// The new content of each segment in `group` after applying `edits`,
    /// which are expressed against the assembled instruction.
    ///
    /// An edit that spans segments puts its text in the first segment it
    /// overlaps and deletes the covered text from the rest, so the assembled
    /// instruction reads as one rewritten target and no run gains a fragment
    /// of another.
    private static func project(_ edits: [AssembledEdit], onto group: [Segment]) -> [String] {
        guard !edits.isEmpty else { return group.map(\.content) }

        var offsets: [Int] = []
        var running = 0
        for segment in group {
            offsets.append(running)
            running += (segment.content as NSString).length
        }

        var perSegment: [[AssembledEdit]] = Array(repeating: [], count: group.count)
        for edit in edits {
            let editEnd = edit.range.location + edit.range.length
            guard editEnd > edit.range.location else { continue }
            var isFirst = true
            for (index, segment) in group.enumerated() {
                let start = offsets[index]
                let end = start + (segment.content as NSString).length
                let overlapStart = max(edit.range.location, start)
                let overlapEnd = min(editEnd, end)
                guard overlapStart < overlapEnd else { continue }
                perSegment[index].append(
                    AssembledEdit(
                        range: NSRange(
                            location: overlapStart - start,
                            length: overlapEnd - overlapStart
                        ),
                        text: isFirst ? edit.text : ""
                    )
                )
                isFirst = false
            }
        }

        return group.enumerated().map { index, segment in
            apply(perSegment[index], to: segment.content)
        }
    }

    /// Apply edits to one string, highest offset first so earlier offsets stay
    /// valid. Shared with the simple-field path, whose whole instruction is
    /// one w:instr attribute and needs the same replacement rule.
    static func apply(_ edits: [AssembledEdit], to content: String) -> String {
        guard !edits.isEmpty else { return content }
        var result = content as NSString
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result = result.replacingCharacters(in: edit.range, with: edit.text) as NSString
        }
        return result as String
    }
}
