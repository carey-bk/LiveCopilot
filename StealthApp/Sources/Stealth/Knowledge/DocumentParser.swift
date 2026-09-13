import Foundation
import PDFKit
import AppKit

struct DocumentSection {
    let text: String
    let page: Int?
}

enum DocumentParser {
    static let supportedExtensions = ["pdf", "md", "markdown", "txt", "docx"]
    static func extract(_ url: URL) throws -> [DocumentSection] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 50_000_000 else {
            throw CopilotError.message("Choose a regular document smaller than 50 MB.")
        }
        let sections: [DocumentSection]
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else {
                throw CopilotError.message("PDF is unreadable or password protected.")
            }
            sections = (0..<pdf.pageCount).compactMap { index in
                pdf.page(at: index)?.string.map { DocumentSection(text: $0, page: index + 1) }
            }
        case "md", "markdown", "txt":
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw CopilotError.message("Save this text document as UTF-8 or UTF-16 and retry.")
            }
            sections = [.init(text: text, page: nil)]
        case "docx":
            let attributed = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
            sections = [.init(text: attributed.string, page: nil)]
        default: throw CopilotError.message("Supported documents: PDF, Markdown, TXT and DOCX.")
        }
        guard sections.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CopilotError.message("No extractable text. Scanned PDFs need OCR before import.")
        }
        return sections
    }
}

enum DocumentChunker {
    static func chunk(_ sections: [DocumentSection], documentID: String, name: String,
                      maxCharacters: Int = 1600, overlap: Int = 180) -> [SourceChunk] {
        let size = max(128, maxCharacters), overlap = max(0, min(overlap, max(128, maxCharacters) / 3))
        var result: [SourceChunk] = []
        for section in sections {
            let chars = Array(section.text.replacingOccurrences(of: "\r\n", with: "\n"))
            var start = 0
            while start < chars.count {
                var end = min(start + size, chars.count)
                if end < chars.count {
                    let lower = start + size / 2
                    if let boundary = (lower..<end).last(where: { "\n。.!?！？ ".contains(chars[$0]) }) { end = boundary + 1 }
                }
                let text = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result.append(.init(id: UUID().uuidString, documentID: documentID, documentName: name,
                                        ordinal: result.count, page: section.page, text: text, vector: [], embeddingModel: ""))
                }
                if end == chars.count { break }
                start = max(start + 1, end - overlap)
            }
        }
        return result
    }
}

enum LexicalTokenizer {
    static func terms(_ text: String) -> [String] {
        var tokens = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        // FTS unicode61 does not segment Han text. Add CJK bigrams on both indexing and querying.
        var run: [Character] = []
        func flush() {
            if run.count == 1 { tokens.append(String(run)) }
            if run.count >= 2 { for i in 0..<(run.count - 1) { tokens.append(String(run[i...i + 1])) } }
            run = []
        }
        for ch in text {
            if ch.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) { run.append(ch) }
            else { flush() }
        }
        flush()
        return tokens
    }
    static func indexedText(_ text: String) -> String { terms(text).joined(separator: " ") }
    static func matchQuery(_ text: String) -> String {
        var seen = Set<String>()
        let stop: Set<String> = ["the", "and", "what", "how", "you", "them", "this", "that", "with", "about", "is", "a", "to", "of", "in", "it"]
        return terms(text).filter { !stop.contains($0) && seen.insert($0).inserted }.prefix(70)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
    }
}

enum VectorMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for (x, y) in zip(a, b) {
            guard x.isFinite, y.isFinite else { return 0 }
            dot += Double(x) * Double(y); aa += Double(x) * Double(x); bb += Double(y) * Double(y)
        }
        guard aa > 0, bb > 0 else { return 0 }
        return dot / sqrt(aa * bb)
    }
    static func fuse(lexical: [SourceChunk], semantic: [SourceChunk], limit: Int) -> [RetrievedSource] {
        var scores: [String: Double] = [:], chunks: [String: SourceChunk] = [:]
        for ranked in [lexical, semantic] {
            for (index, chunk) in ranked.enumerated() {
                scores[chunk.id, default: 0] += 1 / Double(60 + index + 1)
                chunks[chunk.id] = chunk
            }
        }
        var results: [RetrievedSource] = []
        for (id, score) in scores {
            if let chunk = chunks[id] { results.append(RetrievedSource(chunk: chunk, score: score)) }
        }
        results.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.id < rhs.id }
            return lhs.score > rhs.score
        }
        return Array(results.prefix(max(1, min(limit, 12))))
    }
}
