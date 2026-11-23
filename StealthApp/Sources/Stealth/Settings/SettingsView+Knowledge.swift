import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

extension SettingsView {
    var knowledge: some View {
        LCScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
            }.padding(.bottom, 24)
        }.task { if coordinator.settings.embeddingService == .local { await localModels.verifyEmbeddingIfNeeded() } }
    }
    var knowledgeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                LCSectionHeader(t("Local knowledge base"),
                                subtitle: t(coordinator.settings.embeddingService == .local
                                            ? "PDF, Markdown, TXT and DOCX · parsing, embeddings and retrieval stay on this Mac. Answer generation sends selected excerpts to your analysis service."
                                            : "PDF, Markdown, TXT and DOCX · original copies remain local. Indexing sends extracted text to OpenAI."),
                                systemImage: "tray.and.arrow.down")
                KnowledgeImportDropZone(language: coordinator.settings.language, isIndexing: coordinator.isIndexing || !knowledgeConfigured,
                                        selectDocuments: selectDocuments, importDocuments: { urls in
                                            guard knowledgeConfigured else { return }; coordinator.importDocuments(urls)
                                        },
                                        reportError: { coordinator.knowledgeMessage = $0 })
                if coordinator.indexingDocumentCount > 0 {
                    IndexingProgressView(progress: coordinator.indexingProgress,
                                         label: b("Documents completed: ", "已完成文档：") + "\(coordinator.indexingCompletedDocumentCount) / \(coordinator.indexingDocumentCount)")
                        .accessibilityIdentifier("knowledge-index-progress")
                }
                HStack(spacing: 8) {
                    if coordinator.indexingSucceeded {
                        LCPill(text: b("Index established", "索引已建立"), tone: .success, systemImage: "checkmark")
                            .accessibilityIdentifier("knowledge-index-complete")
                    }
                    if !coordinator.knowledgeMessage.isEmpty {
                        Text(t(coordinator.knowledgeMessage)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }.lcCard()

            if coordinator.knowledgeDocuments.contains(where: { $0.embeddingModel != coordinator.settings.selectedEmbeddingIdentity }) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(t("Some documents use a different embedding model. Re-index them to restore semantic retrieval."), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(LC.warning).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(t("Re-index all")) { coordinator.reindexAll() }.disabled(coordinator.isIndexing)
                        Button(b("Clean up retired BGE and Python files", "清理旧 BGE 和 Python 环境")) { coordinator.cleanRetiredModels() }.disabled(coordinator.isIndexing)
                    }
                }.lcCallout(.warning)
            }

            documentTable

            VStack(alignment: .leading, spacing: 10) {
                LCSectionHeader(b("Retrieval", "检索设置"), systemImage: "magnifyingglass")
                Stepper(t("Evidence chunks") + ": \(coordinator.settings.retrievalCount)", value: $coordinator.settings.retrievalCount, in: 3...8)
                Text(b("More evidence chunks provide more context but increase the analysis model's input tokens and may add irrelevant text.", "证据片段越多，分析模型可读的上下文越多，但输入 token 和无关信息也可能增加。")).font(.caption).foregroundStyle(.secondary)
                if coordinator.settings.embeddingService == .local {
                    Button(b("Check local model / copy diagnostics", "检查本地模型 / 复制诊断信息")) {
                        page = Self.knowledgeModelDiagnosticsTarget.page
                        serviceRole = Self.knowledgeModelDiagnosticsTarget.serviceRole.rawValue
                    }
                        .accessibilityIdentifier("knowledge-model-diagnostics")
                }
            }.lcCard()
        }
    }

    private var documentTable: some View {
        let documents = coordinator.knowledgeDocuments
        let chunks = documents.reduce(0) { $0 + $1.chunkCount }
        return VStack(alignment: .leading, spacing: 0) {
            LCSectionHeader(title: b("Documents", "资料"),
                            subtitle: documents.isEmpty ? nil : b("\(documents.count) documents · \(chunks) evidence chunks", "\(documents.count) 份资料 · \(chunks) 个证据片段"),
                            systemImage: "doc.text") { EmptyView() }
                .padding(.bottom, 12)
            if documents.isEmpty {
                Text(t("Import a document to ground answers in your own evidence.")).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                    if index > 0 { Divider() }
                    documentRow(document)
                }
            }
        }.lcCard()
    }

    private func documentRow(_ document: KnowledgeDocument) -> some View {
        let indexing = coordinator.isIndexing && coordinator.indexingDocumentID == document.id
        let stale = document.embeddingModel != coordinator.settings.selectedEmbeddingIdentity
        return HStack(alignment: .center, spacing: 12) {
            LCIconTile(systemImage: Self.documentSymbol(document.name), tone: .accent, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(document.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if indexing {
                        HStack(spacing: 5) { ProgressView().controlSize(.mini); Text(b("Building index…", "正在建立索引…")) }
                            .font(.caption).foregroundStyle(LC.accent)
                    } else if document.error != nil {
                        LCPill(text: b("Failed", "失败"), tone: .danger)
                    } else if document.status == "Ready" {
                        LCPill(text: stale ? b("Re-index needed", "需重建索引") : b("Index established", "索引已建立"), tone: stale ? .warning : .success)
                    } else {
                        LCPill(text: t(document.status))
                    }
                }
                Text("\(document.chunkCount) \(t("chunks")) · \(document.embeddingModel)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let error = document.error { Text(t(error)).font(.caption).foregroundStyle(LC.danger).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                Button { coordinator.reindex(document) } label: { Image(systemName: "arrow.clockwise") }
                    .help(t("Re-index")).accessibilityLabel(t("Re-index"))
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.localPath)]) } label: { Image(systemName: "folder") }
                    .help(t("Show local copy")).accessibilityLabel(t("Show local copy"))
                Button(role: .destructive) { coordinator.deleteDocument(document) } label: { Image(systemName: "trash").foregroundStyle(LC.danger) }
                    .help(t("Delete")).accessibilityLabel(t("Delete"))
            }
            .buttonStyle(.borderless).controlSize(.large).disabled(coordinator.isIndexing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    static func documentSymbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "md", "markdown": return "number"
        case "docx": return "doc.text"
        default: return "text.alignleft"
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
