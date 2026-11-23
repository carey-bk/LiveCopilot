import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var knowledge: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !knowledgeConfigured {
                HStack(spacing: 12) {
                    Label(b("Knowledge indexing is not verified. Configure a local model or API Key and complete verification to continue.", "知识库索引服务尚未验证通过。请前往配置，下载本地模型或保存 API Key 并完成验证。"), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(b("Configure", "去配置")) { serviceRole = ServiceRole.knowledgeIndexing.rawValue; page = .services }
                }.lcCallout(.accent)
            }
            knowledgeContent
                .disabled(!knowledgeConfigured)
                .allowsHitTesting(knowledgeConfigured)
                .saturation(knowledgeConfigured ? 1 : 0)
                .opacity(knowledgeConfigured ? 1 : 0.45)
        }.task { if coordinator.settings.embeddingService == .local { await localModels.verifyEmbeddingIfNeeded() } }
    }
    var knowledgeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Local knowledge base")).font(.headline)
            KnowledgeImportDropZone(language: coordinator.settings.language, isIndexing: coordinator.isIndexing || !knowledgeConfigured,
                                    selectDocuments: selectDocuments, importDocuments: { urls in
                                        guard knowledgeConfigured else { return }; coordinator.importDocuments(urls)
                                    },
                                    reportError: { coordinator.knowledgeMessage = $0 })
            Text(t(coordinator.settings.embeddingService == .local
                   ? "PDF, Markdown, TXT and DOCX · parsing, embeddings and retrieval stay on this Mac. Answer generation sends selected excerpts to your analysis service."
                   : "PDF, Markdown, TXT and DOCX · original copies remain local. Indexing sends extracted text to OpenAI.")).font(.caption).foregroundStyle(.secondary)
            if coordinator.knowledgeDocuments.contains(where: { $0.embeddingModel != coordinator.settings.selectedEmbeddingIdentity }) {
                HStack {
                    Text(t("Some documents use a different embedding model. Re-index them to restore semantic retrieval.")).font(.caption).foregroundStyle(LC.warning)
                    Button(b("Clean up retired BGE and Python files", "清理旧 BGE 和 Python 环境")) { coordinator.cleanRetiredModels() }.disabled(coordinator.isIndexing)
                    Button(t("Re-index all")) { coordinator.reindexAll() }.disabled(coordinator.isIndexing)
                }
            }
            Stepper(t("Evidence chunks") + ": \(coordinator.settings.retrievalCount)", value: $coordinator.settings.retrievalCount, in: 3...8)
            Text(b("More evidence chunks provide more context but increase the analysis model's input tokens and may add irrelevant text.", "证据片段越多，分析模型可读的上下文越多，但输入 token 和无关信息也可能增加。")).font(.caption).foregroundStyle(.secondary)
            if coordinator.indexingDocumentCount > 0 {
                IndexingProgressView(progress: coordinator.indexingProgress,
                                     label: b("Documents completed: ", "已完成文档：") + "\(coordinator.indexingCompletedDocumentCount) / \(coordinator.indexingDocumentCount)")
                    .accessibilityIdentifier("knowledge-index-progress")
            }
            if coordinator.indexingSucceeded {
                Label(b("Index established", "索引已建立"), systemImage: "checkmark.square.fill")
                    .foregroundStyle(LC.success).accessibilityIdentifier("knowledge-index-complete")
            }
            if !coordinator.knowledgeMessage.isEmpty { Text(t(coordinator.knowledgeMessage)).font(.caption).textSelection(.enabled) }
            if coordinator.settings.embeddingService == .local {
                Button(b("Check local model / copy diagnostics", "检查本地模型 / 复制诊断信息")) {
                    page = Self.knowledgeModelDiagnosticsTarget.page
                    serviceRole = Self.knowledgeModelDiagnosticsTarget.serviceRole.rawValue
                }
                    .accessibilityIdentifier("knowledge-model-diagnostics")
            }
            List {
                ForEach(coordinator.knowledgeDocuments) { document in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(document.name).font(.headline)
                        if coordinator.isIndexing && coordinator.indexingDocumentID == document.id {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(b("Building index…", "正在建立索引…")).font(.caption).foregroundStyle(.secondary)
                            }
                        } else if document.status == "Ready" {
                            Label(b("Index established", "索引已建立"), systemImage: "checkmark.square.fill")
                                .font(.caption).foregroundStyle(LC.success)
                        } else { Text(t(document.status)).font(.caption).foregroundStyle(.secondary) }
                        Text("\(document.chunkCount) \(t("chunks")) · \(document.embeddingModel)").font(.caption).foregroundStyle(.secondary)
                        if let error = document.error { Text(t(error)).font(.caption).foregroundStyle(LC.danger) }
                        HStack {
                            Button(t("Re-index")) { coordinator.reindex(document) }
                            Button(t("Show local copy")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.localPath)]) }
                            Spacer()
                            Button(t("Delete"), role: .destructive) { coordinator.deleteDocument(document) }
                        }.buttonStyle(.borderless).disabled(coordinator.isIndexing)
                    }.padding(.vertical, 5).accessibilityElement(children: .contain)
                }
            }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: LC.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LC.Radius.control, style: .continuous).strokeBorder(LC.hairline))
            if coordinator.knowledgeDocuments.isEmpty { Text(t("Import a document to ground answers in your own evidence.")).foregroundStyle(.secondary) }
        }
    }
    func selectDocuments() {
        guard knowledgeConfigured else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentParser.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { response in if response == .OK && knowledgeConfigured { coordinator.importDocuments(panel.urls) } }
    }
}
