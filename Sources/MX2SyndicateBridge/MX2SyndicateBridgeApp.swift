import AppKit
import SwiftUI
import BridgeCore

@main
struct MX2SyndicateBridgeApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        Window("MX2 → Syndicate", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Reveal Source Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath:
                        "/Users/ellie/git/indirect-input", isDirectory: true))
                }
            }
        }
    }
}
