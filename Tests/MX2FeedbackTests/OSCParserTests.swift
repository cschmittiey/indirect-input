import XCTest
@testable import MX2Feedback

final class OSCParserTests: XCTestCase {

    // MARK: Basic decoding

    func testParsesIntArgument() throws {
        let packet = oscMessage("/Syndicate/Deck/1/Playing") { $0.int(1) }
        let message = try XCTUnwrap(OSCMessage.parse(packet))
        XCTAssertEqual(message.address, "/Syndicate/Deck/1/Playing")
        XCTAssertEqual(message.arguments, [.int(1)])
        XCTAssertEqual(message.int(0), 1)
    }

    func testParsesFloatAndStringAndIntMixedInOrder() throws {
        let packet = oscMessage("/Syndicate/Deck/2/Cues") {
            $0.int(4)
            $0.float(0.5)
            $0.string("Vocal")
            $0.int(-7)
        }
        let message = try XCTUnwrap(OSCMessage.parse(packet))
        XCTAssertEqual(message.arguments, [.int(4), .float(0.5), .string("Vocal"), .int(-7)])
        XCTAssertEqual(message.float(1), 0.5)
        XCTAssertEqual(message.string(2), "Vocal")
        XCTAssertEqual(message.int(3), -7)
    }

    func testNoArgumentMessageParsesWithEmptyArguments() throws {
        let packet = oscMessage("/Syndicate/Feedback/Resend")
        let message = try XCTUnwrap(OSCMessage.parse(packet))
        XCTAssertTrue(message.arguments.isEmpty)
    }

    func testZeroArgumentTypeTagStringIsAccepted() throws {
        let packet = oscRawPacket(address: "/Syndicate/Loaded", tags: ",", args: [])
        let message = try XCTUnwrap(OSCMessage.parse(packet))
        XCTAssertEqual(message.address, "/Syndicate/Loaded")
        XCTAssertTrue(message.arguments.isEmpty)
    }

    func testAddressPaddingIsRespected() throws {
        // A reader that ignores padding lands on the type tags early and mis-decodes.
        let address = "/Syndicate/Deck/1/Sync"  // 23 bytes with terminator -> 24
        XCTAssertEqual((address.utf8.count + 1) % 4, 3, "exercises 3 pad bytes")
        let packet = oscMessage(address) { $0.int(1) }
        let message = try XCTUnwrap(OSCMessage.parse(packet))
        XCTAssertEqual(message.address, address)
        XCTAssertEqual(message.arguments, [.int(1)])
    }

    func testAddressesNeedingOneTwoAndThreePadBytesAllParse() throws {
        for extra in 0...3 {
            let base = "/Syndicate"
            // Pad the address so the terminator lands in each alignment case.
            let address = base + String(repeating: "x", count: extra + 1)
            let packet = oscMessage(address) { $0.string("ok") }
            let message = try XCTUnwrap(OSCMessage.parse(packet), "alignment \(extra)")
            XCTAssertEqual(message.address, address, "alignment \(extra)")
            XCTAssertEqual(message.string(0), "ok", "alignment \(extra)")
        }
    }

    func testStringArgumentsArePaddedIndependently() throws {
        let packet = oscMessage("/Syndicate/Deck/1/Cues") {
            $0.int(0)
            $0.string("a")       // 2 bytes -> 4
            $0.int(1)
            $0.string("abcd")    // 5 bytes -> 8
            $0.int(2)
        }
        let message = try XCTUnwrap(OSCMessage.parse(packet))
        XCTAssertEqual(message.arguments.count, 5)
        XCTAssertEqual(message.string(1), "a")
        XCTAssertEqual(message.string(3), "abcd")
        XCTAssertEqual(message.int(4), 2)
    }

    func testUTF8StringArgumentSurvivesPadding() throws {
        let packet = oscMessage("/Syndicate/Deck/1/Cues") { $0.string("Café ☕") }
        let message = try XCTUnwrap(OSCMessage.parse(packet))
        XCTAssertEqual(message.string(0), "Café ☕")
    }

    func testTrailingNulTerminatorOnAPacketIsIgnored() throws {
        var bytes = Array(oscMessage("/Syndicate/Loaded") { $0.int(1) })
        bytes.append(0)
        let message = try XCTUnwrap(OSCMessage.parse(Data(bytes)))
        XCTAssertEqual(message.arguments, [.int(1)])
    }

    // MARK: Bundles

