import Foundation
import CoreMIDI

public struct MIDIControllerMessage: Equatable, Sendable {
    public let channel: UInt8
    public let controller: UInt8
    public let value: UInt8

    public init?(eventPacket: MIDIEventPacket) {
        guard eventPacket.wordCount > 0 else { return nil }
        let word = eventPacket.words.0
        guard (word >> 28) & 0x0F == 0x02 else { return nil } // MIDI 1 channel voice
        let status = UInt8((word >> 16) & 0xFF)
        guard status & 0xF0 == 0xB0 else { return nil }
        channel = (status & 0x0F) + 1
        controller = UInt8((word >> 8) & 0xFF)
        value = UInt8(word & 0xFF)
    }

    public init?(packet: MIDIPacket) {
        guard packet.length == 3 else { return nil }
        let bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(3)) }
        guard bytes[0] & 0xF0 == 0xB0 else { return nil }
        channel = (bytes[0] & 0x0F) + 1
        controller = bytes[1]
        value = bytes[2]
    }
}

public enum MIDIEndpoints {
    public static func stringProperty(_ object: MIDIObjectRef,
                                      _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr,
              let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    public static func uniqueID(_ object: MIDIObjectRef) -> MIDIUniqueID? {
        var value: MIDIUniqueID = 0
        guard MIDIObjectGetIntegerProperty(object, kMIDIPropertyUniqueID, &value) == noErr else {
            return nil
        }
        return value
    }

    public static func isOnline(_ endpoint: MIDIEndpointRef) -> Bool {
        var offline: Int32 = 1
        guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline) == noErr else {
            return false
        }
        return offline == 0
    }

    public static func matchingSource(name: String, uniqueID: MIDIUniqueID?) -> MIDIEndpointRef? {
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            let sourceName = stringProperty(source, kMIDIPropertyDisplayName)
                ?? stringProperty(source, kMIDIPropertyName) ?? ""
            let nameMatches = sourceName.localizedCaseInsensitiveCompare(name) == .orderedSame
            let idMatches = uniqueID.map { self.uniqueID(source) == $0 } ?? false
            guard isOnline(source) else { continue }
            if nameMatches { return source }
            if uniqueID != nil, idMatches { return source }
        }
        return nil
    }

    public static func sourceNamed(_ name: String) -> MIDIEndpointRef? {
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            let sourceName = stringProperty(source, kMIDIPropertyDisplayName)
                ?? stringProperty(source, kMIDIPropertyName) ?? ""
            if sourceName.localizedCaseInsensitiveCompare(name) == .orderedSame {
                return source
            }
        }
        return nil
    }
}
