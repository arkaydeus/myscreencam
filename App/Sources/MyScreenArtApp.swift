import MyScreenArtCore
import SwiftUI

@main
struct MyScreenArtApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryView()
                .environment(environment)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
