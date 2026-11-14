import Foundation
import CoreMIDI

public enum MX2MIDIEvent: Equatable, Sendable {
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case note(channel: UInt8, number: UInt8, velocity: UInt8)

    public init?(eventPacket: MIDIEventPacket) {
        guard eventPacket.wordCount > 0 else { return nil }
        let word = eventPacket.words.0
        guard (word >> 28) & 0x0F == 0x02 else { return nil }
        let status = UInt8((word >> 16) & 0xFF)
        let channel = (status & 0x0F) + 1
        let number = UInt8((word >> 8) & 0xFF)
        let value = UInt8(word & 0xFF)
        switch status & 0xF0 {
        case 0xB0:
            self = .controlChange(channel: channel, controller: number, value: value)
        case 0x90:
            self = .note(channel: channel, number: number, velocity: value)
        case 0x80:
            self = .note(channel: channel, number: number, velocity: 0)
        default:
            return nil
        }
    }
}
