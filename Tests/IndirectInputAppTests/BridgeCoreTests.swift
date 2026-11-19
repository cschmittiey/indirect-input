import XCTest
import IndirectInputCore

final class IndirectInputCoreTests: XCTestCase {
    func testFloatAndMultiArgumentOSCMessageEncoding() {
        let message = OSCMessage(address: "/Deck/1/HotCue",
                                 arguments: [.int(3), .int(1)])
        XCTAssertEqual(message.integer, 3)
        XCTAssertEqual(Array(message.packet), Array("/Deck/1/HotCue\0".utf8) + [
            0, 44, 105, 105, 0, 0, 0, 0, 3, 0, 0, 0, 1
        ])
        let floatMessage = OSCMessage(address: "/Deck/1/TempoSlider", float: 1)
        XCTAssertEqual(floatMessage.arguments, [.float(1)])
    }

    func testOSCMessageUsesExactTriggerAddressAndInt32Payload() {
        let message = OSCMessage(address: "/Syndicate/Browser/Navigation/Down", integer: 1)
        XCTAssertEqual(Array(message.packet), [
            47, 83, 121, 110, 100, 105, 99, 97, 116, 101, 47, 66,
            114, 111, 119, 115, 101, 114, 47, 78, 97, 118, 105, 103,
            97, 116, 105, 111, 110, 47, 68, 111, 119, 110, 0, 0,
            44, 105, 0, 0,
            0, 0, 0, 1
        ])
    }

    /// The bridge encodes and the feedback receiver decodes with the same type, so
    /// whatever one side writes the other must read back unchanged.
    func testEncodedMessagesParseBackIdentically() {
        let messages = [
            OSCMessage(address: "/Syndicate/Deck/3/HotCue", arguments: [.int(4), .int(1)]),
            OSCMessage(address: "/Syndicate/Mixer/CH1/Volume", float: 0.25),
            OSCMessage(address: "/Syndicate/Deck/1/Sampler/LaneSet",
                       arguments: [.int(2), .string("Mute"), .float(1)]),
            OSCMessage(address: "/Syndicate/Browser/L1")
        ]
        for message in messages {
            XCTAssertEqual(OSCMessage.parseAll(message.packet), [message])
        }
    }

    /// The deleted MX2Native parser crashed on exactly this: an immediate bundle.
    func testBundleOfEncodedMessagesParses() {
        let inner = [OSCMessage(address: "/Syndicate/Deck/1/Playing", integer: 1),
                     OSCMessage(address: "/Syndicate/Mixer/CH2/Meter", float: 0.5)]
        var bundle = Data("#bundle\0".utf8)
        bundle.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])
        for message in inner {
            var size = UInt32(message.packet.count).bigEndian
            withUnsafeBytes(of: &size) { bundle.append(contentsOf: $0) }
            bundle.append(message.packet)
        }
        XCTAssertEqual(OSCMessage.parseAll(bundle), inner)
    }
}
