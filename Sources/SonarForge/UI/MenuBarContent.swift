import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SonarForge")
                    .font(.headline)
                Spacer()
                Text(appModel.isBypassed ? "Bypassed" : "Active")
                    .font(.caption)
                    .foregroundStyle(appModel.isBypassed ? .orange : .green)
            }
            .padding(.bottom, 4)

            Divider()

            Toggle("Enable Processing", isOn: .constant(!appModel.isBypassed))
                .onChange(of: appModel.isBypassed) { _, _ in
                    // The toggle above is illustrative; wire to real action
                }

            Button("Open Main Window") {
                // Activate the main window / bring to front
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            // Quick profile switcher (populated from favorites / recents later)
            Text("Quick Profiles")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Flat") {
                appModel.loadProfile(.flat)
            }

            // Placeholder for dynamic profile list
            // ForEach(favoriteProfiles) { profile in ... }

            Divider()

            Button("Quit SonarForge") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 240)
    }
}
