import AppKit
import UniformTypeIdentifiers

/// Decode Finder file drops before starting a single import batch. Preserve order,
/// deduplicate URLs, and reject folders/web links before any indexing or API call.
enum DocumentImport {
    static func validate(_ urls: [URL]) throws -> [URL] {
        var seen = Set<URL>()
        return try urls.map { url in
            guard url.isFileURL,
                  DocumentParser.supportedExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw CopilotError.message("Choose local PDF, Markdown, TXT or DOCX files. Folders and web links are not supported.")
            }
            return url.standardizedFileURL
        }.filter { seen.insert($0).inserted }
    }

    static func load(_ providers: [NSItemProvider]) async throws -> [URL] {
        guard !providers.isEmpty else { return [] }
        var urls: [URL] = []
        for provider in providers {
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let string = item as? String { url = URL(string: string) }
                    else { url = nil }
                    if error == nil, let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: CopilotError.message("Could not read the dropped files. Try choosing them with the file picker.")) }
                }
            }
            urls.append(url)
        }
        return try validate(urls)
    }
}
