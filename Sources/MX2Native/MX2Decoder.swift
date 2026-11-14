import Foundation

public enum MX2Side: Int, Sendable {
    case left = 0
    case right = 1
}

public enum MX2PadBank: Int, Sendable, CaseIterable {
    case hotcues = 0
    case stems = 1
    case pattern = 2
    case loops = 3
}

public enum MX2Control: Hashable, Sendable {
    case fxButton(MX2Side, Int)
    case favorite(MX2Side)
    case addToList(MX2Side)
    case preview(MX2Side)
    case view(MX2Side)
    case flux(MX2Side)
    case reverse(MX2Side)
    case turntable(MX2Side)
    case jogMode(MX2Side)
    case shift(MX2Side)
    case sync(MX2Side)
    case master(MX2Side)
    case keyLock(MX2Side)
    case bank(MX2Side, MX2PadBank)
    case pad(MX2Side, Int)
    case cue(MX2Side)
    case play(MX2Side)
    case fxAssign(MX2Side, Int)
    case channelFX(MX2Side)
    case headphone(MX2Side)
    case globalFX(Int)
    case filter
    case microphone
    case browsePress(MX2Side)
    case movePress(MX2Side)
    case sizePress(MX2Side)
    case jogTouch(MX2Side)
}

public enum MX2Analog: Hashable, Sendable {
    case fxKnob(MX2Side, Int)
    case gain(MX2Side)
    case eqHigh(MX2Side)
    case eqMid(MX2Side)
    case eqLow(MX2Side)
    case channelFX(MX2Side)
    case mainVolume
    case cueMix
    case cueVolume
    case volume(MX2Side)
    case crossfader
    case tempo(MX2Side)
}

public enum MX2Encoder: Hashable, Sendable {
    case browse(MX2Side)
    case move(MX2Side)
    case size(MX2Side)
}

public enum MX2InputEvent: Equatable, Sendable {
    case button(MX2Control, pressed: Bool)
    case analog(MX2Analog, value: UInt16)
    case encoder(MX2Encoder, delta: Int)
    case jog(MX2Side, delta: Int32)
}

public struct MX2Decoder: Sendable {
    private var analogValues: [UInt16] = Array(repeating: 0, count: 26)
    private var buttonValues: [Bool] = Array(repeating: false, count: 82)
    private var encoderValues: [UInt8] = Array(repeating: 0, count: 6)
    private var jogValues: [UInt32] = [0, 0]
    private var initialized = false

    public init() {}

    public mutating func decode(_ report: [UInt8]) -> [MX2InputEvent] {
        guard let id = report.first else { return [] }
        defer { initialized = true }
        switch id {
        case 1 where report.count == 15:
            return decodeButtons(Array(report.dropFirst()))
        case 2 where report.count == 53:
            return decodeAnalogs(Array(report.dropFirst()))
        case 3 where report.count == 20:
            return decodeJogs(Array(report.dropFirst()))
        default:
            return []
        }
    }

    private mutating func decodeButtons(_ data: [UInt8]) -> [MX2InputEvent] {
        var events: [MX2InputEvent] = []
        for index in 0..<82 {
            let pressed = (data[index / 8] & (1 << (index % 8))) != 0
            guard initialized, buttonValues[index] != pressed else { continue }
            let control = Self.buttons[index]
            events.append(.button(control, pressed: pressed))
        }
        buttonValues = (0..<82).map { (data[$0 / 8] & (1 << ($0 % 8))) != 0 }
        for index in 0..<6 {
            let nibble = (data[11 + index / 2] >> (4 * (index % 2))) & 0x0F
            let old = encoderValues[index]
            guard initialized, nibble != old,
                  let encoder = MX2Encoder(rawValue: index) else { continue }
            var delta = Int(nibble) - Int(old)
            if delta > 7 { delta -= 16 }
            if delta < -7 { delta += 16 }
            events.append(.encoder(encoder, delta: delta))
        }
        encoderValues = (0..<6).map { (data[11 + $0 / 2] >> (4 * ($0 % 2))) & 0x0F }
        return events
    }

