import XCTest
@testable import MX2Native
import BridgeCore
import MX2Feedback

final class MX2NativeTests: XCTestCase {
    func testInitialHIDSnapshotDoesNotFireControls() {
        // `decode` drops the report ID, so payload byte N lives at `report[N + 1]`.
        // The decoder emits a *bounded* set of events: a button press it noticed and
        // the browse encoder moving underneath it.
        var decoder = MX2Decoder()
        var report = [UInt8](repeating: 0, count: 15)
        report[0] = 1
        XCTAssertEqual(decoder.decode(report), [], "an all-zero first report must only baseline")
        // Button 80 (left jog touch) held: first report baselines, so silence.
        report[1 + 80 / 8] = 1 << (80 % 8)
        XCTAssertEqual(decoder.decode(report), [.button(.jogTouch(.left), pressed: true)])

        report[12] = 0x01 // Left browse encoder's low nibble moves to one.
        XCTAssertEqual(decoder.decode(report), [.encoder(.browse(.left), delta: 1)])

        report[12] = 0x00
        XCTAssertEqual(decoder.decode(report), [.encoder(.browse(.left), delta: -1)])
    }

    func testRawCueReportUsesTransportCueNotPlay() {
        var decoder = MX2Decoder()
        let idle = [UInt8](repeating: 0, count: 15)
        XCTAssertTrue(decoder.decode([1] + idle.dropFirst()).isEmpty)
        var pressed = idle
        pressed[0] = 1
        pressed[4] = 0x10 // Traktor MX2 descriptor: left Cue is button ID 28.
        XCTAssertEqual(decoder.decode(pressed), [.button(.cue(.left), pressed: true)])
        var rightDecoder = MX2Decoder()
        XCTAssertTrue(rightDecoder.decode([1] + idle.dropFirst()).isEmpty)
        var right = idle
        right[0] = 1
        right[8] = 0x04 // Traktor MX2 descriptor: right Cue is button ID 58.
        XCTAssertEqual(rightDecoder.decode(right), [.button(.cue(.right), pressed: true)])
    }

    func testJogReportDoesNotReleaseButtonBeforeFirstButtonReport() {
        var decoder = MX2Decoder()
        var jog = [UInt8](repeating: 0, count: 20)
        jog[0] = 3
        XCTAssertTrue(decoder.decode(jog).isEmpty)
        var buttons = [UInt8](repeating: 0, count: 15)
        buttons[0] = 1
        buttons[1 + 28 / 8] = 1 << (28 % 8)
        XCTAssertTrue(decoder.decode(buttons).isEmpty)
        buttons[1 + 28 / 8] = 0
        XCTAssertEqual(decoder.decode(buttons), [.button(.cue(.left), pressed: false)])
    }

    func testAnalogUsesFullTwelveBitRange() {
        var decoder = MX2Decoder()
        XCTAssertTrue(decoder.decode([2] + [UInt8](repeating: 0, count: 52)).isEmpty)
        var data = [UInt8](repeating: 0, count: 52)
        data[0] = 0xFF
        data[1] = 0x0F
        XCTAssertEqual(decoder.decode([2] + data), [.analog(.fxKnob(.left, 1), value: 4095)])
    }

    @MainActor
    func testIdleFeedbackFrameIsLegibleButShowsNoRealState() {
        // With no feedback, nothing may claim real state: PLAY and the meters stay
        // dark. But the panel is not a black void — unmapped controls carry a dim
        // "no signal" tint and offline state controls sit dim, so a dead control is
        // distinguishable from a working one that is simply off.
        let client = MX2FeedbackClient()
        let image = client.renderForTesting()
        XCTAssertEqual(image.count, 105)
        XCTAssertEqual(image[30], MX2LEDColor.dimUnmapped.byte(lit: false)) // Right FX1
        XCTAssertEqual(image[43], MX2LEDColor.blue.byte(lit: false))        // Right Sync, dim
        XCTAssertEqual(image[29], 0)                                        // PLAY: unknown
        for index in 60..<73 {
            // Mixer lamps are now populated (dim), never bright without feedback.
            XCTAssertNotEqual(image[index] % 4, 2, "mixer index \(index) must not be bright")
            XCTAssertNotEqual(image[index], 0, "mixer index \(index) should be visible")
        }
    }

