import Foundation
import Combine

/// Persists finished sessions as one JSON file each under
/// `~/Library/Application Support/LiveCopilot/sessions/<id>.json`, and exposes the
/// list (most recent first) to the History UI. Kept forever until deleted.
@MainActor
final class SessionStore: ObservableObject {
    enum PersistOutcome: Equatable, Sendable {
        case saved
        case savedWithoutDraft(String)
        case failed(String)

        var jsonPersisted: Bool {
            switch self {
            case .saved, .savedWithoutDraft: return true
            case .failed: return false
            }
        }
        var draftWarning: String? {
            if case .savedWithoutDraft(let message) = self { return message }
            return nil
        }
        var failureMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }
    struct SaveResult: Equatable {
        let record: SessionRecord
        let outcome: PersistOutcome
    }
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastDraftWarning: String?
    @Published private(set) var pendingSaveIDs: Set<UUID> = []
    @Published private(set) var failedSaveIDs: Set<UUID> = []
    var isSaving: Bool { !pendingSaveIDs.isEmpty }

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let ioQueue = DispatchQueue(label: "com.livecopilot.session-store-io", qos: .utility)
    private let asyncIO: Bool
    private var deletedIDs: Set<UUID> = []

    private let root: URL
    /// Test-only hook to simulate TXT draft export failures after JSON has persisted on disk.
    internal var testDraftWriter: (@Sendable (SessionRecord, URL) throws -> Void)?
    init(root: URL? = nil, asyncIO: Bool = false) {
        self.root = root ?? AppPaths.dataDirectory().appendingPathComponent("sessions", isDirectory: true)
        self.asyncIO = asyncIO
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if asyncIO {
            loadAllAsync()
        } else {
            loadAll()
        }
    }

