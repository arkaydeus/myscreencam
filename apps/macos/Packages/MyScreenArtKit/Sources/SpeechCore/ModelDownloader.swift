import Foundation

/// Downloads one file with `URLSession`, reporting cumulative bytes, and resuming from saved resume data.
///
/// On cancellation the session's resume data is written to `resumeDataURL`, so the next attempt continues where
/// this one stopped. `URLSession` only resumes when the server's validator (ETag/Last-Modified via `If-Range`)
/// still matches; otherwise it starts again from zero. Either way the caller verifies size and SHA-256, so a bad
/// resume can't be installed.
public final class ModelDownloader: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(
        _ url: URL, to destination: URL, expectedSize: Int64, resumeDataURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let delegate = ProgressDelegate(progress: progress)
        let resumeData = try? Data(contentsOf: resumeDataURL)
        try? FileManager.default.removeItem(at: resumeDataURL)
        let temporary: URL
        let response: URLResponse
        do {
            if let resumeData {
                do {
                    (temporary, response) = try await session.download(resumeFrom: resumeData, delegate: delegate)
                } catch let error as URLError where error.code != .cancelled {
                    // Stale or incompatible resume data: start over.
                    (temporary, response) = try await session.download(from: url, delegate: delegate)
                }
            } else {
                (temporary, response) = try await session.download(from: url, delegate: delegate)
            }
        } catch let error as URLError {
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeDataURL, options: .atomic)
            }
            if error.code == .cancelled { throw error }
            throw ModelStoreError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw ModelStoreError.network("The server returned HTTP \(http.statusCode) for \(url.lastPathComponent).")
        }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard size == expectedSize else {
            try? FileManager.default.removeItem(at: temporary)
            throw ModelStoreError.sizeMismatch(destination.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(size)
    }
}

/// Forwards `didWriteData` (throttled to ~10 Hz) to the progress closure.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var lastReport: TimeInterval = 0

    init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let due = now - lastReport >= 0.1
        if due { lastReport = now }
        lock.unlock()
        if due { progress(totalBytesWritten) }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        progress(fileOffset)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The async API hands the file back; nothing to do here.
    }
}
