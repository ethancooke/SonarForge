import SwiftUI

@main
struct SonarForgeApp: App {
    @State private var appModel = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appModel)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 620)
        .windowToolbarStyle(.unified)
        .commands {
            // Quick switching while the app is frontmost (Chunk 4.3).
            // System-wide global hotkeys (other app frontmost) are deferred —
            // they require Carbon RegisterEventHotKey or the like.
            CommandMenu("Profiles") {
                Toggle("Bypass", isOn: Binding(
                    get: { appModel.isBypassed },
                    set: { _ in appModel.toggleBypass() }
                ))
                .keyboardShortcut("b", modifiers: .command)

                Divider()

                ForEach(Array(appModel.profileManager.quickSwitchProfiles.prefix(9).enumerated()), id: \.element.id) { index, profile in
                    Button {
                        appModel.selectProfile(id: profile.id)
                    } label: {
                        Text(profile.isFavorite ? "★ \(profile.name)" : profile.name)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }

            CommandGroup(after: .help) {
                Button("Welcome to SonarForge…") {
                    appModel.showingWelcome = true
                }
                Button("Keyboard Shortcuts…") {
                    appModel.showingShortcutsHelp = true
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
                Button("Troubleshooting…") {
                    appModel.showingTroubleshooting = true
                }
            }

            CommandGroup(replacing: .appInfo) {
                Button("About SonarForge") {
                    openWindow(id: "about")
                }
            }
        }

        Window("About SonarForge", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        // Status item / menu bar extra
        MenuBarExtra {
            MenuBarContent()
                .environment(appModel)
        } label: {
            // Distinct at a glance: filled circle = actively processing,
            // slash = bypassed, plain = engine off.
            Image(systemName: appModel.isBypassed ? "waveform.slash"
                  : appModel.isProcessing ? "waveform.circle.fill"
                  : "waveform")
        }
        .menuBarExtraStyle(.window) // or .menu for simpler menu
    }
}