    @MainActor
    func testCueAndHeadphoneToggleOnSuccessivePresses() {
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.button(.cue(.left), pressed: true))
        controller.handle(.button(.cue(.left), pressed: false))
        controller.handle(.button(.headphone(.left), pressed: true))
        controller.handle(.button(.headphone(.left), pressed: true))
        XCTAssertEqual(messages.map(\.address), [
            "/Syndicate/Deck/1/Cue", "/Syndicate/Deck/1/Cue",
            "/Syndicate/Mixer/CH1/Cue", "/Syndicate/Mixer/CH1/Cue"
        ])
        XCTAssertEqual(messages.map(\.integer), [1, 0, 1, 0])
    }

    @MainActor
    func testKeyLockAndFluxSendTrackedSwitchStatesPerDeck() {
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        for control in [MX2Control.keyLock(.left), .flux(.left)] {
            controller.handle(.button(control, pressed: true))
            controller.handle(.button(control, pressed: false))
            controller.handle(.button(control, pressed: true))
            controller.handle(.button(control, pressed: false))
        }
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/1/PitchPreserve", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/1/PitchPreserve", integer: 0),
            OSCMessage(address: "/Syndicate/Deck/1/CueSlip", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/1/CueSlip", integer: 0)
        ])

        messages.removeAll()
        controller.handle(.button(.keyLock(.right), pressed: true))
        controller.handle(.button(.flux(.right), pressed: true))
        controller.mapping.firstDeck = 3
        controller.handle(.button(.keyLock(.right), pressed: true))
        controller.handle(.button(.flux(.right), pressed: true))
        controller.mapping.firstDeck = 1
        controller.handle(.button(.keyLock(.right), pressed: true))
        controller.handle(.button(.flux(.right), pressed: true))
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/2/PitchPreserve", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/2/CueSlip", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/4/PitchPreserve", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/4/CueSlip", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/2/PitchPreserve", integer: 0),
            OSCMessage(address: "/Syndicate/Deck/2/CueSlip", integer: 0)
        ])
    }

    @MainActor
    func testGfxToggleTracksInsertSwitchPerLogicalDeckOnPressOnly() {
        // The valuable assertion here is deck-pair persistence: the Switch is keyed by
        // LOGICAL deck, so changing the deck pair must not send a stray bypass and must
        // not lose the state. Only the GFX toggle drives it — deck FX 1-4 are separate
        // physical buttons (bits 60/61) and must not share this switch.
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        for (firstDeck, enabled) in [(1, Int32(1)), (3, Int32(1)), (1, Int32(0))] {
            controller.mapping.firstDeck = firstDeck
            for side in [MX2Side.left, .right] {
                messages.removeAll()
                controller.handle(.button(.channelFX(side), pressed: true))
                // Changing pairs while held must not send a bypass on release.
                controller.mapping.firstDeck = firstDeck == 1 ? 3 : 1
                controller.handle(.button(.channelFX(side), pressed: false))
                controller.mapping.firstDeck = firstDeck
                XCTAssertEqual(messages, [OSCMessage(
                    address: "/Syndicate/Mixer/CH\(firstDeck + side.rawValue)/FX", integer: enabled)])
            }
        }
    }

    @MainActor
    func testGfxToggleOwnsTheInsertSwitchAndDeckFXButtonsDoNotShareIt() {
        // Hardware-verified: FX 1-4 are bits 60/61 (64/65 on the right) and the GFX
        // toggle is a separate button at 62/66. Syndicate has exactly one insert-chain
        // Switch per channel, and the owner chose the GFX toggle to own it. If FX 1
        // also toggled it, pressing FX 1 then the GFX toggle would cancel out.
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }

        // Deck FX buttons must be silent.
        for control in [MX2Control.fxButton(.left, 1), .fxButton(.left, 2),
                        .fxButton(.left, 3), .fxButton(.left, 4),
                        .fxButton(.right, 1)] {
            controller.handle(.button(control, pressed: true))
            controller.handle(.button(control, pressed: false))
        }
        XCTAssertTrue(messages.isEmpty, "deck FX buttons must not drive the insert switch")

        // The GFX toggle alone owns it: on, then off.
        controller.handle(.button(.channelFX(.left), pressed: true))
        controller.handle(.button(.channelFX(.left), pressed: false))
        controller.handle(.button(.channelFX(.left), pressed: true))
        controller.handle(.button(.channelFX(.left), pressed: false))
        XCTAssertEqual(messages, [Int32(1), 0].map {
            OSCMessage(address: "/Syndicate/Mixer/CH1/FX", integer: $0)
        })
    }

    @MainActor
    func testViewCyclesOneSharedBrowserModeOnPressOnly() {
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        for (firstDeck, side) in [(1, MX2Side.left), (1, .right), (3, .left),
                                  (3, .right), (1, .left), (1, .right)] {
            controller.mapping.firstDeck = firstDeck
            controller.handle(.button(.view(side), pressed: true))
            controller.handle(.button(.view(side), pressed: false))
        }
        XCTAssertEqual(messages, [Int32(1), 2, 0, 1, 2, 0].map {
            OSCMessage(address: "/Syndicate/Header/Browser", integer: $0)
        })
    }

    func testFXButtonsTwoThroughFourDoNotOverwriteContinuousInsertMacros() {
        var mapping = MX2Mapping()
        for firstDeck in [1, 3] {
            mapping.firstDeck = firstDeck
            for side in [MX2Side.left, .right] {
                for index in 2...4 {
                    for pressed in [true, false] {
                        XCTAssertEqual(mapping.route(.button(.fxButton(side, index), pressed: pressed),
                                                     bank: [.hotcues, .hotcues], shift: [false, false],
                                                     jogMode: [false, false]), [])
                    }
                }
            }
        }
    }

    func testGlobalFXPresetsDoNotChangeInsertMacrosOrOtherMixerValues() {
        var mapping = MX2Mapping()
        for firstDeck in [1, 3] {
            mapping.firstDeck = firstDeck
            for index in 1...4 {
                for pressed in [true, false] {
                    XCTAssertEqual(mapping.route(.button(.globalFX(index), pressed: pressed),
                                                 bank: [.hotcues, .hotcues], shift: [false, false],
                                                 jogMode: [false, false]), [])
                }
            }
        }
    }

    func testPreviewDoesNotSendAnInventedPreviewDeckRoute() {
        var mapping = MX2Mapping()
        for firstDeck in [1, 3] {
            mapping.firstDeck = firstDeck
            for side in [MX2Side.left, .right] {
                for pressed in [true, false] {
                    XCTAssertEqual(mapping.route(.button(.preview(side), pressed: pressed),
                                                 bank: [.hotcues, .hotcues], shift: [false, false],
                                                 jogMode: [false, false]), [])
                }
            }
        }
    }

    func testPatternPadsSelectZeroBasedSamplerLanesOnPressOnly() {
        var mapping = MX2Mapping()
        for firstDeck in [1, 3] {
            mapping.firstDeck = firstDeck
            for side in [MX2Side.left, .right] {
                for pad in 1...8 {
                    let deck = firstDeck + side.rawValue
                    XCTAssertEqual(mapping.route(.button(.pad(side, pad), pressed: true),
                                                 bank: [.pattern, .pattern], shift: [false, false],
                                                 jogMode: [false, false]),
                                   [OSCMessage(address: "/Syndicate/Deck/\(deck)/Sampler/Lane",
                                               integer: Int32(pad - 1))])
                    XCTAssertTrue(mapping.route(.button(.pad(side, pad), pressed: false),
                                                bank: [.pattern, .pattern], shift: [false, false],
                                                jogMode: [false, false]).isEmpty)
                }
            }
        }
    }

    @MainActor
    func testShiftPatternPadsToggleLaneMuteWithoutSelectingOrTriggering() {
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        for side in [MX2Side.left, .right] {
            controller.handle(.button(.bank(side, .pattern), pressed: true))
            controller.handle(.button(.shift(side), pressed: true))
        }
        for (firstDeck, muted) in [(1, Float(1)), (3, Float(1)), (1, Float(0))] {
            controller.mapping.firstDeck = firstDeck
            for side in [MX2Side.left, .right] {
                for pad in 1...8 {
                    messages.removeAll()
                    controller.handle(.button(.pad(side, pad), pressed: true))
                    controller.handle(.button(.pad(side, pad), pressed: false))
                    // First visit mutes; returning to the first pair unmutes.
                    XCTAssertEqual(messages, [OSCMessage(
                        address: "/Syndicate/Deck/\(firstDeck + side.rawValue)/Sampler/LaneSet",
                        arguments: [.int(Int32(pad)), .string("Mute"), .float(muted)])])
                }
            }
        }
    }

    func testStemsBankDoesNotPretendFXMacrosAreStemControls() {
        let mapping = MX2Mapping()
        for side in [MX2Side.left, .right] {
            for pad in 1...8 {
                for shifted in [false, true] {
                    for pressed in [false, true] {
                        XCTAssertTrue(mapping.route(.button(.pad(side, pad), pressed: pressed),
                                                    bank: [.stems, .stems], shift: [shifted, shifted],
                                                    jogMode: [false, false]).isEmpty)
                    }
                }
            }
        }
    }

    @MainActor
    func testHeldControlsReleaseTheirOriginalRouteAfterBankShiftAndDeckChanges() {
        let cases: [(MX2Native.MX2Control, MX2PadBank, String, [BridgeCore.OSCArgument])] = [
            (.pad(.left, 3), .hotcues, "/Syndicate/Deck/1/HotCue", [.int(3), .int(0)]),
            (.pad(.left, 8), .loops, "/Syndicate/Deck/1/SlipLoop/Four", [.int(0)]),
            (.cue(.left), .hotcues, "/Syndicate/Deck/1/Cue", [.int(0)]),
            (.reverse(.left), .hotcues, "/Syndicate/Deck/1/Reverse", [.int(0)])
        ]
        for (control, bank, address, arguments) in cases {
            let controller = MX2NativeController()
            controller.banks = [bank, .hotcues]
            var messages: [BridgeCore.OSCMessage] = []
            controller.onControl = { messages.append($0) }
            controller.handle(.button(control, pressed: true))
            XCTAssertEqual(messages.first?.address, address)
            controller.handle(.button(.shift(.left), pressed: true))
            controller.handle(.button(.bank(.left, .pattern), pressed: true))
            controller.mapping.firstDeck = 3
            messages.removeAll()
            controller.handle(.button(control, pressed: false))
            XCTAssertEqual(messages, [OSCMessage(address: address, arguments: arguments)])
        }
    }

    @MainActor
    func testNonHoldingPadPressNeverGainsAReleaseWhenBankOrShiftChanges() {
        for bank in [MX2PadBank.hotcues, .pattern, .stems] {
            let controller = MX2NativeController()
            controller.banks = [bank, .hotcues]
            controller.shift = [true, false]
            var messages: [BridgeCore.OSCMessage] = []
            controller.onControl = { messages.append($0) }
            controller.handle(.button(.pad(.left, 2), pressed: true))
            controller.shift = [false, false]
            controller.banks = [.loops, .hotcues]
            messages.removeAll()
            controller.handle(.button(.pad(.left, 2), pressed: false))
            XCTAssertTrue(messages.isEmpty)
        }
    }

    @MainActor
    func testJogBendReleaseStaysOnOriginalDeckAfterPairChanges() async throws {
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.jog(.right, delta: -12))
        controller.mapping.firstDeck = 3
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/2/PhaseBend", integer: -1),
            OSCMessage(address: "/Syndicate/Deck/2/PhaseBend", integer: 0)
        ])
    }

    @MainActor
    func testJogZeroSendsOneReleaseAndCancelsPendingRelease() async throws {
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.jog(.left, delta: 12))
        controller.mapping.firstDeck = 3
        controller.handle(.jog(.left, delta: 0))
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: 0)
        ])
    }

    @MainActor
    func testNewJogDeckReleasesOldBendBeforeStartingNewBend() async throws {
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.jog(.left, delta: 12))
        controller.mapping.firstDeck = 3
        controller.handle(.jog(.left, delta: -12))
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: 0),
            OSCMessage(address: "/Syndicate/Deck/3/PhaseBend", integer: -1),
            OSCMessage(address: "/Syndicate/Deck/3/PhaseBend", integer: 0)
        ])
    }

    func testAllHotcueAndLoopPadsKeepDocumentedArgumentsOnBothDeckPairs() {
        var mapping = MX2Mapping()
        let sizes = ["ThirtySecond", "Sixteenth", "Eighth", "Quarter", "Half", "One", "Two", "Four"]
        for firstDeck in [1, 3] {
            mapping.firstDeck = firstDeck
            for side in [MX2Side.left, .right] {
                let root = "/Syndicate/Deck/\(firstDeck + side.rawValue)"
                for pad in 1...8 {
                    for pressed in [true, false] {
                        for shifted in [false, true] {
                            let event = MX2InputEvent.button(.pad(side, pad), pressed: pressed)
                            let hotcues = mapping.route(event, bank: [.hotcues, .hotcues],
                                                        shift: [shifted, shifted], jogMode: [false, false])
                            let expected: [BridgeCore.OSCMessage] = shifted
                                ? (pressed ? [OSCMessage(address: root + "/SetCueLoop", integer: Int32(pad))] : [])
                                : [OSCMessage(address: root + "/HotCue",
                                              arguments: [.int(Int32(pad)), .int(pressed ? 1 : 0)])]
                            XCTAssertEqual(hotcues, expected)
                            XCTAssertEqual(mapping.route(event, bank: [.loops, .loops],
                                                         shift: [shifted, shifted], jogMode: [false, false]),
                                           [OSCMessage(address: root + "/SlipLoop/" + sizes[pad - 1],
                                                       integer: pressed ? 1 : 0)])
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testAllFourBankButtonsAreLocalAndIndependent() {
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        for bank in MX2PadBank.allCases {
            controller.handle(.button(.bank(.left, bank), pressed: true))
            controller.handle(.button(.bank(.left, bank), pressed: false))
            XCTAssertEqual(controller.banks, [bank, .hotcues])
        }
        controller.handle(.button(.bank(.right, .pattern), pressed: true))
        XCTAssertEqual(controller.banks, [.loops, .pattern])
        XCTAssertTrue(messages.isEmpty)
        controller.handle(.button(.pad(.left, 1), pressed: true))
        controller.handle(.button(.pad(.right, 8), pressed: true))
        XCTAssertEqual(messages, [
            OSCMessage(address: "/Syndicate/Deck/1/SlipLoop/ThirtySecond", integer: 1),
            OSCMessage(address: "/Syndicate/Deck/2/Sampler/Lane", integer: 7)
        ])
    }

    func testInvalidPadIndicesNeverSendMessagesInAnyBank() {
        let mapping = MX2Mapping()
        for bank in MX2PadBank.allCases {
            for pad in [-1, 0, 9] {
                for pressed in [false, true] {
                    XCTAssertTrue(mapping.route(.button(.pad(.left, pad), pressed: pressed),
                                                bank: [bank, bank], shift: [true, true],
                                                jogMode: [false, false]).isEmpty)
                }
            }
        }
    }

    func testTransportAndHotCueUseCurrentDeckPair() {
        let mapping = MX2Mapping()
        XCTAssertEqual(mapping.route(.button(.play(.right), pressed: true),
                                     bank: [.hotcues, .hotcues],
                                     shift: [false, false], jogMode: [false, false]),
                       [OSCMessage(address: "/Syndicate/Deck/2/PlayPause", integer: 1)])
        let message = mapping.route(.button(.pad(.left, 3), pressed: true),
                                    bank: [.hotcues, .hotcues],
                                    shift: [false, false], jogMode: [false, false])
        XCTAssertEqual(message, [OSCMessage(address: "/Syndicate/Deck/1/HotCue",
                                            arguments: [.int(3), .int(1)])])
    }

    func testEncoderShiftAndReleaseRules() {
        let mapping = MX2Mapping()
        XCTAssertEqual(mapping.route(.encoder(.browse(.left), delta: 2),
                                     bank: [.hotcues, .hotcues], shift: [true, false],
                                     jogMode: [false, false]).map(\.address),
                       Array(repeating: "/Syndicate/Browser/Navigation/Right", count: 2))
        XCTAssertTrue(mapping.route(.button(.pad(.left, 1), pressed: false),
                                    bank: [.stems, .stems], shift: [false, false],
                                    jogMode: [false, false]).isEmpty)
    }



    @MainActor
    func testFeedbackUpdatesPlayingStateAndCueColors() {
        let client = MX2FeedbackClient()
        var image: [UInt8] = []
        client.onRGB = { image = $0 }
        client.receivePacket(BridgeCore.OSCMessage(
            address: "/Syndicate/Deck/1/Playing", integer: 1).packet)
        client.receivePacket(BridgeCore.OSCMessage(
            address: "/Syndicate/Deck/1/Cues",
            arguments: (1...8).flatMap { slot in
                [.int(Int32(slot)), .string("Cue \(slot)")]
            }).packet)
        XCTAssertEqual(image[29], 30) // Left deck is playing; right deck stays stopped.
        for pad in 0..<8 { XCTAssertNotEqual(image[20 + pad], 0) }
    }


    func testJogDeltaWrapsAt960() {
        // Left jog absolute position is a little-endian u32 at payload offset 7,
        // which is report index 8 once the report ID is dropped.
        func report(position: UInt32) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 20)
            bytes[0] = 3
            for shift in 0..<4 {
                bytes[8 + shift] = UInt8((position >> (8 * shift)) & 0xFF)
            }
            return bytes
        }

        var decoder = MX2Decoder()
        XCTAssertTrue(decoder.decode(report(position: 952)).isEmpty) // Baselines only.

        // 952 -> 100 is 852 backwards, which is nearer +108 forwards on a 960-tick
        // wheel, so the decoder must report the short way round.
        XCTAssertEqual(decoder.decode(report(position: 100)), [.jog(.left, delta: 108)])
    }

    func testJogDeltaTakesTheShortWayForSmallMoves() {
        func report(position: UInt32) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 20)
            bytes[0] = 3
            for shift in 0..<4 {
                bytes[8 + shift] = UInt8((position >> (8 * shift)) & 0xFF)
            }
            return bytes
        }

        var decoder = MX2Decoder()
        _ = decoder.decode(report(position: 500))
        XCTAssertEqual(decoder.decode(report(position: 501)), [.jog(.left, delta: 1)])
        XCTAssertEqual(decoder.decode(report(position: 500)), [.jog(.left, delta: -1)])
    }
}