    private mutating func decodeAnalogs(_ data: [UInt8]) -> [MX2InputEvent] {
        var events: [MX2InputEvent] = []
        for index in 0..<26 {
            let value = UInt16(data[index * 2]) | (UInt16(data[index * 2 + 1]) << 8)
            guard initialized, analogValues[index] != value else { continue }
            let analog = Self.analogs[index]
            events.append(.analog(analog, value: value))
        }
        analogValues = (0..<26).map { UInt16(data[$0 * 2]) | (UInt16(data[$0 * 2 + 1]) << 8) }
        return events
    }

    private mutating func decodeJogs(_ data: [UInt8]) -> [MX2InputEvent] {
        var events: [MX2InputEvent] = []
        for side in 0..<2 {
            let offset = 3 + side * 8 + 4
            let value = (UInt32(data[offset + 3]) << 24) | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 1]) << 8) | UInt32(data[offset])
            let delta = Int32(bitPattern: value &- jogValues[side])
            let wrapped = delta > 480 ? delta - 960 : delta < -480 ? delta + 960 : delta
            if initialized, wrapped != 0 {
                events.append(.jog(MX2Side(rawValue: side)!, delta: wrapped))
            }
            jogValues[side] = value
        }
        return events
    }

    private static let analogs: [MX2Analog] = [
        .fxKnob(.left, 1), .fxKnob(.left, 2), .fxKnob(.left, 3), .fxKnob(.left, 4),
        .fxKnob(.right, 1), .fxKnob(.right, 2), .fxKnob(.right, 3), .fxKnob(.right, 4),
        .gain(.left), .eqHigh(.left), .eqMid(.left), .eqLow(.left), .channelFX(.left),
        .gain(.right), .eqHigh(.right), .eqMid(.right), .eqLow(.right), .channelFX(.right),
        .mainVolume, .cueMix, .cueVolume, .volume(.left), .volume(.right), .crossfader,
        .tempo(.left), .tempo(.right)
    ]

    private static let buttons: [MX2Control] = [
        .fxButton(.left, 1), .fxButton(.left, 2), .fxButton(.left, 3), .fxButton(.left, 4),
        .favorite(.left), .addToList(.left), .preview(.left), .view(.left),
        .flux(.left), .reverse(.left), .turntable(.left), .jogMode(.left), .shift(.left),
        .sync(.left), .master(.left), .keyLock(.left),
        .bank(.left, .hotcues), .bank(.left, .stems), .bank(.left, .pattern), .bank(.left, .loops),
        .pad(.left, 1), .pad(.left, 2), .pad(.left, 3), .pad(.left, 4),
        .pad(.left, 5), .pad(.left, 6), .pad(.left, 7), .pad(.left, 8),
        .cue(.left), .play(.left),
        .fxButton(.right, 1), .fxButton(.right, 2), .fxButton(.right, 3), .fxButton(.right, 4),
        .favorite(.right), .addToList(.right), .preview(.right), .view(.right),
        .flux(.right), .reverse(.right), .turntable(.right), .jogMode(.right), .shift(.right),
        .sync(.right), .master(.right), .keyLock(.right),
        .bank(.right, .hotcues), .bank(.right, .stems), .bank(.right, .pattern), .bank(.right, .loops),
        .pad(.right, 1), .pad(.right, 2), .pad(.right, 3), .pad(.right, 4),
        .pad(.right, 5), .pad(.right, 6), .pad(.right, 7), .pad(.right, 8),
        .cue(.right), .play(.right),
        .fxAssign(.left, 1), .fxAssign(.left, 2), .channelFX(.left), .headphone(.left),
        .fxAssign(.right, 1), .fxAssign(.right, 2), .channelFX(.right), .headphone(.right),
        .globalFX(1), .globalFX(2), .globalFX(3), .globalFX(4), .filter, .microphone,
        .browsePress(.left), .movePress(.left), .sizePress(.left),
        .browsePress(.right), .movePress(.right), .sizePress(.right),
        .jogTouch(.left), .jogTouch(.right)
    ]
}

extension MX2Encoder {
    init?(rawValue: Int) {
        switch rawValue {
        case 0: self = .browse(.left)
        case 1: self = .move(.left)
        case 2: self = .size(.left)
        case 3: self = .browse(.right)
        case 4: self = .move(.right)
        case 5: self = .size(.right)
        default: return nil
        }
    }
}
