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

    func testShiftedBrowseUsesTreeNavigationAndLoadUsesSelectedDeck() {
        let event = BrowseEvent(channel: 2, controller: 19, value: 63)!
        XCTAssertEqual(BridgeRouting.message(for: event, shifted: true).address,
                       "/Syndicate/Browser/Navigation/Left")
        XCTAssertEqual(BridgeRouting.loadMessage(deck: 2).address,
                       "/Syndicate/Browser/L2")
        XCTAssertEqual(BridgeRouting.loadMessage(deck: 2).integer, 1)
    }

    func testOSCMessageUsesExactTriggerAddressAndInt32Payload() {
        let event = BrowseEvent(channel: 1, controller: 19, value: 65)!
        let message = BridgeRouting.message(for: event)
        XCTAssertEqual(message.address, "/Syndicate/Browser/Navigation/Down")
        XCTAssertEqual(message.integer, 1)
        XCTAssertEqual(Array(message.packet), [
            47, 83, 121, 110, 100, 105, 99, 97, 116, 101, 47, 66,
            114, 111, 119, 115, 101, 114, 47, 78, 97, 118, 105, 103,
            97, 116, 105, 111, 110, 47, 68, 111, 119, 110, 0, 0,
            44, 105, 0, 0,
            0, 0, 0, 1
        ])
    }

    func testUnrelatedValuesAndControlsAreIgnored() {
        XCTAssertNil(BrowseEvent(channel: 1, controller: 19, value: 64))
        XCTAssertNil(BrowseEvent(channel: 1, controller: 19, value: 0))
        XCTAssertNotNil(BrowseEvent(channel: 1, controller: 16, value: 63))
        XCTAssertNotNil(BrowseEvent(channel: 2, controller: 19, value: 63))
    }

    func testClockwiseDetentRoutesDown() {
        XCTAssertEqual(BrowseEvent(channel: 1, controller: 19, value: 65),
                       BrowseEvent(direction: .down, value: 65))
    }

    func testCounterClockwiseDetentRoutesUp() {
        XCTAssertEqual(BrowseEvent(channel: 1, controller: 19, value: 63),
                       BrowseEvent(direction: .up, value: 63))
    }
}
