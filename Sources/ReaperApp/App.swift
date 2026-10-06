import ReaperCore
import SwiftUI

@main
struct ReaperApp: App {
    @ObservedObject private var monitor = Monitor.shared

    init() {
        // Dev aid: `ReaperApp --render out.png [dark]` draws the panel and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            renderPanel(to: args[i + 1], dark: args.contains("dark"))
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            Image(nsImage: Icon.slits)
        }
        .menuBarExtraStyle(.window)
    }
}
