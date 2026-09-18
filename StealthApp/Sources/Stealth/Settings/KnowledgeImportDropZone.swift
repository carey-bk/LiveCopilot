import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeImportDropZone: View {
    let language: AppLanguage
    let isIndexing: Bool
    let selectDocuments: () -> Void
    let importDocuments: ([URL]) -> Void
    let reportError: (String) -> Void
    @State private var isTargeted = false
    @State private var isLoadingDrop = false
    private var busy: Bool { isIndexing || isLoadingDrop }
    private func t(_ value: String) -> String { L10n.text(value, language: language) }

    var body: some View {
        Button(action: selectDocuments) {
            VStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).frame(height: 26) }
                else { Image(systemName: isTargeted ? "arrow.down.doc" : "plus").font(.system(size: 25, weight: .medium)).frame(height: 26) }
                Text(t(busy ? "Indexing documents…" : isTargeted ? "Release to add to your knowledge base" : "Drag documents here"))
                    .font(.system(size: 15, weight: .semibold))
                Text(t(busy ? "Wait for indexing to finish before adding more documents." : "or click to choose files"))
                    .font(.callout)
                Text("PDF · Markdown · TXT · DOCX").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 124).padding(12)
            .foregroundStyle(Color.blue)
            .background(Color.blue.opacity(isTargeted && !busy ? 0.14 : 0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.blue.opacity(busy ? 0.3 : isTargeted ? 1 : 0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(busy)
        .accessibilityLabel(t("Import documents…"))
        .accessibilityHint(t("Drag documents here"))
        .accessibilityIdentifier("knowledge-import-zone")
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
            guard !busy, !providers.isEmpty else { return false }
            isLoadingDrop = true
            Task { @MainActor in
                defer { isLoadingDrop = false; isTargeted = false }
                do { importDocuments(try await DocumentImport.load(providers)) }
                catch { reportError(error.localizedDescription) }
            }
            return true
        }
    }
}
