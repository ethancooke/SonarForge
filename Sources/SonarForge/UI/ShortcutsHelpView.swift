import SwiftUI

/// Keyboard shortcut cheat sheet (Chunk 5.4) — reachable via Help ▸ Keyboard
/// Shortcuts or ⇧⌘/.
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(title: String, items: [(keys: String, action: String)])] = [
        ("Profiles", [
            ("⌘1 – ⌘9", "Switch to quick-switch profile 1–9 (favorites first)"),
            ("⌘B", "Toggle bypass"),
        ]),
        ("Engine", [
            ("⇧⌘E", "Start / stop the audio engine"),
        ]),
        ("EQ Editor (click the curve area first)", [
            ("← / →", "Move selected band by 1/24 octave"),
            ("↑ / ↓", "Change selected band gain by 0.5 dB"),
            ("Drag handle", "Set band frequency and gain"),
            ("⌥ + drag handle", "Adjust band Q (up = narrower)"),
            ("Double-click", "Add a band at that frequency/gain"),
            ("Right-click handle", "Delete the band"),
        ]),
        ("Help", [
            ("⇧⌘/", "Show this cheat sheet"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                        ForEach(section.items, id: \.action) { item in
                            GridRow {
                                Text(item.keys)
                                    .font(.system(.callout, design: .monospaced))
                                    .gridColumnAlignment(.trailing)
                                Text(item.action)
                                    .font(.callout)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }
}
