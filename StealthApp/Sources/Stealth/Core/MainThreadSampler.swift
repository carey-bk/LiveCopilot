import Foundation
import Darwin
import MachO

/// Captures the main thread's call stack from another thread while the main thread is stuck,
/// so a freeze report shows where it was spinning. Content-free: return addresses, image names,
/// image UUIDs and offsets, and the nearest exported symbol; no arguments, memory or strings.
final class MainThreadSampler: @unchecked Sendable {
    static let shared = MainThreadSampler()
    private let lock = NSLock()
    private var mainThread: thread_act_t = 0
    static let maximumDepth = 160

    /// Call once on the main thread at launch.
    func registerMainThread() {
        precondition(Thread.isMainThread)
        lock.withLock { if mainThread == 0 { mainThread = mach_thread_self() } }
    }

    var isRegistered: Bool { lock.withLock { mainThread != 0 } }

    /// Return addresses, innermost first. Never call from the main thread.
    func captureOnce() -> [UInt] {
        let thread = lock.withLock { mainThread }
        guard thread != 0, !Thread.isMainThread else { return [] }
        // Allocated before suspending: the main thread may hold the malloc lock while suspended.
        var buffer = [UInt](repeating: 0, count: Self.maximumDepth)
        var depth = 0
        buffer.withUnsafeMutableBufferPointer { frames in
            guard thread_suspend(thread) == KERN_SUCCESS else { return }
            defer { thread_resume(thread) }
            guard let registers = Self.registers(of: thread) else { return }
            frames[0] = registers.pc; depth = 1
            if let link = registers.link, depth < frames.count { frames[depth] = link; depth += 1 }
            var framePointer = registers.fp
            var pair: (UInt, UInt) = (0, 0)
            while depth < frames.count, framePointer != 0, framePointer % UInt(MemoryLayout<UInt>.alignment) == 0 {
                var size: vm_size_t = 0
                let status = withUnsafeMutablePointer(to: &pair) { pointer in
                    vm_read_overwrite(mach_task_self_, vm_address_t(framePointer), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                      vm_address_t(UInt(bitPattern: pointer)), &size)
                }
                guard status == KERN_SUCCESS else { break }
                let returnAddress = Self.strip(pair.1)
                guard returnAddress != 0 else { break }
                frames[depth] = returnAddress; depth += 1
                // Stacks grow down: the caller's frame record is always higher.
                guard pair.0 > framePointer else { break }
                framePointer = pair.0
            }
        }
        return Array(buffer.prefix(depth))
    }

    /// Several captures, `interval` apart.
    func sample(count: Int = 10, interval: TimeInterval = 0.2) -> [[UInt]] {
        (0..<count).compactMap { index in
            if index > 0 { Thread.sleep(forTimeInterval: interval) }
            let frames = captureOnce()
            return frames.isEmpty ? nil : frames
        }
    }

    private struct Registers { let pc: UInt; let fp: UInt; let link: UInt? }

    private static func registers(of thread: thread_act_t) -> Registers? {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Registers(pc: strip(UInt(state.__pc)), fp: UInt(state.__fp), link: strip(UInt(state.__lr)))
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(x86_THREAD_STATE64), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Registers(pc: UInt(state.__rip), fp: UInt(state.__rbp), link: nil)
        #else
        return nil
        #endif
    }

    /// Removes pointer-authentication bits from return addresses of arm64e system frameworks.
    private static func strip(_ address: UInt) -> UInt {
        #if arch(arm64)
        return address & 0x0000_7FFF_FFFF_FFFF
        #else
        return address
        #endif
    }
}

/// Turns sampled addresses into a readable, shareable report. Runs after the main thread resumed.
enum StackReport {
    struct Frame: Hashable { let image: String; let offset: UInt; let symbol: String? }

    static func frame(_ address: UInt) -> Frame {
        var info = Dl_info()
        guard address != 0, dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return Frame(image: "?", offset: address, symbol: nil)
        }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        let base = UInt(bitPattern: info.dli_fbase)
        let symbol = info.dli_sname.map { String(cString: $0) }
        return Frame(image: image, offset: address &- base, symbol: symbol)
    }

    /// UUIDs of the images in `frames`, for offline symbolication of offsets.
    static func imageUUIDs(_ names: Set<String>) -> [String: String] {
        var result = [String: String]()
        for index in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { continue }
            let name = URL(fileURLWithPath: String(cString: cName)).lastPathComponent
            guard names.contains(name), result[name] == nil, let uuid = uuid(header) else { continue }
            result[name] = uuid
        }
        return result
    }

    private static func uuid(_ header: UnsafePointer<mach_header>) -> String? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == UInt32(LC_UUID) {
                let bytes = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: bytes).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }

    /// Identical stacks are grouped and the most frequent comes first.
    static func text(samples: [[UInt]], stallMS: Int, appVersion: String) -> String {
        var counts = [[UInt]: Int]()
        for sample in samples { counts[sample, default: 0] += 1 }
        let ordered = counts.sorted { $0.value > $1.value }
        var images = Set<String>()
        var lines = ["LiveCopilot main-thread stack", "App: \(appVersion)",
                     "Main thread unresponsive for at least \(stallMS) ms when sampled.",
                     "Samples: \(samples.count), distinct stacks: \(ordered.count). Innermost frame first.", ""]
        for (index, entry) in ordered.enumerated() {
            lines.append("Stack \(index + 1) · seen in \(entry.value) of \(samples.count) samples")
            for (depth, address) in entry.key.enumerated() {
                let frame = frame(address)
                images.insert(frame.image)
                let symbol = frame.symbol.map { "  \($0)" } ?? ""
                lines.append(String(format: "%3d  %@ + 0x%llx", depth, frame.image, UInt64(frame.offset)) + symbol)
            }
            lines.append("")
        }
        lines.append("Image UUIDs")
        for (name, uuid) in imageUUIDs(images).sorted(by: { $0.key < $1.key }) { lines.append("  \(name)  \(uuid)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The first frames that belong to this app, else the innermost frames, for the event journal.
    static func summary(samples: [[UInt]]) -> String {
        guard let first = samples.first else { return "" }
        let frames = first.map(frame)
        let own = frames.filter { $0.image == "LiveCopilot" || $0.image.hasPrefix("LiveCopilot") }
        return (own.isEmpty ? Array(frames.prefix(3)) : Array(own.prefix(3)))
            .map { "\($0.image)+0x\(String($0.offset, radix: 16))" }.joined(separator: " < ")
    }

    /// Same data folder as `AppPaths.dataDirectory()` for the app and Debug builds (never mock).
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let app = Bundle.main.bundleIdentifier == "com.livecopilot.development" ? "LiveCopilot/Development" : "LiveCopilot"
        return base.appendingPathComponent(app + "/diagnostics/stalls", isDirectory: true)
    }

    /// Keeps the five newest reports.
    @discardableResult
    static func save(_ text: String, in directory: URL = directory, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("stall-\(stamp).txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        let existing = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("stall-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in existing.dropFirst(5) { try? fm.removeItem(at: old) }
        return url
    }
}
