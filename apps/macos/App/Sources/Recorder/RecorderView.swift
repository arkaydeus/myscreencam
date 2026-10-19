import CaptureKit
import RecordingKit
import SwiftUI

/// The New Recording window: source (display / window / region) with a still preview, camera with a live
/// preview, microphone with a level meter, options, permissions, warnings and the Start button.
struct RecorderView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: RecorderWindowModel?

    var body: some View {
        Group {
            if let model {
                RecorderContent(model: model)
            } else {
                Color.clear.frame(width: 760, height: 560)
            }
        }
        .groupBoxStyle(.themed)
        .toggleStyle(.switch)
        .themedWindow()
        .onAppear {
            if model == nil { model = RecorderWindowModel(controller: appModel.recording) }
        }
    }
}

private struct RecorderContent: View {
    let model: RecorderWindowModel
    @Environment(\.dismissWindow) private var dismissWindow

    private var controller: RecordingController { model.controller }
    private var preferences: RecorderPreferences { model.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                GroupBox {
                    SourceSection(model: model)
                } label: {
                    Label("Source", systemImage: "display")
                }
                .frame(width: 400)
                VStack(alignment: .leading, spacing: 12) {
                    CameraSection(model: model)
                    MicrophoneSection(model: model)
                    OptionsSection(model: model)
                }
                .frame(width: 300)
            }
            WarningsView(model: model)
            if !model.missingPermissions.isEmpty {
                PermissionsCard(model: model)
            }
            StartButton(model: model)
        }
        .padding(20)
        .fixedSize()
        .background(WindowVisibilityReader { visible in visible ? model.activate() : model.deactivate() })
        .onAppear {
            model.activate()
            applySourceRequest()
        }
        .onDisappear { model.deactivate() }
        .onChange(of: controller.router.recorderSourceRequest) { applySourceRequest() }
        .onChange(of: controller.state) { _, state in stateChanged(state) }
    }

    private func applySourceRequest() {
        model.selectSourceKind(controller.router.recorderSourceRequest)
    }

    private func stateChanged(_ state: RecordingController.State) {
        switch state {
        case .idle:
            model.resumeLiveInputs()
        case .countingDown(let remaining):
            if remaining == 0 { model.suspendLiveInputs() }
        case .recording:
            model.suspendLiveInputs()
            // The HUD and the menu bar take over while recording.
            dismissWindow(id: AppRouter.SceneID.recorder)
        case .stopping:
            break
        }
    }
}

// MARK: - Source

private struct SourceSection: View {
    let model: RecorderWindowModel
    private var preferences: RecorderPreferences { model.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(
                "Source",
                selection: Binding(get: { preferences.sourceKind }, set: { model.selectSourceKind($0) })
            ) {
                ForEach(RecorderSourceKind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch preferences.sourceKind {
                case .display: displayPicker
                case .window: WindowList(model: model)
                case .region: regionPicker
                }
            }
            .frame(minHeight: 28, alignment: .top)

            SourcePreview(model: model)

            if SystemContentPicker.isSupported, model.isGranted(.screenRecording) {
                Button("Choose with System Picker…", systemImage: "rectangle.on.rectangle") {
                    model.chooseWithSystemPicker()
                }
                .buttonStyle(.link)
            }
        }
    }

    private var displayPicker: some View {
        Picker(
            "Display",
            selection: Binding(
                get: { preferences.displayID ?? model.displays.first?.id ?? 0 },
                set: { model.selectDisplay($0) })
        ) {
            ForEach(model.displays) { display in
                Text(display.pickerTitle).tag(display.id)
            }
        }
    }

    private var regionPicker: some View {
        HStack {
            Button("Select Region…", systemImage: "rectangle.dashed") { model.selectRegion() }
                .buttonStyle(.themed)
                .fixedSize()
            if let region = preferences.region {
                let name = model.displays.first { $0.id == region.displayID }?.name ?? "a disconnected display"
                let rect = region.rect
                Text(
                    verbatim:
                        "\(Int(rect.width)) × \(Int(rect.height)) at (\(Int(rect.minX)), \(Int(rect.minY))) on \(name)"
                )
                .font(.callout)
                .foregroundStyle(Color.themeSecondaryText)
                .lineLimit(2)
            } else {
                Text("No region selected").foregroundStyle(Color.themeSecondaryText)
            }
        }
    }
}

