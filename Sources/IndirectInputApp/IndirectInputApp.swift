import SwiftUI

@main
struct IndirectInputAppApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        Window("Indirect Input", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Reveal diagnostic log") { model.revealLog() }
            }
        }
    }
}
