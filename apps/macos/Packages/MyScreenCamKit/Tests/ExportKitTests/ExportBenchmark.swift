import AVFoundation
import Darwin
import Foundation
import Testing

@testable import ExportKit

/// Export speed benchmark. Off by default; run with
/// `EXPORTKIT_BENCHMARK=1 swift test --package-path Packages/MyScreenCamKit --filter ExportBenchmark`.
///
/// Exports a synthetic 1920×1080 @60, 60 s clip (with AAC audio) through a video composition, and
/// prints wall time, this process's CPU time, the CPU time of the VideoToolbox/media XPC services
/// (hardware encode and decode are driven from those, not from this process) and the peak memory
/// footprint during the export.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EXPORTKIT_BENCHMARK"] != nil))
struct ExportBenchmark {
    static let clip = ClipSpec(width: 1920, height: 1080, fps: 60, seconds: 60)

    @Test(arguments: [ExportPreset.web, .smooth, .compact, .master, .gif])
    func benchmark(preset: ExportPreset) async throws {
        let source = try await Fixtures.shared.clip(Self.clip)
        let settings = preset.settings
        let fixture = try await CompositionFixture.make(source: source, settings: settings)
        let url = try await Fixtures.shared.outputDirectory("bench-\(preset.rawValue)")
            .appendingPathComponent("out.\(settings.fileExtension)")

        let servicesBefore = ServiceCPU.sample()
        let before = ProcessCPU.now()
        let sampler = FootprintSampler()
        let result = try await VideoExporter().start(
            asset: fixture.composition, videoComposition: fixture.videoComposition,
            audioMix: fixture.audioMix, to: url, settings: settings
        ).result
        let peakFootprint = await sampler.stop()
        let after = ProcessCPU.now()
        let servicesAfter = ServiceCPU.sample()

        let processCPU = after.cpuSeconds - before.cpuSeconds
        let serviceCPU = ServiceCPU.delta(before: servicesBefore, after: servicesAfter)
        let line = String(
            format: "[ExportBenchmark] %@ %dx%d: wall %.2f s (%.1fx realtime), process CPU %.2f s, "
                + "media services CPU %.2f s, footprint %.0f MB before / %.0f MB peak / %.0f MB after, "
                + "output %.1f MB",
            preset.rawValue, Int(result.dimensions.width), Int(result.dimensions.height), result.wallTime,
            Self.clip.seconds / result.wallTime, processCPU, serviceCPU, before.footprintMegabytes,
            peakFootprint, after.footprintMegabytes, Double(result.fileSize) / 1e6)
        print(line)
        try? FileManager.default.removeItem(at: url)
    }
}

/// Samples this process's memory footprint (what Activity Monitor shows, IOSurfaces included) every
/// 20 ms and keeps the peak. A benchmark-only helper.
final class FootprintSampler: Sendable {
    private let task: Task<Double, Never>

    init() {
        task = Task.detached {
            var peak = ProcessCPU.footprintMegabytes()
            while !Task.isCancelled {
                peak = max(peak, ProcessCPU.footprintMegabytes())
                try? await Task.sleep(for: .milliseconds(20))
            }
            return max(peak, ProcessCPU.footprintMegabytes())
        }
    }

    func stop() async -> Double {
        task.cancel()
        return await task.value
    }
}

struct ProcessCPU {
    var cpuSeconds: Double
    var footprintMegabytes: Double

    static func now() -> ProcessCPU {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return ProcessCPU(
            cpuSeconds: seconds(usage.ru_utime) + seconds(usage.ru_stime),
            footprintMegabytes: footprintMegabytes())
    }

    static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Double(info.phys_footprint) / 1_048_576
    }
}

/// CPU time of the out-of-process media services (VideoToolbox encoder/decoder, media server).
enum ServiceCPU {
    static let names = ["VTEncoderXPCService", "VTDecoderXPCService", "mediaserverd"]

    static func sample() -> [pid_t: Double] {
        var result: [pid_t: Double] = [:]
        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            let processName = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard names.contains(processName) else { continue }
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard status == 0 else { continue }
            let ticks = Double(info.ri_user_time + info.ri_system_time)
            result[pid] = ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
        }
        return result
    }

    static func delta(before: [pid_t: Double], after: [pid_t: Double]) -> Double {
        after.reduce(0) { total, entry in total + entry.value - (before[entry.key] ?? 0) }
    }
}