private struct WindowList: View {
    let model: RecorderWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.selectedWindow?.pickerTitle ?? "Choose a window")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.selectedWindow == nil ? Color.themeSecondaryText : Color.themePrimaryText)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshWindows() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.themedIcon)
                    .help("Refresh the window list")
                    .disabled(!model.isGranted(.screenRecording))
            }
            if !model.isGranted(.screenRecording) {
                Text("Allow Screen Recording to list windows.")
                    .font(.callout)
                    .foregroundStyle(Color.themeSecondaryText)
            } else if let error = model.windowsError {
                Text(error).font(.callout).foregroundStyle(Color.themeDestructive)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.windows) { window in
                            WindowRow(
                                window: window, thumbnail: model.windowThumbnails[window.id],
                                isSelected: window.id == model.preferences.windowID
                            ) { model.selectWindow(window.id) }
                            .onAppear { model.requestThumbnail(for: window.id) }
                        }
                    }
                }
                .frame(height: 150)
                .themePanel(.themeStage, cornerRadius: AppTheme.controlRadius + 2)
                .overlay {
                    if model.windowsLoaded, model.windows.isEmpty {
                        Text("No windows").foregroundStyle(Color.themeSecondaryText)
                    } else if !model.windowsLoaded {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct WindowRow: View {
    let window: WindowInfo
    let thumbnail: NSImage?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "macwindow").foregroundStyle(Color.themeTertiaryText)
                    }
                }
                .frame(width: 56, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.appName ?? window.title).lineLimit(1)
                    Text("\(window.title) · \(window.sizeDescription)")
                        .font(.caption)
                        .foregroundStyle(Color.themeSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.themeAccent.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.themeAccent.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SourcePreview: View {
    let model: RecorderWindowModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.controlRadius + 2, style: .continuous).fill(Color.themeStage)
            RoundedRectangle(cornerRadius: AppTheme.controlRadius + 2, style: .continuous)
                .strokeBorder(Color.themePanelBorder)
            if let image = model.sourcePreview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            } else if model.sourcePreviewLoading {
                ProgressView().controlSize(.small)
            } else {
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(Color.themeSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .frame(height: 210)
        .overlay(alignment: .topTrailing) {
            if model.isGranted(.screenRecording), model.preferences.selectedSource != nil {
                Button("Refresh Preview", systemImage: "arrow.clockwise") { model.refreshSourcePreview() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.themedIcon)
                    .padding(4)
                    .help("Take a new preview")
            }
        }
        .accessibilityLabel("Source preview")
    }

    private var placeholder: String {
        if !model.isGranted(.screenRecording) { return "Allow Screen Recording to see a preview." }
        if let error = model.sourcePreviewError { return error }
        return "No preview"
    }
}

// MARK: - Camera and microphone

private struct CameraSection: View {
    let model: RecorderWindowModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                switch model.status(.camera) {
                case .granted:
                    Picker(
                        "Camera",
                        selection: Binding(get: { model.selectedCamera?.id }, set: { model.selectCamera($0) })
                    ) {
                        Text("None").tag(String?.none)
                        ForEach(model.cameras) { camera in Text(camera.name).tag(Optional(camera.id)) }
                    }
                    .labelsHidden()
                    if let selected = model.selectedCamera {
                        preview(for: selected)
                    }
                case .notDetermined:
                    Button("Grant Camera Access…") { Task { await model.request(.camera) } }
                        .buttonStyle(.themed)
                case .denied, .restricted:
                    Button("Allow Camera in System Settings…") { model.openSettings(.camera) }
                        .buttonStyle(.themed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Camera", systemImage: "video")
        }
    }

    @ViewBuilder
    private func preview(for device: CameraDevice) -> some View {
        let hub = model.controller.cameraHub
        ZStack {
            if let camera = hub.camera, camera.configuration.deviceID == device.id {
                CameraPreviewView(camera: camera)
            } else if let failure = hub.failure {
                Text(failure).font(.caption).foregroundStyle(Color.themeSecondaryText).padding()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .background(Color.themeStage)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.controlRadius + 2, style: .continuous))
        .accessibilityLabel("Camera preview")
    }
}

