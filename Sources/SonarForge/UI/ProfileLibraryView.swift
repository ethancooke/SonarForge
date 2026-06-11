import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Debug-grade profile management sheet (Chunk 4.1.3): select, create, rename,
/// duplicate, delete, favorite, export, import. The polished manager window
/// arrives in Phase 5 (Chunk 5.5); this exists so the library is fully usable
/// before then.
struct ProfileLibraryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var deleteCandidate: EQProfile?
    @State private var errorMessage: String?
    @State private var showingAutoEQImport = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Profiles")
                    .font(.headline)
                Spacer()
                Button("New") {
                    let created = appModel.profileManager.create()
                    beginRename(created)
                }
                Button("Import AutoEQ…") { showingAutoEQImport = true }
                Button("Import…") { runImportPanel() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            List {
                ForEach(appModel.profileManager.profiles) { profile in
                    row(for: profile)
                }
            }
            .listStyle(.inset)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            Text("A profile is a plain JSON file — exported files can be shared or re-imported as copies.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)
        }
        .frame(minWidth: 460, minHeight: 360)
        .sheet(isPresented: $showingAutoEQImport) {
            AutoEQImportView()
        }
        .confirmationDialog(
            "Delete “\(deleteCandidate?.name ?? "")”?",
            isPresented: Binding(get: { deleteCandidate != nil },
                                 set: { if !$0 { deleteCandidate = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let candidate = deleteCandidate {
                    appModel.deleteProfile(id: candidate.id)
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("This removes the profile file. Export it first if you want a backup.")
        }
    }

    @ViewBuilder
    private func row(for profile: EQProfile) -> some View {
        let isActive = profile.id == appModel.profileManager.activeProfileID

        HStack(spacing: 8) {
            Button {
                appModel.profileManager.toggleFavorite(profile.id)
            } label: {
                Image(systemName: profile.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(profile.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(profile.isFavorite ? "Remove from favorites" : "Add to favorites")

            if renamingID == profile.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(profile) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(profile.name)
                    .fontWeight(isActive ? .semibold : .regular)
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Active profile")
                }
                if let attribution = profile.sourceAttribution {
                    Text(attribution)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !isActive {
                Button("Activate") { appModel.selectProfile(id: profile.id) }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Activate") { appModel.selectProfile(id: profile.id) }
                .disabled(isActive)
            Button("Rename") { beginRename(profile) }
            Button("Duplicate") { _ = appModel.profileManager.duplicate(profile.id) }
            Button("Export…") { runExportPanel(for: profile) }
            Divider()
            Button("Delete", role: .destructive) { deleteCandidate = profile }
        }
    }

    // MARK: - Actions

    private func beginRename(_ profile: EQProfile) {
        renameText = profile.name
        renamingID = profile.id
    }

    private func commitRename(_ profile: EQProfile) {
        appModel.profileManager.rename(profile.id, to: renameText)
        renamingID = nil
    }

    private func runExportPanel(for profile: EQProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).json"
        panel.title = "Export Profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appModel.exportProfile(id: profile.id, to: url)
            errorMessage = nil
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.title = "Import Profiles"
        guard panel.runModal() == .OK else { return }
        var failures = 0
        for url in panel.urls {
            do {
                _ = try appModel.importProfile(from: url)
            } catch {
                failures += 1
            }
        }
        errorMessage = failures > 0 ? "\(failures) file(s) could not be imported (not valid profile JSON)." : nil
    }
}
