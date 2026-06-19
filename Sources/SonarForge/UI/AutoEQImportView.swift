import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// AutoEQ import sheet (Chunk 4.2): paste the contents of an AutoEQ
/// ParametricEQ.txt / GraphicEQ.txt, load it from a file, or drop the file on
/// the text area. Shows a live parse preview and creates a profile with
/// mandatory source attribution.
struct AutoEQImportView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var name = ""
    @State private var measuredBy = ""
    @State private var parseResult: AutoEQImporter.ParseResult?
    @State private var parseError: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Attribution is constructed, not user-removable (project requirement, D-006).
    private var attribution: String {
        let measurer = measuredBy.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = measurer.isEmpty ? "AutoEQ" : "AutoEQ / \(measurer)"
        return "\(source) — \(trimmedName.isEmpty ? "Imported Profile" : trimmedName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import AutoEQ Profile")
                .font(.headline)
            Text("Paste the contents of a ParametricEQ.txt (preferred) or GraphicEQ.txt from the AutoEQ project, or drop the file below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    loadFile(at: url)
                    return true
                }
                .onChange(of: text) { _, _ in reparse() }

            HStack {
                Button("Load File…") { runOpenPanel() }
                Spacer()
                previewSummary
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Profile name")
                    TextField("e.g. Sennheiser HD 600", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Measured by")
                    TextField("optional, e.g. oratory1990", text: $measuredBy)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Label(attribution, systemImage: "person.text.rectangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Source attribution is stored in the profile and always displayed.")

            if let parseError {
                Text(parseError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let result = parseResult {
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { commitImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parseResult == nil || parseResult!.bands.isEmpty || trimmedName.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 460)
    }

    @ViewBuilder
    private var previewSummary: some View {
        if let result = parseResult {
            Text("\(result.bands.count) band\(result.bands.count == 1 ? "" : "s"), preamp \(String(format: "%+.1f", result.preamp)) dB")
                .font(.caption)
                .foregroundStyle(result.bands.isEmpty ? .orange : .green)
        } else if text.isEmpty {
            Text("Waiting for input…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func reparse() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parseResult = nil
            parseError = nil
            return
        }
        do {
            parseResult = try AutoEQImporter.parse(text)
            parseError = nil
        } catch {
            parseResult = nil
            parseError = error.localizedDescription
        }
    }

    private func runOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.title = "Load AutoEQ File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFile(at: url)
    }

    private func loadFile(at url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            parseError = "Could not read “\(url.lastPathComponent)” as text."
            return
        }
        text = contents
        if trimmedName.isEmpty {
            name = Self.suggestedName(fromFileName: url.deletingPathExtension().lastPathComponent)
        }
        reparse()
    }

    /// "Sennheiser HD 600 ParametricEQ" → "Sennheiser HD 600"
    static func suggestedName(fromFileName fileName: String) -> String {
        var name = fileName
        for suffix in [" ParametricEQ", " GraphicEQ", "ParametricEQ", "GraphicEQ"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitImport() {
        guard let result = parseResult else { return }
        appModel.importAutoEQ(result, name: trimmedName, measuredBy: measuredBy)
        dismiss()
    }
}
