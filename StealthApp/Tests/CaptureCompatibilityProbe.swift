// Manual meeting-client compatibility matrix. Synthetic UI only, no capture,
// microphone, network, preferences or credentials. Close the legend to quit.
import AppKit
import SwiftUI

private struct ProbeContent: View {
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(.title2.bold())
            Text("本机应始终看见这行文字").font(.headline)
            Text("SwiftUI / native rendering comparison").font(.caption)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
}

private final class ProbeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main, let backend = WindowCaptureProtection.Backend.system() else {
            print("Probe needs a display and the private exclusion symbols"); NSApp.terminate(nil); return
        }
        let x = screen.visibleFrame.minX + 55, top = screen.visibleFrame.maxY - 65
        let legend = NSWindow(contentRect: CGRect(x:x,y:top-72,width:730,height:62),
                              styleMask:[.titled,.closable],backing:.buffered,defer:false)
        legend.title = "LiveCopilot 共享诊断（关闭此窗退出）"
        legend.isReleasedWhenClosed = false; legend.delegate = self; legend.level = .floating
        let heading = NSTextField(labelWithString:"左上 A 对照　右上 B 旧标记\n左下 C 排除区域　右下 D 两者同时")
        let rendering = CommandLine.arguments.contains("--rendering")
        if rendering { heading.stringValue = "左上 A 基准　右上 B 正式窗口\n左下 C 圆角容器　右下 D 正式窗口属性" }
        heading.font = .systemFont(ofSize:18,weight:.semibold); heading.frame = CGRect(x:16,y:8,width:700,height:48)
        legend.contentView?.addSubview(heading); legend.orderFrontRegardless(); windows.append(legend)
        let cases = rendering ? [("A · 基准窗口",true,true),("B · 正式窗口",true,true),
                                 ("C · 圆角容器",true,true),("D · 正式窗口属性",true,true)] :
                                [("A · 无保护",false,false),("B · 仅旧标记",true,false),
                                 ("C · 仅排除区域",false,true),("D · 两者同时",true,true)]
        for (i,item) in cases.enumerated() {
            let rect = CGRect(x:x+CGFloat(i%2)*415,y:top-330-CGFloat(i/2)*270,width:400,height:250)
            if rendering && i == 1 {
                let window = OverlayWindow(rootView: ProbeContent(label:item.0))
                window.isReleasedWhenClosed=false; window.configure(autoHeight:false,edgeHide:false)
                window.setFrame(rect,display:true); window.orderFrontRegardless(); windows.append(window)
                print("\(item.0) id=\(window.windowNumber) production=\(window.captureProtectionStatus)")
                continue
            }
            let window = NSPanel(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false; window.level = .floating
            window.hidesOnDeactivate=false; window.isOpaque=false; window.backgroundColor = .clear
            window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            if rendering && i == 3 {
                window.styleMask=[.nonactivatingPanel,.fullSizeContentView,.borderless,.resizable]
                window.collectionBehavior.insert(.stationary)
                window.isFloatingPanel=true; window.becomesKeyOnlyIfNeeded=true
                window.titleVisibility = .hidden; window.titlebarAppearsTransparent=true
            }
            window.title=item.0
            let root=NSView(frame:CGRect(origin:.zero,size:rect.size)); root.wantsLayer=true
            let hosting=NSHostingView(rootView:ProbeContent(label:item.0)); hosting.frame=CGRect(x:0,y:50,width:400,height:200)
            root.addSubview(hosting)
            let native=NSTextField(labelWithString:"AppKit 原生文字 123 ABC")
            native.font = .systemFont(ofSize:20,weight:.bold); native.textColor = .white
            native.frame=CGRect(x:16,y:10,width:320,height:32); root.addSubview(native)
            root.layer?.backgroundColor=NSColor.systemBlue.cgColor; window.contentView=root
            if rendering && i == 2 {
                window.contentView=OverlayResizeView(content: NSHostingView(rootView:ProbeContent(label:item.0)))
            }
            window.sharingType=item.1 ? .none : .readOnly
            // Do not clear a region after assigning .none: on some systems the
            // legacy setter itself uses that region and a clear would undo it.
            let code=item.2 ? backend.setRegion(window.windowNumber,CGRect(origin:.zero,size:rect.size)) : 0
            window.orderFrontRegardless(); windows.append(window)
            print("\(item.0) id=\(window.windowNumber) private-result=\(code) sharing=\(window.sharingType.rawValue)")
        }
        fflush(stdout)
    }
}

@main struct CaptureCompatibilityProbe {
    @MainActor static func main() {
        let app=NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate=ProbeDelegate(); app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
