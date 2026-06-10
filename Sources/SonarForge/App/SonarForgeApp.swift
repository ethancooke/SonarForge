import SwiftUI

@main
struct SonarForgeApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 620)
        .windowToolbarStyle(.unified)

        // Status item / menu bar extra
        MenuBarExtra {
            MenuBarContent()
                .environment(appModel)
        } label: {
            // Use a simple SF Symbol or custom asset for now
            Image(systemName: appModel.isBypassed ? "waveform.slash" : "waveform")
        }
        .menuBarExtraStyle(.window) // or .menu for simpler menu
    }
}
