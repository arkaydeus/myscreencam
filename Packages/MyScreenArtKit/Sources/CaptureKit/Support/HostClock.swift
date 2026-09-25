import CoreMedia
import Darwin

/// The host time clock (`CMClockGetHostTimeClock`, i.e. `mach_absolute_time`) expressed in seconds.
///
/// Every capture timestamp in MyScreenArt lives on this clock: ScreenCaptureKit sample buffers already do,
/// camera buffers are converted from the capture session's synchronisation clock, and event-tap timestamps
/// are converted from their raw units with ``EventTimestampConverter``.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Now, in host seconds.
    public static func now() -> Double { seconds(machTicks: mach_absolute_time()) }

    /// Converts `mach_absolute_time` ticks to seconds. On Apple silicon one tick is 125/3 ns.
    public static func seconds(machTicks: UInt64) -> Double {
        let info = timebase
        return Double(machTicks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    /// Converts a host-clock `CMTime` to seconds.
    public static func seconds(_ time: CMTime) -> Double { time.seconds }

    /// A `CMTime` on the host clock for the given seconds (nanosecond timescale).
    public static func time(seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * 1_000_000_000).rounded()), timescale: 1_000_000_000)
    }
}

/// Converts `CGEvent.timestamp` values to host seconds.
///
/// `CGEventTimestamp` is documented as nanoseconds since startup, but it is filled from `mach_absolute_time`,
/// whose ticks are 125/3 ns on Apple silicon (they only equal nanoseconds on Intel). Picking the wrong unit would
/// run the event clock ~42× off. Rather than hard-code either, the converter calibrates on the first real event:
/// it compares the raw value against "now" in both units and locks in whichever is closer. The candidates differ
/// by a factor of ~42 and an event reaches the tap within milliseconds, so the choice is unambiguous.
public struct EventTimestampConverter: Sendable, Equatable {
    public enum Unit: Sendable, Equatable {
        case machTicks
        case nanoseconds
    }

    public private(set) var unit: Unit?

    public init(unit: Unit? = nil) {
        self.unit = unit
    }

    /// Host seconds for a raw event timestamp. A zero timestamp (synthesised events) maps to `now`.
    public mutating func hostSeconds(eventTimestamp raw: UInt64, nowTicks: UInt64 = mach_absolute_time()) -> Double {
        let now = HostClock.seconds(machTicks: nowTicks)
        guard raw != 0 else { return now }
        let asTicks = HostClock.seconds(machTicks: raw)
        let asNanos = Double(raw) / 1_000_000_000
        let resolved =
            unit
            ?? (abs(now - asTicks) <= abs(now - asNanos) ? Unit.machTicks : Unit.nanoseconds)
        unit = resolved
        return resolved == .machTicks ? asTicks : asNanos
    }
}
