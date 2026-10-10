// Standalone UI acceptance fixture. No services, user data or recording.
// Logs cursor identity/window ownership only; never entered text.
import AppKit
import SwiftUI

private struct CursorFixture: View {
    @State private var query = ""
    @State private var protected = true
    let changed: (Bool) -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text("鼠标样式诊断（不发送问题）")
            TextField("点击输入区", text: $query, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Toggle("保护开启", isOn: $protected).onChange(of: protected) { _, value in changed(value) }
            Text("选择文字与输入不变；保护开启时鼠标应为箭头。")
                .font(.caption)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: OverlayWindow!
    var timer: Timer?
    var last = ""
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = OverlayWindow(rootView: CursorFixture(changed: { [weak self] value in
            self?.window.setCaptureExcluded(value)
        }))
        window.title = "LiveCopilot 鼠标诊断"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.configure(autoHeight: false, edgeHide: false)
        window.setFrame(NSRect(x: 60, y: 140, width: 430, height: 260), display: true)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dump() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { NSApp.terminate(nil) }
    }
    func dump() {
        let cursor = NSCursor.current
        let name = cursor === NSCursor.arrow ? "arrow" : cursor === NSCursor.iBeam ? "ibeam" : "other"
        let point = NSEvent.mouseLocation
        let row = "cursor=\(name) inside=\(window.frame.contains(point)) topMatches=\(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber) sharing=\(window.sharingType.rawValue)"
        if row != last { print(row); fflush(stdout); last = row }
    }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { window.stopWatching() }
}

@main struct CursorProtectionProbe {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = Delegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
