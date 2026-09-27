import AppKit
import ExportKit
import Foundation
import MyScreenArtCore
import Observation
import ProjectKit

/// Runs exports app-wide, one at a time, in the order they were started. Jobs outlive the sheet and the
/// editor window that started them.
///
/// Other areas rely only on: `isExporting`, `cancelAll()`, `waitUntilIdle()`.
@MainActor
@Observable
final class ExportCenter {
    /// One export: queued → preparing (building the composition) → encoding → finished.
    @MainActor
    @Observable
    final class Job: Identifiable {
        enum State: Equatable {
            case queued
            case preparing
            case running(ExportProgress)
            case succeeded(ExportResult)
            case failed(String)
            case cancelled

            var isActive: Bool {
                switch self {
                case .queued, .preparing, .running: true
                case .succeeded, .failed, .cancelled: false
                }
            }
        }

        let id = UUID()
        let package: RecordingPackage
        let name: String
        let destination: URL
        let settings: ExportSettings
        /// SubRip text written beside the exported file when the export succeeds.
        let subtitleSidecar: String?
        fileprivate let edit: EditConfig
        private(set) var state: State = .queued
        @ObservationIgnored fileprivate var exportJob: ExportJob?
        @ObservationIgnored fileprivate var prepareTask: Task<PreparedExport, any Error>?
        @ObservationIgnored fileprivate var cancelRequested = false

        fileprivate init(
            package: RecordingPackage, name: String, edit: EditConfig, settings: ExportSettings, destination: URL,
            subtitleSidecar: String?
        ) {
            self.subtitleSidecar = subtitleSidecar
            self.package = package
            self.name = name
            self.edit = edit
            self.settings = settings
            self.destination = destination
        }

        var isActive: Bool { state.isActive }

        /// 0…1 for the progress bar.
        var fraction: Double {
            switch state {
            case .queued, .preparing: 0
            case .running(let progress): progress.fraction
            case .succeeded: 1
            case .failed, .cancelled: 0
            }
        }

        var stageText: String {
            switch state {
            case .queued: "Waiting for other exports…"
            case .preparing: "Preparing…"
            case .running(let progress): progress.stageText
            case .succeeded: "Done"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }

        /// Cancels the job (queued or running). The partial file is deleted.
        func cancel() {
            guard isActive else { return }
            cancelRequested = true
            exportJob?.cancel()
            prepareTask?.cancel()
            if state == .queued { state = .cancelled }
        }

        fileprivate func update(_ state: State) { self.state = state }
    }

    /// Every job this session (most recent last): active ones and the last few finished ones.
    private(set) var jobs: [Job] = []

    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let dockProgress = ExportDockProgress()
    @ObservationIgnored private let notifier = ExportNotifier()
    private let exporter = VideoExporter()
    private let prepare: @Sendable (RecordingPackage, EditConfig, ExportSettings) async throws -> PreparedExport

    init(
        prepare: @escaping @Sendable (RecordingPackage, EditConfig, ExportSettings) async throws -> PreparedExport = {
            package, edit, settings in
            try await ExportPipeline.prepare(package: package, edit: edit, settings: settings)
        }
    ) {
        self.prepare = prepare
    }

    var isExporting: Bool { jobs.contains { $0.isActive } }

    var activeJobs: [Job] { jobs.filter(\.isActive) }

    /// The running or queued export of a recording, if any (so a reopened sheet shows it).
    func activeJob(for package: RecordingPackage) -> Job? {
        jobs.last { $0.isActive && $0.package == package }
    }

    /// Queues an export and returns its job. Starts it immediately when nothing else is running.
    @discardableResult
    func start(
        package: RecordingPackage, name: String, edit: EditConfig, settings: ExportSettings, destination: URL,
        subtitleSidecar: String? = nil
    ) -> Job {
        let job = Job(
            package: package, name: name, edit: edit, settings: settings, destination: destination,
            subtitleSidecar: subtitleSidecar)
        jobs.append(job)
        trimFinishedJobs()
        notifier.prepare()
        Log.app.info("Export queued: \(destination.lastPathComponent, privacy: .public)")
        if runner == nil {
            runner = Task { [weak self] in await self?.drainQueue() }
        }
        return job
    }

    func cancelAll() {
        for job in jobs where job.isActive { job.cancel() }
    }

    /// Returns when no export is running or queued.
    func waitUntilIdle() async {
        guard isExporting else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: running

    private func drainQueue() async {
        while let job = jobs.first(where: { $0.state == .queued }) {
            await run(job)
        }
        runner = nil
        dockProgress.clear()
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func run(_ job: Job) async {
        job.update(.preparing)
        dockProgress.show(fraction: 0)
        let prepared: PreparedExport
        do {
            let task = Task {
                try await prepare(job.package, job.edit, job.settings)
            }
            job.prepareTask = task
            if job.cancelRequested { task.cancel() }
            prepared = try await task.value
        } catch {
            job.prepareTask = nil
            finish(job, with: job.cancelRequested ? .cancelled : .failed(error.localizedDescription))
            return
        }
        job.prepareTask = nil
        if job.cancelRequested {
            finish(job, with: .cancelled)
            return
        }

        let exportJob = exporter.start(
            asset: prepared.asset, videoComposition: prepared.videoComposition, audioMix: prepared.audioMix,
            to: job.destination, settings: prepared.settings)
        job.exportJob = exportJob
        job.update(.running(exportJob.latestProgress))

        var lastDockPercent = -1
        for await progress in exportJob.progress {
            job.update(.running(progress))
            let percent = Int(progress.fraction * 100)
            if percent != lastDockPercent {
                lastDockPercent = percent
                dockProgress.show(fraction: progress.fraction)
            }
        }
        do {
            let result = try await exportJob.result
            finish(job, with: .succeeded(result))
        } catch {
            if case .cancelled = error {
                finish(job, with: .cancelled)
            } else {
                finish(job, with: .failed(error.localizedDescription))
            }
        }
    }

    private func finish(_ job: Job, with state: Job.State) {
        job.update(state)
        job.exportJob = nil
        switch state {
        case .succeeded(let result):
            if let srt = job.subtitleSidecar {
                let url = result.url.deletingPathExtension().appendingPathExtension("srt")
                do {
                    try Data(srt.utf8).write(to: url, options: .atomic)
                } catch {
                    Log.app.error("Couldn't write subtitles: \(error.localizedDescription, privacy: .public)")
                }
            }
            Log.app.info(
                "Export finished: \(result.url.lastPathComponent, privacy: .public), \(result.fileSize) bytes in \(result.wallTime, format: .fixed(precision: 1)) s"
            )
            notifier.notifyFinished(name: job.name, url: result.url)
        case .failed(let message):
            Log.app.error("Export failed: \(message, privacy: .public)")
            notifier.notifyFailed(name: job.name, message: message)
        default:
            break
        }
    }

    private func trimFinishedJobs() {
        let finished = jobs.filter { !$0.isActive }
        guard finished.count > 10 else { return }
        let drop = Set(finished.prefix(finished.count - 10).map(\.id))
        jobs.removeAll { drop.contains($0.id) }
    }
}
