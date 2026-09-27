import Foundation

/// A scratch directory mirroring a verified model snapshot with symlinks. SDK loaders that derive files at load
/// time (MLX Audio Swift writes `tokenizer.json` next to the weights) write them here, so the checksum-verified
/// snapshot is never modified. Deleting it only costs a re-derivation.
enum RuntimeDirectory {
    static func prepare(mirroring snapshot: URL, at runtime: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        for relative in try fm.subpathsOfDirectory(atPath: snapshot.path) {
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            let file = snapshot.appending(path: relative)
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let link = runtime.appending(path: relative)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == file.path { continue }
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: file)
        }
        return runtime
    }
}
