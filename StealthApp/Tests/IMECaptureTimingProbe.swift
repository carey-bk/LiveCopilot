// Synthetic compositor regression for first display / focus loss / panel reuse.
// Captures only a rectangle covered by fixtures, never audio or typed text.
// Build with WindowCaptureProtection.swift. Real IME/Tencent acceptance is separate.
import AppKit
import ScreenCaptureKit
import CoreImage
import Darwin

private final class InputOwner: NSPanel {
    var ownsInput = false
    override var isKeyWindow: Bool { ownsInput }
}

private final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext()
    private var frames: [CGImage] = []
    private var boundary: UInt64 = 0
    func reset() { lock.lock(); frames = []; boundary = mach_absolute_time(); lock.unlock() }
    func snapshots() -> [CGImage] { lock.lock(); defer { lock.unlock() }; return frames }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete,
              let timestamp = attachments.first?[.displayTime] as? NSNumber,
              let pixel = CMSampleBufferGetImageBuffer(buffer),
              let image = context.createCGImage(CIImage(cvPixelBuffer: pixel), from: CIImage(cvPixelBuffer: pixel).extent) else { return }
        lock.lock(); defer { lock.unlock() }
        if timestamp.uint64Value >= boundary { frames.append(image) }
    }
}

@main struct IMECaptureTimingProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count == 2, CGPreflightScreenCaptureAccess(), let screen = NSScreen.main else {
            print("Output directory and existing capture permission required"); exit(2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let area = CGRect(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 110, width: 640, height: 200)
        guard screen.visibleFrame.contains(area) else { exit(2) }
        func box(_ rect: CGRect, _ color: NSColor, _ level: Int) -> NSPanel {
            let window = NSPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.hasShadow = false
            window.hidesOnDeactivate = false
            window.isOpaque = true; window.backgroundColor = color
            window.contentView = NSView(); window.level = NSWindow.Level(rawValue: level)
            return window
        }
        let backdrop = box(area, .green, 25)
        let normal = box(CGRect(x: area.minX + 510, y: area.minY + 35, width: 110, height: 120), .blue, 26)
        backdrop.orderFrontRegardless(); normal.orderFrontRegardless()
        guard backdrop.isVisible && normal.isVisible else { exit(2) }
        let owner = InputOwner(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        owner.contentView = editor
        guard owner.makeFirstResponder(editor) else { exit(2) }
        var panels: [NSPanel] = []
        let protection = OverlayInputCaptureProtection(overlay: owner, candidate: { window in panels.contains { $0 === window } })
        func candidate() -> NSPanel {
            let panel = box(CGRect(x: area.minX + 25, y: area.minY + 90, width: 390, height: 32), .red, 26)
            panels.append(panel); return panel
        }
        var failed = false
        Task { @MainActor in
            var activeStream: SCStream?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw NSError(domain: "Display", code: 1) }
                let config = SCStreamConfiguration()
                config.width = 640; config.height = 200; config.showsCursor = false; config.capturesAudio = false
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60); config.queueDepth = 5
                config.sourceRect = CGRect(x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY, width: area.width, height: area.height)
                let sink = FrameSink()
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
                activeStream = stream
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "synthetic.ime.capture"))
                try await stream.startCapture()
                var tick = 0
                @MainActor func redraw(_ count: Int) async throws {
                    for _ in 0..<count {
                        tick += 1
                        backdrop.backgroundColor = tick % 2 == 0 ? .green : NSColor(calibratedRed: 0.1, green: 0.9, blue: 0.1, alpha: 1)
                        backdrop.displayIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
                var rows: [[String: Any]] = []
                func record(_ phase: String, hidden: Bool) throws {
                    let frames = sink.snapshots()
                    guard let last = frames.last else { throw NSError(domain: "NoFrames", code: 2) }
                    let counts = frames.map { image -> (Int, Int) in
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        var red = 0, blue = 0
                        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                                if c.redComponent > 0.7 && c.greenComponent < 0.35 && c.blueComponent < 0.35 { red += 1 }
                                if c.blueComponent > 0.7 && c.greenComponent < 0.35 && c.redComponent < 0.35 { blue += 1 }
                            }
                        }
                        return (red, blue)
                    }
                    let redMax = counts.map { $0.0 }.max()!, blueMin = counts.map { $0.1 }.min()!
                    let pass = blueMin > 1000 && (hidden ? redMax == 0 : counts.last!.0 > 1000)
                    failed = failed || !pass
                    let row: [String: Any] = ["phase": phase, "frames": frames.count, "red_max": redMax,
                                             "red_frames": counts.filter { $0.0 > 0 }.count, "blue_min": blueMin, "pass": pass]
                    rows.append(row); print(row)
                    try NSBitmapImageRep(cgImage: last).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(phase + ".png"))
                }
                sink.reset()
                var panel = candidate()
                // Capture continuously across all 12 cycles, including the very
                // first presentation and blur. No settling delay discards frames.
                for n in 0..<12 {
                    if n % 3 == 0 { panel = candidate() }
                    owner.ownsInput = true
                    panel.orderFrontRegardless()
                    failed = failed || !panel.isVisible || panel.sharingType != .none
                    try await redraw(4)
                    owner.ownsInput = false
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: owner)
                    failed = failed || panel.sharingType != .none
                    try await redraw(4)
                    panel.orderOut(nil)
                    try await redraw(2)
                }
                try record("protected-first-display-blur-repeat", hidden: true)
                sink.reset()
                panel.orderFrontRegardless()
                try await redraw(12)
                try record("ordinary-input-reuses-panel", hidden: false)
                panel.orderOut(nil)
                owner.ownsInput = true
                sink.reset()
                panel.orderFrontRegardless()
                try await redraw(8)
                try record("return-to-protected-input", hidden: true)
                sink.reset()
                protection.stop()
                try await redraw(8)
                try record("close-protected-input", hidden: true)
                try await stream.stopCapture(); activeStream = nil
                try JSONSerialization.data(withJSONObject: ["cycles": 12, "pass": !failed, "phases": rows], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("results.json"))
            } catch {
                failed = true; print("IME_CAPTURE_TEST_ERROR", error)
                if let activeStream { try? await activeStream.stopCapture() }
            }
            protection.stop(); panels.forEach { $0.close() }; owner.close(); normal.close(); backdrop.close()
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        app.run(); exit(failed ? 1 : 0)
    }
}
