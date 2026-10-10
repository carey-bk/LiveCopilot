// Local, opt-in compositor test. Captures only a rectangle covered by synthetic
// fixture windows; no audio, keys, user files or network. Not a meeting-client test.
// Build with OverlayWindow, OverlayResizeView, OverlayLayout and WindowCaptureProtection.
import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreImage
import Darwin

private final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext()
    private var images: [CGImage] = []
    private var earliestDisplayTime: UInt64 = 0
    func reset() {
        lock.lock(); images.removeAll(); earliestDisplayTime = mach_absolute_time(); lock.unlock()
    }
    func snapshots() -> [CGImage] { lock.lock(); defer { lock.unlock() }; return images }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let displayTime = attachments.first?[.displayTime] as? NSNumber,
              let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pixel)
        guard let image = context.createCGImage(ci, from: ci.extent) else { return }
        lock.lock()
        // A previous phase's frames can still be queued when a setting changes.
        // Compare capture display time, not callback arrival time, at the boundary.
        if displayTime.uint64Value >= earliestDisplayTime {
            images.append(image); if images.count > 60 { images.removeFirst() }
        }
        lock.unlock()
    }
}

@main struct CaptureProtectionProbe {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count == 2, CGPreflightScreenCaptureAccess() else {
            print("Explicit output directory and existing screen capture permission required."); exit(2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let screen = NSScreen.main!
        let area = CGRect(x: screen.visibleFrame.minX+30, y: screen.visibleFrame.minY+40, width: 800, height: 500)
        guard screen.visibleFrame.contains(area) else { print("Display too small for protected fixtures"); exit(2) }
        func box(_ rect: CGRect, _ color: NSColor, _ title: String, _ level: Int) -> NSWindow {
            let w = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            w.title=title; w.isReleasedWhenClosed=false; w.isOpaque=true; w.backgroundColor=color
            w.hasShadow=false; w.level=NSWindow.Level(rawValue: level); w.sharingType = .readOnly
            w.orderFrontRegardless(); return w
        }
        let base = box(area, .green, "Synthetic background", 25)
        let settings = box(CGRect(x: area.minX+570, y: area.minY+100, width: 180, height: 160), .blue, "Synthetic settings / setup", 26)
        let overlay = OverlayWindow(rootView: Color.red)
        overlay.isReleasedWhenClosed=false; overlay.hasShadow=false; overlay.level=NSWindow.Level(rawValue: 26)
        overlay.isOpaque=true; overlay.backgroundColor = .red
        // Red backing avoids dependence on SwiftUI text/color rendering.
        overlay.contentView=NSView(); overlay.configure(autoHeight: false, edgeHide: false)
        overlay.setFrame(CGRect(x: area.minX+20, y: area.minY+90, width: 400, height: 250), display: true)
        overlay.setCaptureExcluded(false); overlay.orderFrontRegardless()
        var failed = false
        Task { @MainActor in
            var stream: SCStream?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let display = content.displays.first { $0.displayID == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) }!
                let ids = Set([base.windowNumber, settings.windowNumber, overlay.windowNumber].map { UInt32($0) })
                let windows = content.windows.filter { ids.contains($0.windowID) }
                guard windows.count == 3 else { throw NSError(domain: "Fixtures", code: 1) }
                let full = SCContentFilter(display: display, excludingWindows: [])
                let explicit = SCContentFilter(display: display, including: windows)
                let config = SCStreamConfiguration()
                config.width=800; config.height=500; config.showsCursor=false; config.capturesAudio=false
                config.minimumFrameInterval=CMTime(value: 1, timescale: 30); config.queueDepth=3
                config.sourceRect=CGRect(x: area.minX-screen.frame.minX, y: screen.frame.maxY-area.maxY, width: area.width, height: area.height)
                let sink = FrameSink()
                let capture = SCStream(filter: full, configuration: config, delegate: nil); stream=capture
                try capture.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "synthetic.capture"))
                try await capture.startCapture()
                var rows: [[String: Any]] = []
                @MainActor func record(_ name: String, expectHidden: Bool?) async throws {
                    sink.reset()
                    // A visible fixture update forces a new non-idle video frame.
                    for n in 0..<20 {
                        base.backgroundColor = n % 2 == 0 ? .green : NSColor(calibratedRed: 0.1, green: 0.9, blue: 0.1, alpha: 1)
                        base.contentView?.needsDisplay = true
                        base.displayIfNeeded()
                        try await Task.sleep(nanoseconds: 60_000_000)
                    }
                    let frames = sink.snapshots()
                    guard let final = frames.last else { throw NSError(domain: "NoVideoFrames", code: 2) }
                    func counts(_ image: CGImage) -> (Int,Int) {
                        let bitmap=NSBitmapImageRep(cgImage:image)
                        var red=0,blue=0
                        // Coarse sampling is enough for large, solid marker regions.
                        for y in stride(from:0,to:bitmap.pixelsHigh,by:4) { for x in stride(from:0,to:bitmap.pixelsWide,by:4) {
                            guard let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { continue }
                            if c.redComponent > 0.7 && c.greenComponent < 0.35 && c.blueComponent < 0.35 { red += 1 }
                            if c.blueComponent > 0.7 && c.greenComponent < 0.35 && c.redComponent < 0.35 { blue += 1 }
                        } }
                        return (red,blue)
                    }
                    let values=frames.map(counts), redMax=values.map{$0.0}.max()!, blueMin=values.map{$0.1}.min()!
                    let pass=overlay.isVisible && overlay.alphaValue == 1 && blueMin > 500 &&
                        (expectHidden == nil || (expectHidden! ? redMax == 0 : values.last!.0 > 500))
                    if !pass { failed=true }
                    let row: [String:Any] = ["phase":name,"frames":frames.count,"red_max":redMax,"red_last":values.last!.0,"red_frames":values.filter{$0.0 > 0}.count,"blue_min":blueMin,"local_visible":overlay.isVisible,"alpha":overlay.alphaValue,"status":String(describing:overlay.captureProtectionStatus),"pass":pass]
                    rows.append(row); print(row)
                    try NSBitmapImageRep(cgImage:final).representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(name+".png"))
                }
                try await record("unprotected-display", expectHidden:false)
                overlay.setCaptureExcluded(true)
                try await record("protected-display", expectHidden:true)
                try await capture.updateContentFilter(explicit)
                try await record("protected-explicit-windows", expectHidden:true)
                overlay.setFrame(CGRect(x:area.minX+20,y:area.minY+90,width:520,height:360),display:true,animate:true)
                try await record("protected-enlarged", expectHidden:true)
                overlay.setFrame(CGRect(x:area.minX+55,y:area.minY+60,width:410,height:270),display:true)
                try await record("protected-resized-and-moved", expectHidden:true)
                overlay.orderOut(nil); overlay.orderFrontRegardless()
                try await capture.updateContentFilter(full)
                try await record("protected-reshown-display", expectHidden:true)
                overlay.setCaptureExcluded(false)
                try await record("disabled-display", expectHidden:false)
                overlay.setCaptureExcluded(true)
                try await capture.stopCapture(); try await capture.startCapture()
                try await record("protected-restarted-stream", expectHidden:true)
                try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("results.json"))
                try await capture.stopCapture(); stream=nil
            } catch { failed=true; print("CAPTURE_TEST_ERROR",error); if let stream { try? await stream.stopCapture() } }
            overlay.close(); settings.close(); base.close(); app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:0,data1:0,data2:0)!,atStart:false)
        }
        app.run(); exit(failed ? 1 : 0)
    }
}
