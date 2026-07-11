import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Profile library sheet: browse, favorite, import, export, and manage built-ins.
struct ProfileLibraryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool
    @State private var deleteCandidate: EQProfile?
    @State private var errorMessage: String?
    @State private var showingAutoEQImport = false
    @State private var showingResetAllConfirmation = false
    @State private var searchText = ""
    /// UI highlight (independent of the *active* profile) — target of the
    /// toolbar Actions menu and of scroll-to after New/Import.
    @State private var selectedID: UUID?
    @State private var scrollTarget: UUID?

    private var selectedProfile: EQProfile? {
        guard let selectedID else { return nil }
        return appModel.profileManager.profiles.first { $0.id == selectedID }
    }

    private var visibleProfiles: [EQProfile] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return appModel.profileManager.profiles }
        return appModel.profileManager.profiles.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.sourceAttribution?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var factoryProfiles: [EQProfile] {
        visibleProfiles.filter(\.isFactory)
    }

    private var userProfiles: [EQProfile] {
        visibleProfiles.filter { !$0.isFactory }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityLabel("Search profiles by name or attribution")

            ScrollViewReader { proxy in
            List(selection: $selectedID) {
                if !factoryProfiles.isEmpty {
                    Section("Built-in") {
                        ForEach(factoryProfiles) { profile in
                            row(for: profile)
                        }
                    }
                }
                if !userProfiles.isEmpty {
                    Section("Yours") {
                        ForEach(userProfiles) { profile in
                            row(for: profile)
                        }
                    }
                }
                if visibleProfiles.isEmpty {
                    Text(searchText.isEmpty ? "No profiles" : "No profiles match “\(searchText)”")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .listStyle(.inset)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Text("Click a profile to activate. Built-ins can be reset but not deleted.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(minWidth: 540, minHeight: 500)
        .sheet(isPresented: $showingAutoEQImport) {
            AutoEQImportView()
        }
        .confirmationDialog(
            "Reset all built-in presets?",
            isPresented: $showingResetAllConfirmation
        ) {
            Button("Reset All Built-ins", role: .destructive) {
                appModel.resetAllFactoryPresets()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores the \(EQProfile.factoryPresets.count) factory EQ presets to their shipped defaults. Your custom profiles are not affected.")
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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Profiles")
                .font(.headline)
            Spacer()
            Button("New") {
                let created = appModel.profileManager.create()
                selectedID = created.id
                scrollTarget = created.id
                beginRename(created)
            }
            actionsMenu
            Menu {
                Button("Import Profile…") { runImportPanel() }
                Button("Import AutoEQ…") { showingAutoEQImport = true }
                Divider()
                Button("Reset Built-ins…") { showingResetAllConfirmation = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Import profiles or reset built-in presets")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Toolbar twin of the row context menu, operating on the highlighted
    /// profile — discoverable for users who don't think to right-click.
    private var actionsMenu: some View {
        Menu {
            if let profile = selectedProfile {
                let isActive = profile.id == appModel.profileManager.activeProfileID
                Button("Activate") { appModel.selectProfile(id: profile.id) }
                    .disabled(isActive)
                Button(profile.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    appModel.profileManager.toggleFavorite(profile.id)
                }
                if profile.isFactory {
                    Button("Reset to Default") { appModel.resetFactoryPreset(id: profile.id) }
                        .disabled(!appModel.profileManager.isFactoryModified(profile.id))
                }
                Button("Rename") { beginRename(profile) }
                    .disabled(profile.isFactory)
                Button("Duplicate") { _ = appModel.profileManager.duplicate(profile.id) }
                Button("Export\u{2026}") { runExportPanel(for: profile) }
                Divider()
                Button("Delete", role: .destructive) { deleteCandidate = profile }
                    .disabled(profile.isFactory)
            } else {
                Text("Select a profile first")
            }
        } label: {
            Label("Actions", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(selectedProfile == nil)
        .help(selectedProfile.map { "Actions for \u{201C}\($0.name)\u{201D}" } ?? "Select a profile to enable actions")
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for profile: EQProfile) -> some View {
        let isActive = profile.id == appModel.profileManager.activeProfileID
        let isModified = profile.isFactory && appModel.profileManager.isFactoryModified(profile.id)

        HStack(alignment: .center, spacing: 10) {
            Button {
                appModel.profileManager.toggleFavorite(profile.id)
            } label: {
                Image(systemName: profile.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(profile.isFavorite ? .yellow : .secondary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help(profile.isFavorite ? "Remove from favorites" : "Add to favorites")

            if renamingID == profile.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(profile) }
                    .onExitCommand { renamingID = nil }
                    // Grab keyboard focus as soon as the field exists so the
                    // user can type immediately (focus also selects all text).
                    .onAppear { renameFieldFocused = true }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .fontWeight(isActive ? .semibold : .regular)
                            .lineLimit(1)
                        statusIcons(for: profile, isActive: isActive, isModified: isModified)
                    }
                    if let attribution = profile.sourceAttribution {
                        Text(attribution)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .tag(profile.id)
        .listRowBackground(isActive ? Color.accentColor.opacity(0.08) : nil)
        .onTapGesture {
            guard renamingID == nil else { return }
            selectedID = profile.id
            if !isActive {
                appModel.selectProfile(id: profile.id)
            }
        }
        .contextMenu {
            Button("Activate") { appModel.selectProfile(id: profile.id) }
                .disabled(isActive)
            if profile.isFactory {
                Button("Reset to Default") {
                    appModel.resetFactoryPreset(id: profile.id)
                }
                .disabled(!isModified)
            }
            Button("Rename") { beginRename(profile) }
                .disabled(profile.isFactory)
            Button("Duplicate") { _ = appModel.profileManager.duplicate(profile.id) }
            Button("Export…") { runExportPanel(for: profile) }
            Divider()
            Button("Delete", role: .destructive) { deleteCandidate = profile }
                .disabled(profile.isFactory)
        }
    }

    @ViewBuilder
    private func statusIcons(for profile: EQProfile, isActive: Bool, isModified: Bool) -> some View {
        HStack(spacing: 4) {
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .imageScale(.small)
                    .help("Active")
            }
            if profile.isFactory {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                    .help("Built-in preset")
            }
            if isModified {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                    .help("Modified from default — reset to restore")
            }
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
                let imported = try appModel.importProfile(from: url)
                selectedID = imported.id
                scrollTarget = imported.id
            } catch {
                failures += 1
            }
        }
        errorMessage = failures > 0 ? "\(failures) file(s) could not be imported (not valid profile JSON)." : nil
    }
}
