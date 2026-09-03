//
//  AdvisoryRow.swift
//  LDAUI
//
//  The persistent advisory row that sits between the status banner and the
//  document pane: one sentence about something the user needs to know BEFORE
//  they scan or export, with an optional control to act on it.
//
//  Two advisories use it today, and both are conditional on a fact about the
//  document or the machine rather than on a preference:
//    - no detection model for the selected rung, so a scan will not look for
//      names, companies or addresses;
//    - the document carries tracked changes, so a value spanning one is
//      flattened on restore.
//
//  There is deliberately NO dismiss control. Both conditions are real
//  reductions in what the tool does, and a dismissible row means a lawyer can
//  hide one and then act on output that looks complete. The row disappears when
//  the condition does, which is the only way it should disappear.
//
//  Extracted from AppShell.swift, which is over its size budget: this is leaf
//  chrome with no dependency on the shell's state beyond the action closure.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI

/// One hairline-separated advisory above the document pane.
struct AdvisoryRow<Trailing: View>: View {

    private let advice: String
    private let trailing: () -> Trailing

    init(advice: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.advice = advice
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
            Text(verbatim: advice)
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: advice))
    }
}

extension AdvisoryRow where Trailing == EmptyView {
    /// An advisory that only reports, with nothing to press.
    init(advice: String) {
        self.init(advice: advice, trailing: { EmptyView() })
    }
}
