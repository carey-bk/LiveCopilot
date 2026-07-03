import Foundation
import Combine

/// Persists finished sessions as one JSON file each under
/// `~/Library/Application Support/Stealth/sessions/<id>.json`, and exposes the
/// list (most recent first) to the History UI. Kept forever until deleted.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        loadAll()
    }

    /// Directory holding the per-session JSON files. Created on demand.
    private var directory: URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Stealth/sessions", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                DebugLog.log("SessionStore: create dir failed: \(error.localizedDescription)")
                return nil
            }
        }
        return dir
    }

    /// Build a record from live transcript lines and persist it.
    /// No-op when there are no lines (an empty session isn't worth saving).
    @discardableResult
    func save(lines: [TranscriptLine], startedAt: Date, endedAt: Date = Date()) -> SessionRecord? {
        guard !lines.isEmpty else { return nil }
        let record = SessionRecord(
            startedAt: startedAt,
            endedAt: endedAt,
            lines: lines.map(SessionLine.init(from:))
        )
        persist(record)
        sessions = ([record] + sessions).sorted { $0.startedAt > $1.startedAt }
        return record
    }

    func delete(_ record: SessionRecord) {
        if let url = fileURL(for: record.id) {
            try? fileManager.removeItem(at: url)
        }
        sessions = sessions.filter { $0.id != record.id }
    }

    // MARK: - Disk

    private func fileURL(for id: UUID) -> URL? {
        directory?.appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ record: SessionRecord) {
        guard let url = fileURL(for: record.id) else { return }
        do {
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            DebugLog.log("SessionStore: save failed: \(error.localizedDescription)")
        }
    }

    private func loadAll() {
        guard let dir = directory,
              let urls = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        let loaded: [SessionRecord] = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
        sessions = loaded.sorted { $0.startedAt > $1.startedAt }
    }
}
