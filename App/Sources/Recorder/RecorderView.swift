import SwiftUI

/// New Recording window (skeleton).
struct RecorderView: View {
    var body: some View {
        ContentUnavailableView("New Recording", systemImage: "record.circle")
            .frame(minWidth: 720, minHeight: 480)
    }
}

/// Menu-bar extra content (skeleton).
struct RecorderMenuBarContent: View {
    var body: some View {
        Text("MyScreenArt")
    }
}