    func testParsesImmediateBundleOfTwoMessages() throws {
        let bundle = oscBundle([
            oscMessage("/Syndicate/Loaded") { $0.int(1) },
            oscMessage("/Syndicate/Deck/2/Playing") { $0.int(0) }
        ])
        let messages = OSCMessage.parseAll(bundle)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].address, "/Syndicate/Loaded")
        XCTAssertEqual(messages[1].address, "/Syndicate/Deck/2/Playing")
        XCTAssertEqual(messages[1].int(0), 0)
    }

    func testParsesNestedBundle() throws {
        let inner = oscBundle([oscMessage("/Syndicate/PlayPending") { $0.int(1) }])
        let outer = oscBundle([inner])
        let messages = OSCMessage.parseAll(outer)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].address, "/Syndicate/PlayPending")
    }

    func testBundleSkipsElementWithTruncatedLengthButKeepsOthers() throws {
        var bytes = oscPadded("#bundle")
        bytes += [0, 0, 0, 0, 0, 0, 0, 1]
        let good = Array(oscMessage("/Syndicate/Loaded") { $0.int(1) })
        bytes += oscInt32Bytes(Int32(good.count))
        bytes += good
        bytes += oscInt32Bytes(999)  // claims more bytes than remain
        bytes += good
        let messages = OSCMessage.parseAll(Data(bytes))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].address, "/Syndicate/Loaded")
    }

    func testBundleSkipsMalformedElementAndDecodesTheNext() throws {
        let message = Array(oscMessage("/Syndicate/Loaded") { $0.int(1) })
        let truncated = Array(message.prefix(6))  // valid length, unusable content
        var bytes = oscPadded("#bundle")
        bytes += [0, 0, 0, 0, 0, 0, 0, 1]
        bytes += oscInt32Bytes(Int32(truncated.count))
        bytes += truncated
        // Length-prefixed element framing keeps the next element recoverable.
        bytes += oscInt32Bytes(Int32(message.count))
        bytes += message
        let messages = OSCMessage.parseAll(Data(bytes))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].address, "/Syndicate/Loaded")
        XCTAssertEqual(messages[0].int(0), 1)
    }

    // MARK: Malformed input

    func testIgnoresEmptyPacket() {
        XCTAssertNil(OSCMessage.parse(Data()))
        XCTAssertEqual(OSCMessage.parseAll(Data()).count, 0)
    }

    func testIgnoresAddressWithoutLeadingSlash() {
        let packet = oscMessage("Syndicate/Loaded") { $0.int(1) }
        XCTAssertNil(OSCMessage.parse(packet))
    }

    func testIgnoresMissingTypeTagString() {
        var bytes = oscPadded("/Syndicate/Loaded")
        bytes += oscInt32Bytes(1)  // no ",i" tag string at all
        XCTAssertNil(OSCMessage.parse(Data(bytes)))
    }

    func testIgnoresUnterminatedAddress() {
        // Full 4 bytes with no null terminator anywhere.
        var bytes = Array("/Synd".utf8)
        bytes += oscPadded(",i")
        bytes += oscInt32Bytes(1)
        XCTAssertNil(OSCMessage.parse(Data(bytes)))
    }

    func testIgnoresUnsupportedTypeTagsInsteadOfMisreadingFollowingArguments() throws {
        // 'b' (blob) is unsupported: the whole message is unusable, not partially decoded.
        let packet = oscRawPacket(address: "/Syndicate/Deck/1/Cues", tags: ",ib", args: oscInt32Bytes(1))
        XCTAssertNil(OSCMessage.parse(packet))
    }

    func testIgnoresArgumentCountLongerThanPayload() {
        let packet = oscRawPacket(address: "/Syndicate/Deck/1/Cues", tags: ",iiii", args: oscInt32Bytes(1))
        XCTAssertNil(OSCMessage.parse(packet))
    }

    func testIgnoresTrailingNonZeroBytesAfterCompleteArguments() {
        // Extra bytes that are not NUL padding mean the reader desynced; the message
        // must be rejected rather than silently reporting a short argument list.
        let packet = oscRawPacket(address: "/Syndicate/Loaded", tags: ",i",
                                  args: oscInt32Bytes(1) + [0, 0, 1, 0])
        XCTAssertNil(OSCMessage.parse(packet))
    }

    func testToleratesTrailingNullPaddingAfterArguments() {
        let packet = oscRawPacket(address: "/Syndicate/Loaded", tags: ",i",
                                  args: oscInt32Bytes(1) + [0, 0])
        let message = OSCMessage.parse(packet)
        XCTAssertEqual(message?.arguments, [.int(1)])
    }

    func testIgnoresNonBundleBraceTag() {
        // "#bundle" style payload that is not a real bundle: length-prefix garbage.
        var bytes = oscPadded("#bundle")
        bytes += [0, 0, 0, 0, 0, 0, 0, 1]
        bytes += oscInt32Bytes(0x7FFF_FFFF)
        XCTAssertEqual(OSCMessage.parseAll(Data(bytes)).count, 0)
    }

    func testIgnoresBundleWithShortHeader() {
        let bytes = Array("#bund".utf8)
        XCTAssertEqual(OSCMessage.parseAll(Data(bytes)).count, 0)
        XCTAssertNil(OSCMessage.parse(Data(bytes)))
    }

    func testIntAndFloatAreDistinguishedNotCoerced() throws {
        let packet = oscRawPacket(address: "/Syndicate/Deck/1/TempoSlider",
                                  tags: ",i",
                                  args: oscInt32Bytes(5))
        let message = try XCTUnwrap(OSCMessage.parse(packet))
        XCTAssertEqual(message.arguments, [.int(5)])
        XCTAssertNil(message.float(0))
        XCTAssertEqual(message.number(0), 5)
    }

    func testTruncatedFloatArgumentIsRejected() {
        let packet = oscRawPacket(address: "/Syndicate/Mixer/CH1/Meter",
                                  tags: ",f",
                                  args: [0x3F, 0x80])  // 2 of 4 bytes
        XCTAssertNil(OSCMessage.parse(packet))
    }
}
