// Standalone, synthetic input-method diagnostic. Logs only this process's
// window/view classes and geometry, never the text being typed. No network/audio.
import AppKit

private final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var timer: Timer?
    var last = ""
    var protection: OverlayInputCaptureProtection?
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 160, width: 420, height: 120),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LiveCopilot 输入法诊断"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let label = NSTextField(labelWithString: "仅测试拼音候选窗口，不发送问题")
        label.frame = NSRect(x: 18, y: 78, width: 384, height: 24)
        let field = NSTextField(frame: NSRect(x: 18, y: 34, width: 384, height: 30))
        field.placeholderString = "输入 nihao，先不要按空格"
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--protect") {
            protection = OverlayInputCaptureProtection(overlay: window)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.dump() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) { NSApp.terminate(nil) }
    }
    func dump() {
        func classes(_ view: NSView?, depth: Int = 0) -> [String] {
            guard let view, depth < 4 else { return [] }
            return [String(repeating: " ", count: depth) + NSStringFromClass(type(of: view))] + view.subviews.flatMap { classes($0, depth: depth + 1) }
        }
        let rows = NSApp.windows.map { w in
            "id=\(w.windowNumber) class=\(NSStringFromClass(type(of: w))) visible=\(w.isVisible) sharing=\(w.sharingType.rawValue) level=\(w.level.rawValue) parent=\(w.parent?.windowNumber ?? -1) frame=\(w.frame) views=\(classes(w.contentView))"
        }.sorted().joined(separator: "\n")
        guard rows != last else { return }
        last = rows
        print("OWN_WINDOWS\n" + rows)
        fflush(stdout)
    }
    func windowWillClose(_ notification: Notification) { protection?.stop(); NSApp.terminate(nil) }
}

@main struct IMEWindowProbe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
