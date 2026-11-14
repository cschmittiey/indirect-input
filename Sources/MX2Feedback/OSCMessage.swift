import Foundation

/// A single OSC 1.0 message: an address pattern plus typed arguments.
///
/// Only the argument types Syndicate's feedback uses are modelled (`i`, `f`, `s`),
/// plus the OSC 1.0 boolean tags `T`/`F` which are decoded as integers. Any other
/// type tag makes the whole message unparseable rather than partially decoded, so a
/// reader can never silently mismatch an argument with the wrong payload.
public struct OSCMessage: Equatable, Sendable {
    public enum Argument: Equatable, Sendable {
        case int(Int32)
        case float(Float)
        case string(String)
    }

    public let address: String
    public let arguments: [Argument]

    public init(address: String, arguments: [Argument] = []) {
        self.address = address
        self.arguments = arguments
    }

    // MARK: - Typed accessors

    public func int(_ index: Int) -> Int? {
        guard case let .int(value)? = arguments[safe: index] else { return nil }
        return Int(value)
    }

    public func float(_ index: Int) -> Float? {
        guard case let .float(value)? = arguments[safe: index] else { return nil }
        return value
    }

    public func string(_ index: Int) -> String? {
        guard case let .string(value)? = arguments[safe: index] else { return nil }
        return value
    }

    /// Numeric value from either an `int` or `float` argument.
    public func number(_ index: Int) -> Double? {
        switch arguments[safe: index] {
        case let .int(value)?: return Double(value)
        case let .float(value)?: return Double(value)
        default: return nil
        }
    }

    /// Truthiness for Syndicate's 0/1 integer flags. A float is true when nonzero.
    public func flag(_ index: Int) -> Bool? {
        switch arguments[safe: index] {
        case let .int(value)?: return value != 0
        case let .float(value)?: return value != 0
        case let .string(value)?: return value != "0" && !value.isEmpty
        default: return nil
        }
    }

    // MARK: - Parsing

    /// Parses one message. Returns `nil` for anything malformed, truncated or
    /// carrying an unsupported type tag.
    public static func parse(_ data: Data) -> OSCMessage? {
        var reader = Reader(bytes: Array(data))
        return parseMessage(&reader)
    }

    /// Parses a bare message or an OSC bundle (including nested bundles).
    /// Malformed elements are dropped; a garbage packet yields an empty array.
    public static func parseAll(_ data: Data) -> [OSCMessage] {
        var reader = Reader(bytes: Array(data))
        return parseElement(&reader)
    }

    static let bundleTag = "#bundle"

    private static func parseElement(_ reader: inout Reader) -> [OSCMessage] {
        let start = reader.offset
        if reader.matchesBundleTag() {
            return parseBundle(&reader)
        }
        reader.seek(start)
        if let message = parseMessage(&reader) {
            return [message]
        }
        return []
    }

    private static func parseBundle(_ reader: inout Reader) -> [OSCMessage] {
        guard reader.skipPaddedString(), reader.skip(8) else { return [] }  // tag + time tag
        var messages: [OSCMessage] = []
        while reader.remaining >= 4 {
            guard let size = reader.readInt32(), size > 0 else { break }
            let start = reader.offset
            guard start + Int(size) <= reader.bytes.count else { break }
            var element = Reader(bytes: Array(reader.bytes[start..<(start + Int(size))]))
            messages += parseElement(&element)
            reader.seek(start + Int(size))
        }
        return messages
    }

    private static func parseMessage(_ reader: inout Reader) -> OSCMessage? {
        guard let address = reader.readPaddedString(), address.hasPrefix("/") else { return nil }
        guard let tags = reader.readPaddedString(), tags.hasPrefix(",") else { return nil }

        var arguments: [Argument] = []
        arguments.reserveCapacity(tags.count)
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard let value = reader.readInt32() else { return nil }
                arguments.append(.int(value))
            case "f":
                guard let value = reader.readFloat32() else { return nil }
                arguments.append(.float(value))
            case "s":
                guard let value = reader.readPaddedString() else { return nil }
                arguments.append(.string(value))
            case "T":
                arguments.append(.int(1))
            case "F":
                arguments.append(.int(0))
            default:
                return nil  // blob, time tag, double, symbol, midi, char, colour…
            }
        }

        // Trailing NUL padding is tolerated; real trailing data means a desync.
        guard reader.remainingBytesAreZero else { return nil }
        return OSCMessage(address: address, arguments: arguments)
    }

    // MARK: - Byte reader

    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var remaining: Int { bytes.count - offset }
        var remainingBytesAreZero: Bool { bytes[offset...].allSatisfy { $0 == 0 } }

        @discardableResult
        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, offset + count <= bytes.count else { return false }
            offset += count
            return true
        }

        mutating func seek(_ position: Int) {
            offset = max(0, min(position, bytes.count))
        }

        func matchesBundleTag() -> Bool {
            guard bytes.count >= 8 else { return false }
            return Array(bytes[0..<7]) == Array(bundleTag.utf8) && bytes[7] == 0
        }

        /// Reads a NUL-terminated string and advances past its 4-byte padding.
        mutating func readPaddedString() -> String? {
            guard offset % 4 == 0, offset < bytes.count else { return nil }
            guard let terminator = bytes[offset...].firstIndex(of: 0) else { return nil }
            let value = String(decoding: bytes[offset..<terminator], as: UTF8.self)
            var next = terminator + 1
            while next % 4 != 0 { next += 1 }
            guard next <= bytes.count else { return nil }
            offset = next
            return value
        }

        /// Skips a padded string without materialising it.
        mutating func skipPaddedString() -> Bool {
            readPaddedString() != nil
        }

        mutating func readInt32() -> Int32? {
            guard remaining >= 4 else { return nil }
            let value = bytes[offset..<(offset + 4)].reduce(Int32(0)) { ($0 << 8) | Int32($1) }
            offset += 4
            return value
        }

        mutating func readFloat32() -> Float? {
            guard let raw = readInt32() else { return nil }
            return Float(bitPattern: UInt32(bitPattern: raw))
        }
    }
}

// MARK: - Small helpers

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Int {
    /// `self` when the predicate holds, else nil — keeps guard chains flat.
    func optional(where predicate: (Int) -> Bool) -> Int? {
        predicate(self) ? self : nil
    }
}
