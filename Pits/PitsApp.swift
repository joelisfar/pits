import SwiftUI

@main
struct PitsApp: App {
    var body: some Scene {
        WindowGroup("Pits") {
            Text("Pits")
                .frame(minWidth: 400, minHeight: 300)
        }
        .windowResizability(.contentMinSize)
    }
}
