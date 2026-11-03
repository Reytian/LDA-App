import SwiftUI

/// The complete heading is the disclosure control, including its trailing space.
public struct FullRowDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.appLanguage) private var language

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CounselTheme.textSecondary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    configuration.label
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CounselTheme.textPrimary)
            .accessibilityValue(L10n.string(configuration.isExpanded ? "Expanded" : "Collapsed", language: language))
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

/// Scope the full-row style to explicit disclosures, preserving native List sections.
struct FullRowDisclosure<Content: View, Label: View>: View {
    private let expanded: Binding<Bool>?
    private let content: Content
    private let label: Label
    @State private var localExpanded = false

    init(isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        expanded = isExpanded
        self.content = content()
        self.label = label()
    }

    var body: some View {
        DisclosureGroup(isExpanded: expanded ?? $localExpanded) { content } label: { label }
            .disclosureGroupStyle(FullRowDisclosureStyle())
    }
}
