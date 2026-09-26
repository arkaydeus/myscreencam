import ProjectKit
import SwiftUI

/// Presets menu, Back to Library, click-to-rename title with the creation date, Delete and Export.
struct EditorHeader: View {
    let model: EditorModel
    /// Closes the window after the recording was moved to the Trash.
    let onDeleted: () -> Void

    @Environment(AppModel.self) private var app
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var confirmDelete = false
    @State private var showSavePreset = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                app.router.showLibrary()
            } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .help("Back to Library")

            PresetsMenu(model: model, showSavePreset: $showSavePreset)
                .fixedSize()

            Divider().frame(height: 20)

            title

            Spacer(minLength: 12)

            if let saveError = model.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .font(.callout)
            }

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Move this recording to the Trash")

            Button {
                model.pause()
                model.showExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .help("Export… (⌘E)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .confirmationDialog(
            "Move “\(model.meta.name)” to the Trash?", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    if let message = await model.deleteRecording() {
                        errorMessage = message
                    } else {
                        onDeleted()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can restore it from the Trash in Finder.")
        }
        .sheet(isPresented: $showSavePreset) {
            PresetNameSheet(model: model)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder private var title: some View {
        VStack(alignment: .leading, spacing: 1) {
            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .frame(maxWidth: 360)
                    .focused($nameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { isRenaming = false }
                    .onChange(of: nameFieldFocused) { _, focused in
                        // Clicking elsewhere cancels, like Esc.
                        if !focused { isRenaming = false }
                    }
            } else {
                Text(model.meta.name)
                    .font(.headline)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { beginRename() }
                    .help("Click to rename")
            }
            Text(model.meta.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func beginRename() {
        draftName = model.meta.name
        isRenaming = true
        nameFieldFocused = true
    }

    private func commitRename() {
        let name = draftName
        isRenaming = false
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != model.meta.name else { return }
        Task {
            if let message = await model.rename(to: name) { errorMessage = message }
        }
    }
}

/// Presets: apply, save current, delete.
struct PresetsMenu: View {
    let model: EditorModel
    @Binding var showSavePreset: Bool

    var body: some View {
        Menu {
            if model.presets.isEmpty {
                Text("No Presets")
            } else {
                Section("Apply") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.applyPreset(preset) }
                    }
                }
            }
            Divider()
            Button("Save Current as Preset…") { showSavePreset = true }
            if !model.presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(model.presets) { preset in
                        Button(preset.name, role: .destructive) { model.deletePreset(preset) }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "slider.horizontal.3")
        }
        .help("Presets save webcam, audio, cursor, zoom defaults and background settings")
    }
}

/// Name entry for "Save Current as Preset…".
struct PresetNameSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Current as Preset")
                .font(.headline)
            Text(
                "Saves the webcam, audio, cursor, zoom defaults and background. A preset with the same name is replaced."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            error = await model.saveCurrentAsPreset(named: name)
            saving = false
            if error == nil { dismiss() }
        }
    }
}
