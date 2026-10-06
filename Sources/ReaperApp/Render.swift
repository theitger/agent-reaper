import ReaperCore
import AppKit
import SwiftUI

@MainActor
func renderPanel(to path: String, dark: Bool) {
    let monitor = Monitor.shared
    monitor.setSnapshotForRendering(Monitor.scan(previous: nil))
    let panel = PanelView(monitor: monitor)
    let buttons = HStack(spacing: 8) {
        QuietButton(title: "Quit") {}
        QuietButton(title: "Stop") {}
        QuietButton(title: "Reap all · 393 MB") {}
    }.padding(14)
    let view = Group { if CommandLine.arguments.contains("buttons") { AnyView(buttons) } else { AnyView(panel) } }
        .background(dark ? Color(white: 0.16) : Color(white: 0.96))
        .environment(\.colorScheme, dark ? .dark : .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    // Muxy's dynamic colors resolve against the current drawing appearance.
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        guard let cg = renderer.cgImage else { print("render failed"); return }
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        do { try png?.write(to: URL(fileURLWithPath: path)) } catch { print(error) }
    }
}
