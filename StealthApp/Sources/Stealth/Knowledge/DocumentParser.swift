import Foundation
import PDFKit
import AppKit

struct DocumentSection: Sendable {
    let text: String
    let page: Int?
}

enum DocumentParser {
    enum TextEncodingChoice: String, CaseIterable, Sendable, Equatable {
        case automatic
        case utf8
        case utf16
        case gb18030
        case isoLatin1
    }

    struct TextImportPreview: Sendable, Equatable {
        struct Candidate: Sendable, Equatable {
            let encoding: TextEncodingChoice
            let sample: String
        }

        let detectedEncoding: TextEncodingChoice?
        let ambiguous: Bool
        let sampleText: String
        let candidates: [Candidate]
    }

    static let supportedExtensions = ["pdf", "md", "markdown", "txt", "docx"]
    static let maxDocxUncompressedBytes: UInt64 = 100_000_000
    static let maxDocxEntryCount: UInt64 = 5_000
    static let maxExtractedBytes = 100_000_000
    private static let documentTooLargeMessage = "Document is too large to extract safely. Split it into smaller documents."
    private static let docxUnreadableMessage = "DOCX document is unreadable or corrupted."
    private static let unsupportedEncodingMessage = "Save this text document as UTF-8, UTF-16 (with BOM), or GB18030 and retry."
    private static let ambiguousEncodingMessage = "Text encoding is ambiguous (could be GB18030 or Western/Latin-1). Save the file as UTF-8 or select an explicit encoding before importing."
    private static let gb18030Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    )

    static func decodeText(_ data: Data, encoding: TextEncodingChoice = .automatic) throws -> String {
        if data.isEmpty { return "" }
        switch encoding {
        case .automatic:
            // Reject UTF-32 BOMs before checking 2-byte UTF-16 BOMs so UTF-32 LE (FF FE 00 00)
            // is never mistaken for UTF-16 LE (FF FE).
            if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
                throw CopilotError.message(unsupportedEncodingMessage)
            }
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                guard let text = decodeUTF8(data) else {
                    throw CopilotError.message(unsupportedEncodingMessage)
                }
                return text
            }
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                guard let text = decodeUTF16WithBOM(data) else {
                    throw CopilotError.message(unsupportedEncodingMessage)
                }
                return text
            }
            if let text = String(data: data, encoding: .utf8) {
                guard isValidDecodedText(text) else {
                    throw CopilotError.message(unsupportedEncodingMessage)
                }
                return text
            }
            guard let text = decodeGB18030Strict(data) else {
                throw CopilotError.message(unsupportedEncodingMessage)
            }
            guard isPlausibleAutomaticGB18030(data: data, decoded: text) else {
                throw CopilotError.message(ambiguousEncodingMessage)
            }
            return text
        case .utf8:
            guard let text = decodeUTF8(data) else {
                throw CopilotError.message(unsupportedEncodingMessage)
            }
            return text
        case .utf16:
            guard let text = decodeUTF16WithBOM(data) else {
                throw CopilotError.message(unsupportedEncodingMessage)
            }
            return text
        case .gb18030:
            guard let text = decodeGB18030Strict(data) else {
                throw CopilotError.message(unsupportedEncodingMessage)
            }
            return text
        case .isoLatin1:
            guard let text = decodeISOLatin1(data) else {
                throw CopilotError.message(unsupportedEncodingMessage)
            }
            return text
        }
    }

    static func previewText(_ data: Data, maxCharacters: Int = 240) -> TextImportPreview {
        let limit = max(0, maxCharacters)
        func excerpt(_ text: String) -> String {
            String(text.prefix(limit))
        }

        if data.isEmpty {
            return TextImportPreview(
                detectedEncoding: .utf8,
                ambiguous: false,
                sampleText: "",
                candidates: [.init(encoding: .utf8, sample: "")]
            )
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return TextImportPreview(detectedEncoding: nil, ambiguous: false, sampleText: "", candidates: [])
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let text = decodeUTF8(data) else {
                return TextImportPreview(detectedEncoding: nil, ambiguous: false, sampleText: "", candidates: [])
            }
            let sample = excerpt(text)
            return TextImportPreview(
                detectedEncoding: .utf8,
                ambiguous: false,
                sampleText: sample,
                candidates: [.init(encoding: .utf8, sample: sample)]
            )
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = decodeUTF16WithBOM(data) else {
                return TextImportPreview(detectedEncoding: nil, ambiguous: false, sampleText: "", candidates: [])
            }
            let sample = excerpt(text)
            return TextImportPreview(
                detectedEncoding: .utf16,
                ambiguous: false,
                sampleText: sample,
                candidates: [.init(encoding: .utf16, sample: sample)]
            )
        }
        if let text = String(data: data, encoding: .utf8) {
            guard isValidDecodedText(text) else {
                return TextImportPreview(detectedEncoding: nil, ambiguous: false, sampleText: "", candidates: [])
            }
            let sample = excerpt(text)
            return TextImportPreview(
                detectedEncoding: .utf8,
                ambiguous: false,
                sampleText: sample,
                candidates: [.init(encoding: .utf8, sample: sample)]
            )
        }

        let gbText = decodeGB18030Strict(data)
        let latin1Text = decodeISOLatin1(data)

        if let gbText, isPlausibleAutomaticGB18030(data: data, decoded: gbText) {
            let gbSample = excerpt(gbText)
            var candidates: [TextImportPreview.Candidate] = [.init(encoding: .gb18030, sample: gbSample)]
            if let latin1Text {
                candidates.append(.init(encoding: .isoLatin1, sample: excerpt(latin1Text)))
            }
            return TextImportPreview(
                detectedEncoding: .gb18030,
                ambiguous: false,
                sampleText: gbSample,
                candidates: candidates
            )
        }

        var candidates: [TextImportPreview.Candidate] = []
        if let latin1Text {
            candidates.append(.init(encoding: .isoLatin1, sample: excerpt(latin1Text)))
        }
        if let gbText {
            candidates.append(.init(encoding: .gb18030, sample: excerpt(gbText)))
        }
        guard !candidates.isEmpty else {
            return TextImportPreview(detectedEncoding: nil, ambiguous: false, sampleText: "", candidates: [])
        }
        return TextImportPreview(
            detectedEncoding: nil,
            ambiguous: true,
            sampleText: "",
            candidates: candidates
        )
    }

    private static func decodeUTF8(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        let payload = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        guard let text = String(data: payload, encoding: .utf8), isValidDecodedText(text) else {
            return nil
        }
        return text
    }

    private static func decodeUTF16WithBOM(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return nil
        }
        let encoding: String.Encoding
        if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
        } else {
            return nil
        }
        let payload = Data(data.dropFirst(2))
        guard payload.count.isMultiple(of: 2),
              let text = String(data: payload, encoding: encoding),
              text.data(using: encoding) == payload,
              isValidDecodedText(text) else {
            return nil
        }
        return text
    }

    private static func decodeGB18030Strict(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        guard !data.contains(0x00),
              let text = String(data: data, encoding: gb18030Encoding),
              !text.unicodeScalars.contains("\u{FFFD}"),
              text.data(using: gb18030Encoding) == data,
              isValidDecodedText(text) else {
            return nil
        }
        return text
    }

    private static func decodeISOLatin1(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        guard !data.contains(0x00),
              let text = String(data: data, encoding: .isoLatin1),
              isValidDecodedText(text) else {
            return nil
        }
        return text
    }

    /// Rejects non-BOM byte streams that round-trip under GB18030 only because single-byte Western
    /// text (e.g. ISO-8859-1 `élève` = `E9 6C E8 76 65`) pairs high lead bytes with ASCII trail bytes
    /// into rare GBK extension codepoints (`"閘鑦e"`). Standard Simplified Chinese GB18030 text is
    /// dominated by GB2312 high+high pairs (`0xA1...0xA9` / `0xB0...0xF7` + `0xA1...0xFE`).
    private static func isPlausibleAutomaticGB18030(data: Data, decoded: String) -> Bool {
        var gb2312HanziCount = 0
        var gb2312Count = 0
        var asciiTrailPairCount = 0
        var multibyteCount = 0

        let validWalk = data.withUnsafeBytes { bytes -> Bool in
            var index = 0
            while index < bytes.count {
                let lead = bytes[index]
                if lead < 0x80 {
                    index += 1
                    continue
                }
                guard (0x81...0xFE).contains(lead), index + 1 < bytes.count else {
                    return false
                }
                let trail = bytes[index + 1]
                if (0x30...0x39).contains(trail) {
                    guard index + 3 < bytes.count,
                          (0x81...0xFE).contains(bytes[index + 2]),
                          (0x30...0x39).contains(bytes[index + 3]) else {
                        return false
                    }
                    multibyteCount += 1
                    index += 4
                } else if (0x40...0x7E).contains(trail) {
                    asciiTrailPairCount += 1
                    multibyteCount += 1
                    index += 2
                } else if (0x80...0xFE).contains(trail) {
                    if (0xB0...0xF7).contains(lead) && (0xA1...0xFE).contains(trail) {
                        gb2312HanziCount += 1
                        gb2312Count += 1
                    } else if (0xA1...0xA9).contains(lead) && (0xA1...0xFE).contains(trail) {
                        gb2312Count += 1
                    }
                    multibyteCount += 1
                    index += 2
                } else {
                    return false
                }
            }
            return true
        }

        guard validWalk, multibyteCount > 0, gb2312Count > 0, gb2312HanziCount > 0 else {
            return false
        }
        if asciiTrailPairCount > 0 && gb2312Count < asciiTrailPairCount * 2 {
            return false
        }
        return decoded.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func isValidDecodedText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value < 0x20 {
                if value != 0x09 && value != 0x0A && value != 0x0C && value != 0x0D {
                    return false
                }
            } else if value == 0x7F || (0x80...0x9F).contains(value) {
                return false
            }
        }
        return true
    }

    static func extract(_ url: URL, textEncoding: TextEncodingChoice = .automatic) throws -> [DocumentSection] {
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
            var extracted: [DocumentSection] = []
            extracted.reserveCapacity(min(pdf.pageCount, 512))
            var totalBytes = 0
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                guard let text = pdf.page(at: index)?.string else { continue }
                totalBytes += text.utf8.count
                guard totalBytes <= maxExtractedBytes else {
                    throw CopilotError.message(documentTooLargeMessage)
                }
                extracted.append(DocumentSection(text: text, page: index + 1))
            }
            sections = extracted
        case "md", "markdown", "txt":
            let data = try Data(contentsOf: url)
            let text = try decodeText(data, encoding: textEncoding)
            guard text.utf8.count <= maxExtractedBytes else {
                throw CopilotError.message(documentTooLargeMessage)
            }
            sections = [.init(text: text, page: nil)]
        case "docx":
            try validateDocxArchive(url)
            try Task.checkCancellation()
            let attributed = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
            let text = attributed.string
            guard text.utf8.count <= maxExtractedBytes else {
                throw CopilotError.message(documentTooLargeMessage)
            }
            sections = [.init(text: text, page: nil)]
        default: throw CopilotError.message("Supported documents: PDF, Markdown, TXT and DOCX.")
        }
        guard sections.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CopilotError.message("No extractable text. Scanned PDFs need OCR before import.")
        }
        return sections
    }

    /// Inspects the ZIP Central Directory of a `.docx` archive before AppKit decompresses it,
    /// rejecting malformed archives, excessive entry counts, and zip-bomb uncompressed totals.
    static func validateDocxArchive(_ url: URL) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw CopilotError.message(docxUnreadableMessage) }
        defer { try? handle.close() }

        let fileSize: UInt64
        do { fileSize = try handle.seekToEnd() }
        catch { throw CopilotError.message(docxUnreadableMessage) }
        guard fileSize >= 22 else { throw CopilotError.message(docxUnreadableMessage) }

        let tailLength = min(fileSize, UInt64(22 + 65_535))
        let tailStart = fileSize - tailLength
        try handle.seek(toOffset: tailStart)
        guard let tail = try handle.read(upToCount: Int(tailLength)), tail.count == Int(tailLength) else {
            throw CopilotError.message(docxUnreadableMessage)
        }

        var eocdOffsetInTail: Int?
        for pos in stride(from: tail.count - 22, through: 0, by: -1) {
            if readUInt32LE(tail, at: pos) == 0x0605_4B50 {
                let commentLength = Int(readUInt16LE(tail, at: pos + 20))
                if pos + 22 + commentLength == tail.count {
                    eocdOffsetInTail = pos
                    break
                }
            }
        }
        guard let eocdPos = eocdOffsetInTail else {
            throw CopilotError.message(docxUnreadableMessage)
        }

        var entryCount = UInt64(readUInt16LE(tail, at: eocdPos + 10))
        var cdSize = UInt64(readUInt32LE(tail, at: eocdPos + 12))
        var cdOffset = UInt64(readUInt32LE(tail, at: eocdPos + 16))

        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            let eocdFileOffset = tailStart + UInt64(eocdPos)
            guard eocdFileOffset >= 20 else { throw CopilotError.message(docxUnreadableMessage) }
            try handle.seek(toOffset: eocdFileOffset - 20)
            guard let locator = try handle.read(upToCount: 20), locator.count == 20,
                  readUInt32LE(locator, at: 0) == 0x0706_4B50 else {
                throw CopilotError.message(docxUnreadableMessage)
            }
            let z64Offset = readUInt64LE(locator, at: 8)
            let (z64End, z64Overflow) = z64Offset.addingReportingOverflow(56)
            guard !z64Overflow, z64End <= fileSize else {
                throw CopilotError.message(docxUnreadableMessage)
            }
            try handle.seek(toOffset: z64Offset)
            guard let z64 = try handle.read(upToCount: 56), z64.count == 56,
                  readUInt32LE(z64, at: 0) == 0x0606_4B50 else {
                throw CopilotError.message(docxUnreadableMessage)
            }
            entryCount = readUInt64LE(z64, at: 32)
            cdSize = readUInt64LE(z64, at: 40)
            cdOffset = readUInt64LE(z64, at: 48)
        }

        guard entryCount <= maxDocxEntryCount else {
            throw CopilotError.message(documentTooLargeMessage)
        }
        guard entryCount > 0 else {
            throw CopilotError.message(docxUnreadableMessage)
        }
        let (cdEnd, cdOverflow) = cdOffset.addingReportingOverflow(cdSize)
        guard !cdOverflow, cdEnd <= fileSize, cdSize <= 50_000_000 else {
            throw CopilotError.message(docxUnreadableMessage)
        }

        try handle.seek(toOffset: cdOffset)
        guard let cdData = try handle.read(upToCount: Int(cdSize)), cdData.count == Int(cdSize) else {
            throw CopilotError.message(docxUnreadableMessage)
        }

        var cursor = 0
        var totalUncompressed: UInt64 = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= cdData.count,
                  readUInt32LE(cdData, at: cursor) == 0x0201_4B50 else {
                throw CopilotError.message(docxUnreadableMessage)
            }
            let rawUncompressed = readUInt32LE(cdData, at: cursor + 24)
            let nameLen = Int(readUInt16LE(cdData, at: cursor + 28))
            let extraLen = Int(readUInt16LE(cdData, at: cursor + 30))
            let commentLen = Int(readUInt16LE(cdData, at: cursor + 32))
            let extraStart = cursor + 46 + nameLen
            let nextCursor = extraStart + extraLen + commentLen
            guard nextCursor <= cdData.count else {
                throw CopilotError.message(docxUnreadableMessage)
            }

            let entryUncompressed: UInt64
            if rawUncompressed == 0xFFFF_FFFF {
                guard let z64Size = zip64UncompressedSize(in: cdData, extraStart: extraStart, extraLength: extraLen) else {
                    throw CopilotError.message(docxUnreadableMessage)
                }
                entryUncompressed = z64Size
            } else {
                entryUncompressed = UInt64(rawUncompressed)
            }

            let (sum, overflow) = totalUncompressed.addingReportingOverflow(entryUncompressed)
            guard !overflow, sum <= maxDocxUncompressedBytes else {
                throw CopilotError.message(documentTooLargeMessage)
            }
            totalUncompressed = sum
            cursor = nextCursor
        }
    }

    private static func zip64UncompressedSize(in data: Data, extraStart: Int, extraLength: Int) -> UInt64? {
        var pos = extraStart
        let end = extraStart + extraLength
        while pos + 4 <= end {
            let headerID = readUInt16LE(data, at: pos)
            let blockSize = Int(readUInt16LE(data, at: pos + 2))
            let payloadStart = pos + 4
            guard payloadStart + blockSize <= end else { return nil }
            if headerID == 0x0001 {
                guard blockSize >= 8 else { return nil }
                return readUInt64LE(data, at: payloadStart)
            }
            pos = payloadStart + blockSize
        }
        return nil
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        let lo = UInt64(readUInt32LE(data, at: offset))
        let hi = UInt64(readUInt32LE(data, at: offset + 4))
        return lo | (hi << 32)
    }
}

