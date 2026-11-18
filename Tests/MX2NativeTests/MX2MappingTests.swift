import XCTest
@testable import MX2Native
import IndirectInputCore

final class MX2MappingTests: XCTestCase {
    func testPureMappingUsesSuppliedAbsolutePositionAndDefendsValueRange() {
        var mapping = MX2Mapping()
        for firstDeck in [1, 3] {
            mapping.firstDeck = firstDeck
            for side in [MX2Side.left, .right] {
                let deck = mapping.deck(side)
                for (position, expected) in [(0.42, Float(0.42)), (-0.1, 0), (1.1, 1),
                                             (Double.nan, 0), (.infinity, 0), (-.infinity, 0)] {
                    XCTAssertEqual(mapping.route(.jog(side, delta: -12),
                        bank: [.hotcues, .hotcues], shift: [false, false], jogMode: [true, true],
                        jogTouch: [true, true], jogPosition: [deck: position]),
                        [OSCMessage(address: "/Syndicate/Deck/\(deck)/WaveformSeek", float: expected)])
                }
            }
        }
    }

    func testUntouchedMappingKeepsDocumentedSignOnlyBendForAllDeltaMagnitudes() {
        let mapping = MX2Mapping()
        for (delta, sign): (Int32, Int32) in [(1, 1), (480, 1), (.max, 1),
                                             (-1, -1), (-480, -1), (.min, -1), (0, 0)] {
            XCTAssertEqual(mapping.route(.jog(.left, delta: delta),
                bank: [.hotcues, .hotcues], shift: [false, false], jogMode: [false, false]),
                [OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: sign)])
        }
    }

    @MainActor
    func testTouchIsIndependentPerSideAndReleaseReturnsToBend() async throws {
        let controller = MX2NativeController()
        var messages: [OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.button(.jogTouch(.left), pressed: true))
        controller.handle(.jog(.left, delta: 96))
        controller.handle(.jog(.right, delta: -96))
        controller.handle(.jog(.right, delta: 0))
        controller.handle(.button(.jogTouch(.left), pressed: false))
        controller.handle(.jog(.left, delta: 192))
        controller.handle(.jog(.left, delta: 0))
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 0.001),
            OSCMessage(address: "/Syndicate/Deck/2/PhaseBend", integer: -1),
            OSCMessage(address: "/Syndicate/Deck/2/PhaseBend", integer: 0),
            OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: 0)
        ])
        XCTAssertEqual(controller.jogPosition[1], 0.001)
        XCTAssertNil(controller.jogPosition[2])
        XCTAssertEqual(controller.jogTouch, [false, false])
    }

    @MainActor
    func testSeekPositionsSurviveDeckPairChangesWithoutCrossContamination() {
        let controller = MX2NativeController()
        controller.jogPosition = [1: 0.1, 2: 0.2, 3: 0.3, 4: 0.4]
        var messages: [OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.button(.jogTouch(.left), pressed: true))
        controller.handle(.button(.jogTouch(.right), pressed: true))
        for firstDeck in [1, 3, 1] {
            controller.mapping.firstDeck = firstDeck
            controller.handle(.jog(.left, delta: 96))
            controller.handle(.jog(.right, delta: -96))
        }
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 0.101),
            OSCMessage(address: "/Syndicate/Deck/2/WaveformSeek", float: 0.199),
            OSCMessage(address: "/Syndicate/Deck/3/WaveformSeek", float: 0.301),
            OSCMessage(address: "/Syndicate/Deck/4/WaveformSeek", float: 0.399),
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 0.102),
            OSCMessage(address: "/Syndicate/Deck/2/WaveformSeek", float: 0.198)
        ])
    }

    @MainActor
    func testSeekClampsAtTrackEndsAndReversesImmediatelyWithoutOverflow() {
        let controller = MX2NativeController()
        var messages: [OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.button(.jogTouch(.left), pressed: true))
        for delta: Int32 in [.min, 96, .max, -96] {
            controller.handle(.jog(.left, delta: delta))
        }
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 0),
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 0.001),
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 1),
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 0.999)
        ])
        for invalid in [Double.nan, .infinity, -.infinity] {
            controller.jogPosition[1] = invalid
            controller.handle(.jog(.left, delta: 96))
            XCTAssertEqual(messages.last, OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 0.001))
            XCTAssertEqual(controller.jogPosition[1], 0.001)
        }
    }

    @MainActor
    func testTouchWithoutMotionAndZeroDeltaNeverSeekOrScheduleBendRelease() async throws {
        let controller = MX2NativeController()
        var messages: [OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.button(.jogTouch(.right), pressed: true))
        controller.handle(.jog(.right, delta: 0))
        controller.handle(.button(.jogTouch(.right), pressed: false))
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(controller.jogPosition.isEmpty)
    }

    @MainActor
    func testSeekHasNoDelayedBendReleaseAndDoesNotWrapAtOneRevolution() async throws {
        let controller = MX2NativeController()
        var messages: [OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.button(.jogTouch(.left), pressed: true))
        for _ in 0..<4 { controller.handle(.jog(.left, delta: 480)) }
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(messages, [0.005, 0.01, 0.015, 0.02].map {
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: Float($0))
        })
    }

    @MainActor
    func testSeekDistanceIsIndependentOfHowTicksAreSplitAcrossReports() {
        let slow = MX2NativeController()
        let fast = MX2NativeController()
        for controller in [slow, fast] {
            controller.handle(.button(.jogTouch(.right), pressed: true))
        }
        for _ in 0..<10 { slow.handle(.jog(.right, delta: 24)) }
        fast.handle(.jog(.right, delta: 240))
        XCTAssertEqual(slow.jogPosition[2]!, fast.jogPosition[2]!, accuracy: 1e-12)
    }

    @MainActor
    func testShiftJogUsesZoomTriggersBeforeTouchAndNeverChangesSeekPosition() async throws {
        let controller = MX2NativeController()
        var messages: [OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.jogPosition[4] = 0.5
        controller.mapping.firstDeck = 3
        controller.handle(.button(.shift(.right), pressed: true))
        controller.handle(.jog(.right, delta: 48))
        controller.handle(.button(.jogTouch(.right), pressed: true))
        controller.handle(.jog(.right, delta: -96))
        controller.handle(.jog(.right, delta: 0))
        controller.handle(.button(.jogTouch(.right), pressed: false))
        controller.handle(.button(.shift(.right), pressed: false))
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/4/WaveformZoomIn", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/4/WaveformZoomOut", integer: 1)
        ])
        XCTAssertEqual(controller.jogPosition[4], 0.5)
    }

    @MainActor
    func testTouchAndShiftImmediatelyReleaseOriginalBendWithoutDuplicateTimerRelease() async throws {
        for modifier in [MX2Control.jogTouch(.left), .shift(.left)] {
            let controller = MX2NativeController()
            var messages: [OSCMessage] = []
            controller.onControl = { messages.append($0) }
            controller.handle(.jog(.left, delta: 24))
            controller.mapping.firstDeck = 3
            controller.handle(.button(modifier, pressed: true))
            let expected = [
                OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: 1),
                OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: 0)
            ]
            XCTAssertEqual(messages, expected, "release on mode transition, not on a later jog")
            controller.handle(.jog(.left, delta: 0))
            controller.handle(.button(modifier, pressed: false))
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertEqual(messages, expected)
        }
    }

    @MainActor
    func testTouchedJogAccumulatesSignedTicksWithProportionalSeekDistance() {
        let controller = MX2NativeController()
        var messages: [OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.button(.jogTouch(.left), pressed: true))
        controller.handle(.jog(.left, delta: 96))
        controller.handle(.jog(.left, delta: 192))
        controller.handle(.jog(.left, delta: -96))
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 0.001),
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 0.003),
            OSCMessage(address: "/Syndicate/Deck/1/WaveformSeek", float: 0.002)
        ])
    }
}
