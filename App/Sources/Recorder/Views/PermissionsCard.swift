import CaptureKit
import SwiftUI

/// Status of the four privacy permissions, with "Grant…" (system prompt) and "Open Settings" actions.
/// Statuses are re-checked when the app becomes active (see `RecorderWindowModel`).
struct PermissionsCard: View {
    let model: RecorderWindowModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, status: model.status(kind), model: model)
                }
                if model.relaunchHint {
                    Text("macOS applies Screen Recording and Input Monitoring after MyScreenArt is reopened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("Permissions", systemImage: "lock.shield")
        }
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let model: RecorderWindowModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(status.isGranted ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !status.isGranted {
                if canRequest {
                    Button("Grant…") { Task { await model.request(kind) } }
                }
                Button("Open Settings") { model.openSettings(kind) }
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }

    /// Camera and microphone can only prompt once; the Core Graphics requests (screen, input) add the app to
    /// the Settings list, so they stay available.
    private var canRequest: Bool {
        switch kind {
        case .camera, .microphone: status == .notDetermined
        case .screenRecording, .inputMonitoring: status != .restricted
        }
    }

    private var detail: String {
        switch status {
        case .granted: "Allowed"
        case .notDetermined: kind.explanation
        case .denied: kind.explanation
        case .restricted: "Blocked by a configuration profile."
        }
    }
}