enum DocumentChunker {
    /// Splits extracted document sections into overlapping chunks bounded by character and scalar limits.
    /// When `maxChunks` is set, chunking stops early once `result.count > maxChunks` so callers can
    /// reject oversized documents without materializing all remaining chunks.
    static func chunk(_ sections: [DocumentSection], documentID: String, name: String,
                      maxCharacters: Int = 1600, overlap: Int = 180, maxChunks: Int? = nil) -> [SourceChunk] {
        let size = max(128, maxCharacters), overlap = max(0, min(overlap, max(128, maxCharacters) / 3))
        // A Character may hide many scalars (combining marks, emoji sequences, broken PDF text
        // extraction), and every scalar can become a model token. Bound scalars as well so one passage
        // cannot exceed the local model's 8,192-token input limit or force an oversized context.
        let maxScalars = size * 2
        let chunkLimit = maxChunks.map { max(0, $0) }
        let compactThreshold = max(size, 2048)
        var result: [SourceChunk] = []
        var window: [Character] = []
        var windowScalars: [Int] = []
        window.reserveCapacity(compactThreshold + size + 1)
        windowScalars.reserveCapacity(compactThreshold + size + 1)

        for section in sections {
            window.removeAll(keepingCapacity: true)
            windowScalars.removeAll(keepingCapacity: true)
            var iterator = section.text.makeIterator()
            var reachedEnd = false
            var head = 0
            var iterations = 0

            while true {
                if iterations & 63 == 0, Task.isCancelled { return result }
                iterations += 1

                if head >= compactThreshold {
                    window.removeFirst(head)
                    windowScalars.removeFirst(head)
                    head = 0
                }
                while (window.count - head) <= size && !reachedEnd {
                    if let raw = iterator.next() {
                        let ch: Character = raw == "\r\n" ? "\n" : raw
                        window.append(ch)
                        windowScalars.append(ch.unicodeScalars.count)
                    } else {
                        reachedEnd = true
                    }
                }
                if head >= window.count { break }

                var end = min(head + size, window.count)
                var scalarSum = 0
                var scalarEnd = head
                while scalarEnd < end {
                    let nextSum = scalarSum + windowScalars[scalarEnd]
                    if nextSum > maxScalars && scalarEnd > head { break }
                    scalarSum = nextSum
                    scalarEnd += 1
                }
                end = scalarEnd

                let atSectionEnd = (end == window.count) && reachedEnd
                if !atSectionEnd {
                    let lower = head + (end - head) / 2
                    if let boundary = (lower..<end).last(where: { "\n。.!?！？ ".contains(window[$0]) }) {
                        end = boundary + 1
                    }
                }

                let text = String(window[head..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result.append(.init(id: UUID().uuidString, documentID: documentID, documentName: name,
                                        ordinal: result.count, page: section.page, text: text, vector: [], embeddingModel: ""))
                    if let chunkLimit, result.count > chunkLimit { return result }
                }
                if atSectionEnd { break }
                // A scalar-limited passage may be shorter than the overlap; always advance by 2/3 of it.
                head = max(head + 1, end - min(overlap, (end - head) / 3))
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
    static func retrievalTerms(_ text: String) -> [String] {
        let stop: Set<String> = ["the", "and", "what", "how", "you", "your", "them", "this", "that", "with", "about", "is", "a", "to", "of", "in", "it", "its", "are", "was", "were", "can", "could", "would", "please", "explain", "tell", "me", "do", "does", "why", "we", "did", "请问", "什么", "怎么", "如何", "为什么", "一下", "这个", "那个", "我们", "你们", "的是", "是否"]
        return terms(text).filter { !stop.contains($0) && $0.count >= 2 }
    }
    static func matchQuery(_ text: String) -> String {
        var seen = Set<String>()
        return retrievalTerms(text).filter { seen.insert($0).inserted }.prefix(70)
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
