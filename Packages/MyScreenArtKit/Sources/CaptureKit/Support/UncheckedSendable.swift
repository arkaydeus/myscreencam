/// Moves a non-`Sendable` value (e.g. a `CMSampleBuffer`) across a queue hop whose ordering the caller
/// guarantees. Capture buffers are immutable once delivered, so handing one to exactly one other queue is safe.
public struct UncheckedSendable<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }
}
