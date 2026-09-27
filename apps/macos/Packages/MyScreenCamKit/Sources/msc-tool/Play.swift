// `msc-tool play`: headless editor-playback benchmark.
//
// Builds the same player the editor does (`ProjectRenderer` with `.preview(maxSize:)`, an `AVPlayer` over its
// player item), attaches an `AVPlayerItemVideoOutput`, pulls composed frames at display rate, plays for N seconds
// and prints this process's CPU time and memory footprint.

import AVFoundation
import Darwin
import Foundation
import ProjectKit
import QuartzCore
import RenderKit

/// This process's `phys_footprint` in bytes (what Activity Monitor calls "Memory").
func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Frame counter and footprint statistics, touched only on the main queue.
@MainActor
final class PlayStats {
    var frames = 0
    var peak: UInt64 = 0
    var footprintSum = 0.0
    var footprintSamples = 0

    func sampleFootprint() {
        let f = physFootprint()
        peak = max(peak, f)
        footprintSum += Double(f)
        footprintSamples += 1
    }
}

@MainActor
func runPlay(package: RecordingPackage, args: [String]) async throws {
    let seconds = Double(option("--seconds", in: args) ?? "20") ?? 20
    let parts = (option("--size", in: args) ?? "2368x1152").split(separator: "x").compactMap { Double($0) }
    let size = parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : CGSize(width: 2368, height: 1152)
    let displayRate = Double(option("--display-fps", in: args) ?? "60") ?? 60
    let project = try RenderProject.load(package)
    let fps = Int(option("--fps", in: args) ?? "") ?? min(60, max(24, project.meta.screen.frameRate))
    let renderer = try await ProjectRenderer(
        project: project, options: .preview(maxSize: size, frameRate: fps), metering: args.contains("--meter"))
    let item = renderer.makePlayerItem()
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.actionAtItemEnd = .pause
    player.isMuted = args.contains("--mute")
    print(
        "Playing \(Int(renderer.layout.canvasSize.width))×\(Int(renderer.layout.canvasSize.height)) @\(fps) fps "
            + "for \(seconds) s (display \(Int(displayRate)) Hz)")

    while item.status == .unknown { try await Task.sleep(for: .milliseconds(20)) }
    guard item.status == .readyToPlay else {
        throw ToolError.usage("player item failed: \(String(describing: item.error))")
    }

    let stats = PlayStats()
    let cpuStart = cpuSeconds()
    let wallStart = CACurrentMediaTime()
    player.play()

    let pull = DispatchSource.makeTimerSource(queue: .main)
    pull.schedule(deadline: .now(), repeating: 1 / displayRate, leeway: .milliseconds(1))
    pull.setEventHandler {
        MainActor.assumeIsolated {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time),
                output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil
            {
                stats.frames += 1
            }
        }
    }
    pull.resume()
    let meter = DispatchSource.makeTimerSource(queue: .main)
    meter.schedule(deadline: .now() + 0.5, repeating: 0.25)
    meter.setEventHandler { MainActor.assumeIsolated { stats.sampleFootprint() } }
    meter.resume()

    let end = min(seconds, renderer.timeline.duration)
    while CACurrentMediaTime() - wallStart < end, player.rate != 0 || CACurrentMediaTime() - wallStart < 1 {
        try await Task.sleep(for: .milliseconds(100))
    }
    pull.cancel()
    meter.cancel()
    let wall = CACurrentMediaTime() - wallStart
    let cpu = cpuSeconds() - cpuStart
    let played = player.currentTime().seconds
    player.pause()
    let mb = 1_048_576.0
    let average = stats.footprintSamples > 0 ? stats.footprintSum / Double(stats.footprintSamples) / mb : 0
    print(
        String(
            format:
                "play wall: %.1f s, media: %.1f s, frames pulled: %d (%.1f fps), CPU: %.2f s = %.1f%% of a core, "
                + "footprint avg %.0f MB / peak %.0f MB",
            wall, played, stats.frames, Double(stats.frames) / wall, cpu, 100 * cpu / wall, average,
            Double(stats.peak) / mb))
    print(
        "audio meter updates: system \(renderer.audioLevels.updateCount(for: .systemAudio)), "
            + "mic \(renderer.audioLevels.updateCount(for: .microphone))")
}
