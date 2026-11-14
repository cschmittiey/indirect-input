import Foundation
@testable import MX2Feedback

// MARK: - OSC wire helpers (test-only)

/// Pads a string with at least one null terminator out to a 4-byte boundary.
func oscPadded(_ string: String) -> [UInt8] {
    var bytes = Array(string.utf8)
    bytes.append(0)
    while bytes.count % 4 != 0 { bytes.append(0) }
    return bytes
}

func oscInt32Bytes(_ value: Int32) -> [UInt8] {
    let big = value.bigEndian
    return withUnsafeBytes(of: big) { Array($0) }
}

func oscFloat32Bytes(_ value: Float) -> [UInt8] {
    let big = value.bitPattern.bigEndian
    return withUnsafeBytes(of: big) { Array($0) }
}

/// Incremental OSC message builder. `packet()` emits address + type tags + args.
struct OSCPacketBuilder {
    var address: String
    private var tags = ""
    private var args: [UInt8] = []

    init(_ address: String) {
        self.address = address
    }

    mutating func int(_ value: Int32) { tags += "i"; args += oscInt32Bytes(value) }
    mutating func float(_ value: Float) { tags += "f"; args += oscFloat32Bytes(value) }
    mutating func string(_ value: String) { tags += "s"; args += oscPadded(value) }
    mutating func bool(_ value: Bool) { tags += value ? "T" : "F" }

    /// Raw escape hatch: lets a test emit a type tag with no correctly encoded payload.
    mutating func raw(tag: Character, bytes: [UInt8]) { tags.append(tag); args += bytes }

    func packet() -> Data {
        Data(oscPadded(address) + oscPadded("," + tags) + args)
    }
}

/// Builds a packet whose tag string is supplied verbatim (including the leading comma).
func oscRawPacket(address: String, tags: String, args: [UInt8]) -> Data {
    Data(oscPadded(address) + oscPadded(tags) + args)
}

func oscMessage(_ address: String,
                build: (inout OSCPacketBuilder) -> Void = { _ in }) -> Data {
    var builder = OSCPacketBuilder(address)
    build(&builder)
    return builder.packet()
}

func oscBundle(_ elements: [Data]) -> Data {
    var bytes = oscPadded("#bundle")
    bytes += [0, 0, 0, 0, 0, 0, 0, 1]  // immediate time tag
    for element in elements {
        bytes += oscInt32Bytes(Int32(element.count))
        bytes += Array(element)
    }
    return Data(bytes)
}

// MARK: - State fixtures

extension MX2Cue {
    static func slot(_ color: Int, _ name: String = "", pressed: Bool = false) -> MX2Cue {
        MX2Cue(color: color, name: name, pressed: pressed)
    }
}

extension MX2FeedbackState {
    /// Convenience for renderer tests: deck 1 = left physical deck, deck 2 = right.
    static func playingDecks(playing: Set<Int> = [1]) -> MX2FeedbackState {
        var state = MX2FeedbackState()
        for deck in playing {
            state[deck: deck].playing = true
            state[deck: deck].loaded = true
        }
        return state
    }
}
