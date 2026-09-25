import Foundation

/// One line of `events.jsonl`. Positions are normalised to the captured content rect (0…1, y down);
/// values outside 0…1 mean the pointer was outside the captured area. `t` is session time in seconds.
public struct InputEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case move
        case down
        case up
        case scroll
    }

    public var t: Double
    public var kind: Kind
    public var x: Double
    public var y: Double
    /// 0 = left, 1 = right, 2+ = other. Set for `down`/`up`, and for `move` while a button is held (a drag).
    public var button: Int?
    /// Index into `cursors/index.json` of the cursor image showing at this moment.
    public var cursor: Int?
    /// Scroll deltas in points (for `scroll`).
    public var dx: Double?
    public var dy: Double?

    public init(
        t: Double, kind: Kind, x: Double, y: Double, button: Int? = nil, cursor: Int? = nil, dx: Double? = nil,
        dy: Double? = nil
    ) {
        self.t = t
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.cursor = cursor
        self.dx = dx
        self.dy = dy
    }

    enum CodingKeys: String, CodingKey {
        case t
        case kind = "k"
        case x
        case y
        case button = "b"
        case cursor = "c"
        case dx
        case dy
    }

    public var isLeftClick: Bool { kind == .down && button == 0 }
}

/// Reads and writes `events.jsonl` (one JSON object per line).
public enum InputEventLog {
    public static func encodeLine(_ event: InputEvent) throws -> Data {
        var data = try JSONEncoder.compact.encode(event)
        data.append(0x0A)
        return data
    }

    /// Decodes every well-formed line; a truncated last line (crash mid-write) is ignored.
    public static func decode(_ data: Data) -> [InputEvent] {
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(InputEvent.self, from: Data($0)) }
    }
}

extension JSONEncoder {
    static var compact: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.fractional.string(from: date))
        }
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: string)
                ?? ISO8601DateFormatter().date(from: string)
            {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return decoder
    }
}

extension ISO8601DateFormatter {
    /// ISO 8601 with milliseconds. A new instance per use: the formatter isn't Sendable.
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