    /// Directory holding the per-session JSON files. Created on demand.
    private var directory: URL? {
        let dir = root
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
    func save(lines: [TranscriptLine], startedAt: Date, endedAt: Date = Date(), fragments: [TranscriptFragment] = []) -> SessionRecord? {
        saveSnapshot(lines: lines.map { SessionLine(from: $0) }, startedAt: startedAt, endedAt: endedAt, fragments: fragments, answers: [])
    }
    @discardableResult
    func saveSnapshot(id: UUID = UUID(), lines: [SessionLine], startedAt: Date, endedAt: Date = Date(), fragments: [TranscriptFragment] = [], answers: [SessionAnswer]) -> SessionRecord? {
        guard !lines.isEmpty || !answers.isEmpty else { return nil }
        var record = SessionRecord(id: id, startedAt: startedAt, endedAt: endedAt, lines: lines)
        record.fragments = fragments; record.answers = answers; record.schemaVersion = 2
        guard persist(record, isNewRecord: true) else { return nil }
        upsertSession(record)
        return record
    }

    /// Persists a session snapshot (off the main thread when `asyncIO` is enabled) and awaits
    /// actual JSON durability on disk before returning. Callers can distinguish queued vs JSON-persisted
    /// vs TXT-draft-warning vs JSON-failure, and safely retry with the same `id` without creating duplicates.
    func saveSnapshotConfirmed(id: UUID = UUID(), lines: [SessionLine], startedAt: Date, endedAt: Date = Date(), fragments: [TranscriptFragment] = [], answers: [SessionAnswer]) async -> SaveResult? {
        guard !lines.isEmpty || !answers.isEmpty else { return nil }
        var record = SessionRecord(id: id, startedAt: startedAt, endedAt: endedAt, lines: lines)
        record.fragments = fragments; record.answers = answers; record.schemaVersion = 2
        let outcome: PersistOutcome
        let draftWriter = testDraftWriter
        if asyncIO {
            let dir = root
            pendingSaveIDs.insert(record.id)
            outcome = await withCheckedContinuation { continuation in
                ioQueue.async {
                    let result = Self.persistOnDisk(record, in: dir, draftWriter: draftWriter)
                    continuation.resume(returning: result)
                }
            }
            pendingSaveIDs.remove(record.id)
        } else {
            outcome = Self.persistOnDisk(record, in: root, draftWriter: draftWriter)
        }
        applyOutcome(outcome, for: record, upsertOnSuccess: true)
        return SaveResult(record: record, outcome: outcome)
    }

    @discardableResult
    func update(_ id: UUID, change: (inout SessionRecord) -> Void) -> Bool {
        // A late API response or answer must never resurrect a deleted session.
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        var record = sessions[index]; change(&record)
        guard persist(record, isNewRecord: false) else { return false }
        sessions[index] = record
        return true
    }

    @discardableResult
    func rename(_ id: UUID, title: String) -> Bool {
        guard let title = SessionNaming.clean(title) else { return false }
        return update(id) { $0.generatedTitle = title; $0.namingState = "manual" }
    }

    func delete(_ record: SessionRecord) {
        deletedIDs.insert(record.id)
        if asyncIO {
            sessions = sessions.filter { $0.id != record.id }
            let dir = root
            let id = record.id
            ioQueue.async { [weak self] in
                let error = Self.deleteOnDisk(id: id, in: dir)
                if let error {
                    Task { @MainActor [weak self] in self?.lastError = error }
                }
            }
            return
        }
        if let url = fileURL(for: record.id) {
            do { try fileManager.removeItem(at: url) }
            catch { lastError = "Could not delete session history. Check disk permissions."; return }
        }
        if let url = directory?.appendingPathComponent(record.id.uuidString + ".txt"), fileManager.fileExists(atPath: url.path) {
            do { try fileManager.removeItem(at: url) } catch { lastError = "Could not delete transcript draft." }
        }
        sessions = sessions.filter { $0.id != record.id }
    }

    func export(_ record: SessionRecord, to url: URL) throws {
        try Data(record.export(markdown: url.pathExtension.lowercased() == "md").utf8).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Wait for any queued background session I/O to finish, bounded so shutdown never hangs.
    func flush(timeout: TimeInterval = 3.0) async {
        guard asyncIO else { return }
        let queue = ioQueue
        let waitNS = UInt64(max(0.05, timeout) * 1_000_000_000)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce() {
                lock.lock()
                let shouldResume = !resumed
                resumed = true
                lock.unlock()
                if shouldResume { continuation.resume() }
            }
            queue.async { resumeOnce() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(min(waitNS, UInt64(Int.max))))) {
                resumeOnce()
            }
        }
    }

    /// Synchronous bounded drain for `applicationWillTerminate`.
    func flushSync(timeout: TimeInterval = 1.5) {
        guard asyncIO else { return }
        let semaphore = DispatchSemaphore(value: 0)
        ioQueue.async { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + max(0.05, timeout))
    }

    // MARK: - Disk

    private func fileURL(for id: UUID) -> URL? {
        directory?.appendingPathComponent("\(id.uuidString).json")
    }

    private func upsertSession(_ record: SessionRecord) {
        if let index = sessions.firstIndex(where: { $0.id == record.id }) {
            sessions[index] = record
        } else {
            sessions = ([record] + sessions).sorted { $0.startedAt > $1.startedAt }
        }
    }

    private func applyOutcome(_ outcome: PersistOutcome, for record: SessionRecord, upsertOnSuccess: Bool, rollbackNewRecordOnFailure: Bool = false) {
        switch outcome {
        case .saved:
            failedSaveIDs.remove(record.id)
            lastError = nil
            lastDraftWarning = nil
            if upsertOnSuccess { upsertSession(record) }
        case .savedWithoutDraft(let warning):
            failedSaveIDs.remove(record.id)
            lastDraftWarning = warning
            lastError = warning
            if upsertOnSuccess { upsertSession(record) }
        case .failed(let message):
            failedSaveIDs.insert(record.id)
            lastDraftWarning = nil
            lastError = message
            if rollbackNewRecordOnFailure {
                sessions = sessions.filter { $0.id != record.id }
            }
        }
    }

