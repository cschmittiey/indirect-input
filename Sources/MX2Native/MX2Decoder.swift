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
    private var initializedReports: Set<UInt8> = []

    public init() {}

    /// The first valid snapshot of each report family only establishes a baseline.
    /// Wrong lengths and analogue samples outside 0...4095 are rejected without
    /// emitting events or changing that baseline (including initialization).
    public mutating func decode(_ report: [UInt8]) -> [MX2InputEvent] {
        guard let id = report.first else { return [] }
        let initialized = initializedReports.contains(id)
        switch id {
        case 1 where report.count == 15:
            initializedReports.insert(id)
            return decodeButtons(Array(report.dropFirst()), initialized: initialized)
        case 2 where report.count == 53:
            return decodeAnalogs(Array(report.dropFirst()), initialized: initialized)
        case 3 where report.count == 20:
            initializedReports.insert(id)
            return decodeJogs(Array(report.dropFirst()), initialized: initialized)
        default:
            return []
        }
    }

    private mutating func decodeButtons(_ data: [UInt8], initialized: Bool) -> [MX2InputEvent] {
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
            // Absolute modulo-16 counter samples, not relative signed nibbles:
            // Traktor EncoderHandler::process 0x100d725a8..0x100d725d4 stores the
            // previous sample and subtracts it before applying these corrections.
            var delta = Int(nibble) - Int(old)
            if delta > 7 { delta -= 16 }
            if delta < -7 { delta += 16 }
            events.append(.encoder(encoder, delta: delta))
        }
        encoderValues = (0..<6).map { (data[11 + $0 / 2] >> (4 * ($0 % 2))) & 0x0F }
        return events
    }

    // Report 2 has no leading counter: the live HID descriptor declares Usage 4
    // as 21 * 16 bits at payload offset 0, Usage 5 as 5 * 16 bits at offset 42.
    // Traktor MX2::Device registers PotiHandler(21, 4095) at offset 0 and
    // FaderHandler(5, 4095, baseID: 21) at 42 (0x100d5fb48..0x100d5fc00).
    // ControllerDevice::process passes report+1 (0x100d628f4); AnalogControlHandler
    // reads offset+2*index little-endian (0x100d71f5c..0x100d71f74).
    private mutating func decodeAnalogs(_ data: [UInt8], initialized: Bool) -> [MX2InputEvent] {
        let values = (0..<26).map { UInt16(data[$0 * 2]) | (UInt16(data[$0 * 2 + 1]) << 8) }
        // Reject the entire snapshot before emitting or updating any channel. Masking
        // high bits would conceal a byte-alignment error and corrupt the baseline.
        guard values.allSatisfy({ $0 <= 4095 }) else { return [] }
        initializedReports.insert(2)
        var events: [MX2InputEvent] = []
        for index in 0..<26 {
            let value = values[index]
            guard initialized, analogValues[index] != value else { continue }
            let analog = Self.analogs[index]
            events.append(.analog(analog, value: value))
        }
        analogValues = values
        return events
    }

    // MX2 JogwheelHandler reads position at handlerOffset(3) + side*8 + 4
    // (0x100d5f800..0x100d5f82c). Its constructor sets the wrap to 960 at
    // 0x100d5f510..0x100d5f514. The preceding four bytes are auxiliary timing,
    // not position. Captured report-3 bytes are retained in MX2DecoderTests.
    private mutating func decodeJogs(_ data: [UInt8], initialized: Bool) -> [MX2InputEvent] {
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

    // Software-descriptor control identities, not a hardware-verified sweep map.
    // Use MX2_MAPPING_CAPTURE with MX2DecoderTests.testMappingProbeCapture to
    // compare each physical control's captured wire index against these claims.
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
