import SwiftUI

/// Editor window for one recording package (skeleton).
struct EditorWindow: View {
    let packageURL: URL?

    var body: some View {
        ContentUnavailableView("Editor", systemImage: "film", description: Text(packageURL?.lastPathComponent ?? ""))
            .frame(minWidth: 900, minHeight: 600)
    }
}