    /// Synchronous persistence helper for `applicationWillTerminate` fallback.
    @discardableResult
    func saveSnapshotSync(id: UUID = UUID(), lines: [SessionLine], startedAt: Date, endedAt: Date = Date(), fragments: [TranscriptFragment] = [], answers: [SessionAnswer]) -> SaveResult? {
        guard !lines.isEmpty || !answers.isEmpty else { return nil }
        var record = SessionRecord(id: id, startedAt: startedAt, endedAt: endedAt, lines: lines)
        record.fragments = fragments; record.answers = answers; record.schemaVersion = 2
        let outcome = Self.persistOnDisk(record, in: root, draftWriter: testDraftWriter)
        applyOutcome(outcome, for: record, upsertOnSuccess: true)
        return SaveResult(record: record, outcome: outcome)
    }

    private func persist(_ record: SessionRecord, isNewRecord: Bool) -> Bool {
        let draftWriter = testDraftWriter
        if asyncIO {
            let dir = root
            lastError = nil
            lastDraftWarning = nil
            pendingSaveIDs.insert(record.id)
            ioQueue.async { [weak self] in
                let outcome = Self.persistOnDisk(record, in: dir, draftWriter: draftWriter)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pendingSaveIDs.remove(record.id)
                    self.applyOutcome(outcome, for: record, upsertOnSuccess: false, rollbackNewRecordOnFailure: isNewRecord)
                }
            }
            return true
        }
        let outcome = Self.persistOnDisk(record, in: root, draftWriter: draftWriter)
        applyOutcome(outcome, for: record, upsertOnSuccess: false)
        return outcome.jsonPersisted
    }

    private func loadAll() {
        guard let dir = directory else { return }
        sessions = Self.readAllFromDisk(in: dir)
    }

    private func loadAllAsync() {
        let dir = root
        ioQueue.async { [weak self] in
            let loaded = Self.readAllFromDisk(in: dir)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let existingIDs = Set(self.sessions.map(\.id))
                let merged = self.sessions + loaded.filter { !existingIDs.contains($0.id) && !self.deletedIDs.contains($0.id) }
                self.sessions = merged.sorted { $0.startedAt > $1.startedAt }
            }
        }
    }

    private nonisolated static func ensureDirectory(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                DebugLog.log("SessionStore: create dir failed: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    private nonisolated static func readAllFromDisk(in dir: URL) -> [SessionRecord] {
        guard ensureDirectory(dir) else { return [] }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded: [SessionRecord] = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard var record = try? decoder.decode(SessionRecord.self, from: data) else { return nil }
                if record.namingState == "pending" { record.namingState = "failed" }
                return record
            }
        return loaded.sorted { $0.startedAt > $1.startedAt }
    }

    private nonisolated static func persistOnDisk(_ record: SessionRecord, in dir: URL, draftWriter: (@Sendable (SessionRecord, URL) throws -> Void)? = nil) -> PersistOutcome {
        guard ensureDirectory(dir) else { return .failed("Cannot access local session storage.") }
        let fm = FileManager.default
        let url = dir.appendingPathComponent("\(record.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let txtURL = url.deletingPathExtension().appendingPathExtension("txt")
            do {
                if let draftWriter {
                    try draftWriter(record, txtURL)
                } else {
                    try Data(record.export(markdown: false).utf8).write(to: txtURL, options: .atomic)
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: txtURL.path)
                }
                return .saved
            } catch {
                return .savedWithoutDraft("Session saved; transcript draft could not be written. You can export it from History.")
            }
        } catch {
            return .failed("Session history could not be saved. Check available disk space and permissions.")
        }
    }

    private nonisolated static func deleteOnDisk(id: UUID, in dir: URL) -> String? {
        let fm = FileManager.default
        let jsonURL = dir.appendingPathComponent("\(id.uuidString).json")
        if fm.fileExists(atPath: jsonURL.path) {
            do { try fm.removeItem(at: jsonURL) }
            catch { return "Could not delete session history. Check disk permissions." }
        }
        let txtURL = dir.appendingPathComponent("\(id.uuidString).txt")
        if fm.fileExists(atPath: txtURL.path) {
            do { try fm.removeItem(at: txtURL) }
            catch { return "Could not delete transcript draft." }
        }
        return nil
    }
}
