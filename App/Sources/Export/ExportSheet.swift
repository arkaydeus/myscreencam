import ProjectKit
import SwiftUI

/// Export options + progress sheet, presented by the editor (skeleton).
struct ExportSheet: View {
    let package: RecordingPackage
    let edit: EditConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("Export")
            Button("Close") { dismiss() }
        }
        .padding()
    }
}
