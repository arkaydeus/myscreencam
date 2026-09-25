import AppKit
import SwiftUI

/// Recording library. Phase 0 shows only the empty state; the project grid arrives in phase 2.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            switch environment.recordingsRoot {
            case .success:
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "record.circle",
                    description: Text("Recordings you make will appear here.")
                )
            case .failure(let error):
                ContentUnavailableView(
                    "Recordings Folder Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            if case .success(let root) = environment.recordingsRoot {
                ToolbarItem {
                    Button("Show Recordings Folder", systemImage: "folder") {
                        NSWorkspace.shared.open(root)
                    }
                }
            }
        }
    }
}
