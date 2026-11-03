import SwiftUI

/// The production intake surface, shared by the window and layout previews.
/// Window resizing reflows content; it never scales the type or controls.
struct DocumentIntakeView: View {
    var isDropTargeted = false
    var errorMessage: String?
    let onChooseFiles: () -> Void
    let onBatch: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        L10n.text("Anonymize Documents")
                            .font(CounselTheme.Typography.pageTitle)
                            .foregroundStyle(CounselTheme.textPrimary)
                        L10n.text("Add your files, review sensitive details, then export a redacted copy.")
                            .font(CounselTheme.Typography.readingBody)
                            .foregroundStyle(CounselTheme.textSecondary)
                            .lineSpacing(4)
                    }

                    VStack(spacing: 18) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 36, weight: .regular))
                            .foregroundStyle(CounselTheme.inkAccent)
                            .accessibilityHidden(true)
                        L10n.text("Drop documents to anonymize")
                            .font(CounselTheme.Typography.sectionTitle)
                        L10n.text("PDF, Word (.docx), plain text, PNG or JPEG images, and ZIP archives.")
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.textSecondary)
                        Button(action: onChooseFiles) {
                            L10n.label("Choose Files", systemImage: "plus")
                                .font(CounselTheme.Typography.readingBody.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(CounselTheme.inkAccentFill)
                        .accessibilityIdentifier("chooseDocuments")
                        L10n.text("Add several files to review them together. You can add more later.")
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.textSecondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(28)
                    .frame(maxWidth: .infinity)
                    .background(CounselTheme.raised, in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(isDropTargeted ? CounselTheme.inkAccent : CounselTheme.hairline,
                                          style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 5]))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button(action: onBatch) {
                            L10n.label("Batch Anonymize…", systemImage: "square.stack.3d.down.right")
                                .font(CounselTheme.Typography.supporting.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .accessibilityIdentifier("batchAnonymize")
                        L10n.text("Or anonymize every document in a folder at once, with no review step.")
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.textSecondary)
                            .lineSpacing(3)
                    }

                    L10n.label("Detection and redaction run on this Mac.", systemImage: "lock.shield")
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(CounselTheme.textSecondary)
                    if let errorMessage {
                        Label { Text(verbatim: errorMessage) } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(CounselTheme.danger)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640)
                .padding(geometry.size.width < 760 ? 24 : 40)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .font(CounselTheme.Typography.readingBody)
        .foregroundStyle(CounselTheme.textPrimary)
        .background(CounselTheme.paper)
    }
}