private struct MicrophoneSection: View {
    let model: RecorderWindowModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                switch model.status(.microphone) {
                case .granted:
                    Picker(
                        "Microphone",
                        selection: Binding(
                            get: { model.selectedMicrophone?.id }, set: { model.selectMicrophone($0) })
                    ) {
                        Text("None").tag(String?.none)
                        ForEach(model.microphones) { mic in
                            Text(mic.isDefault ? "\(mic.name) (Default)" : mic.name).tag(Optional(mic.id))
                        }
                    }
                    .labelsHidden()
                    if model.selectedMicrophone != nil {
                        MicLevelMeterView(sink: model.meterSink)
                            .frame(height: 6)
                            .accessibilityLabel("Microphone level")
                        if let error = model.micMeterError {
                            Text(error).font(.caption).foregroundStyle(Color.themeSecondaryText)
                        }
                    }
                case .notDetermined:
                    Button("Grant Microphone Access…") { Task { await model.request(.microphone) } }
                        .buttonStyle(.themed)
                case .denied, .restricted:
                    Button("Allow Microphone in System Settings…") { model.openSettings(.microphone) }
                        .buttonStyle(.themed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Microphone", systemImage: "mic")
        }
    }
}

private struct OptionsSection: View {
    let model: RecorderWindowModel
    @State private var showsAdvanced = false

    var body: some View {
        @Bindable var preferences = model.preferences
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("System Audio", isOn: $preferences.captureSystemAudio)
                Toggle("Custom Cursor", isOn: $preferences.customCursor)
                Text(
                    model.isGranted(.inputMonitoring)
                        ? "Hides the system cursor; the editor draws a smooth one from the recorded pointer."
                        : "Needs Input Monitoring. Without it the system cursor is recorded as is."
                )
                .font(.caption)
                .foregroundStyle(Color.themeSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Frame rate", selection: $preferences.frameRate) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }
                        .pickerStyle(.segmented)
                        Picker("Codec", selection: $preferences.codec) {
                            ForEach(VideoCodec.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    // On macOS only the chevron toggles a DisclosureGroup; make the title toggle it too.
                    Text("Advanced")
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { showsAdvanced.toggle() } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
    }
}

// MARK: - Warnings and Start

private struct WarningsView: View {
    let model: RecorderWindowModel

    var body: some View {
        let warnings = messages
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.themeWarning)
                        .font(.callout)
                }
            }
        }
    }

    private var messages: [String] {
        var messages: [String] = []
        if let name = model.disconnectedCamera {
            messages.append("\(name) is disconnected. The recording won't include a camera.")
        }
        if let name = model.disconnectedMicrophone {
            messages.append("\(name) is disconnected. The recording won't include a microphone.")
        }
        if model.selectedCamera != nil, model.selectedMicrophone == nil, model.disconnectedMicrophone == nil {
            messages.append("Camera without a microphone: the recording will have no voice.")
        }
        return messages
    }
}

private struct StartButton: View {
    let model: RecorderWindowModel
    private var controller: RecordingController { model.controller }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Label(title, systemImage: isCountingDown ? "xmark" : "record.circle.fill")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
            // A countdown shows Cancel, so it isn't drawn as the red record action.
            .buttonStyle(ThemeButtonStyle(kind: isCountingDown ? .standard : .record, isLarge: true))
            .keyboardShortcut(.defaultAction)
            .disabled(isDisabled)
            if controller.state == .idle, let blocker = model.startBlocker {
                Text(blocker).font(.callout).foregroundStyle(Color.themeSecondaryText)
            }
        }
    }

    private var isCountingDown: Bool {
        if case .countingDown = controller.state { return true }
        return false
    }

    private var title: String {
        switch controller.state {
        case .idle: "Start Recording"
        case .countingDown(let remaining) where remaining > 0: "Cancel · Recording in \(remaining)"
        case .countingDown: "Starting…"
        case .recording: "Recording…"
        case .stopping: "Saving…"
        }
    }

    private var isDisabled: Bool {
        switch controller.state {
        case .idle: model.startBlocker != nil
        case .countingDown(let remaining): remaining == 0
        case .recording, .stopping: true
        }
    }

    private func action() {
        switch controller.state {
        case .idle: model.startRecording()
        case .countingDown: controller.cancelCountdown()
        case .recording, .stopping: break
        }
    }
}

// MARK: - Window visibility

/// Reports when the hosting window becomes hidden or visible again after appearing (minimised, covered, on
/// another Space), so the camera preview and mic meter only run while someone can see them.
private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: (any NSObjectProtocol)?
        private var lastVisible: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
            report()
        }

        private func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible)
            guard let lastVisible else {
                // Appearing is handled by `onAppear`; only later changes are reported.
                self.lastVisible = visible
                return
            }
            guard visible != lastVisible else { return }
            self.lastVisible = visible
            // Out of the view update that triggered it.
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }
    }
}
