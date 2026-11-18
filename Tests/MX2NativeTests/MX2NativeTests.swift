import XCTest
@testable import MX2Native
import IndirectInputCore
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
    func testIdleFeedbackFrameLeavesUnmappedControlsDark() {
        // With no feedback: unmapped controls and mixer lamps with no route are fully
        // dark. Tracked-but-off state controls (SYNC/MASTER/KEYLOCK) stay dim so a
        // working control is distinguishable from one that was never wired. PLAY and
        // the meters stay dark outright, because lighting them would invent state.
        let client = MX2FeedbackClient()
        let image = client.renderForTesting()
        XCTAssertEqual(image.count, 105)
        XCTAssertEqual(image[30], 0)                                 // Right FX1: unmapped
        XCTAssertEqual(image[43], MX2LEDColor.blue.byte(lit: false)) // Right Sync: dim
        XCTAssertEqual(image[29], 0)                                 // PLAY: unknown
        XCTAssertEqual(image[74], 0)                                 // deck A under-shell
        // Mixer lamps: dark except the headphone Cue pair, which is the only one with
        // real state behind it.
        for id in 61...73 where id != 64 && id != 68 {
            XCTAssertEqual(image[id - 1], 0, "mixer lamp \(id) should be dark")
        }
        XCTAssertEqual(image[64 - 1], MX2LEDColor.white.byte(lit: false))
        XCTAssertEqual(image[68 - 1], MX2LEDColor.white.byte(lit: false))
    }

    @MainActor
    func testHeadphoneCueStateFollowsTheLogicalDeckAcrossAPairChange() {
        // Regression: headphoneCue was keyed by physical side while the mixer routes by
        // deck number. After switching to pair 3/4 the CH3 lamp inverted relative to the
        // button, and CH1/CH2 kept stale values. Nothing covered this because the older
        // test only ever pressed twice within one pair.
        let controller = MX2NativeController()
        var messages: [IndirectInputCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }

        // Cue CH1 on pair 1/2, then move to pair 3/4.
        controller.mapping.firstDeck = 1
        controller.handle(.button(.headphone(.left), pressed: true))
        controller.mapping.firstDeck = 3

        // A fresh press on the left button now addresses CH3 and must read as ON
        // (a toggle from false), not inherit CH1's state.
        messages.removeAll()
        controller.handle(.button(.headphone(.left), pressed: true))
        XCTAssertEqual(messages.map(\.address), ["/Syndicate/Mixer/CH3/Cue"])
        XCTAssertEqual(messages.map(\.integer), [1], "CH3 must start OFF, not inherit CH1")

        // And the right side of the new pair is its own state.
        messages.removeAll()
        controller.handle(.button(.headphone(.right), pressed: true))
        XCTAssertEqual(messages.map(\.address), ["/Syndicate/Mixer/CH4/Cue"])
        XCTAssertEqual(messages.map(\.integer), [1])
    }

    @MainActor
    func testCueAndHeadphoneToggleOnSuccessivePresses() {
        let controller = MX2NativeController()
        var messages: [IndirectInputCore.OSCMessage] = []
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
        var messages: [IndirectInputCore.OSCMessage] = []
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
        var messages: [IndirectInputCore.OSCMessage] = []
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
        var messages: [IndirectInputCore.OSCMessage] = []
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
        var messages: [IndirectInputCore.OSCMessage] = []
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
        var messages: [IndirectInputCore.OSCMessage] = []
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
        let cases: [(MX2Native.MX2Control, MX2PadBank, String, [IndirectInputCore.OSCArgument])] = [
            (.pad(.left, 3), .hotcues, "/Syndicate/Deck/1/HotCue", [.int(3), .int(0)]),
            (.pad(.left, 8), .loops, "/Syndicate/Deck/1/SlipLoop/Four", [.int(0)]),
            (.cue(.left), .hotcues, "/Syndicate/Deck/1/Cue", [.int(0)]),
            (.reverse(.left), .hotcues, "/Syndicate/Deck/1/Reverse", [.int(0)])
        ]
        for (control, bank, address, arguments) in cases {
            let controller = MX2NativeController()
            controller.banks = [bank, .hotcues]
            var messages: [IndirectInputCore.OSCMessage] = []
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
            var messages: [IndirectInputCore.OSCMessage] = []
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
        var messages: [IndirectInputCore.OSCMessage] = []
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
        var messages: [IndirectInputCore.OSCMessage] = []
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
        var messages: [IndirectInputCore.OSCMessage] = []
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
                            let expected: [IndirectInputCore.OSCMessage] = shifted
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
        var messages: [IndirectInputCore.OSCMessage] = []
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
        client.receivePacket(IndirectInputCore.OSCMessage(
            address: "/Syndicate/Deck/1/Playing", integer: 1).packet)
        client.receivePacket(IndirectInputCore.OSCMessage(
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

// MARK: - Consumer-side audit of the MX2 control surface
//
// Contract source: Syndicate 0.3.10 OSC API. Every row cites the table it came from:
//   §14.3 message kinds (Value / Switch / Trigger / Hold / Step / Bend / Index)
//   §14.4 Header · §14.5 Browser · §14.6 track & arrangement decks
//   §14.8 sampler decks · §14.9 mixer
// Cached copy: /Users/ellie/.hermes/cache/web/untitledaudiosyndicate.com-5767e38e75.md
//
// The table is the contract, not a transcript of the implementation: one row per
// MX2Native.MX2Control case and per context variant that changes the wire. A row with no wire is a
// *deliberate* silence, of two kinds:
//   • bridge-local state (shift, pad banks, jog touch, turntable / jog-wheel mode)
//   • no route exists anywhere in §14.4–14.10 (deck FX 1–4, global FX 1–4, PREVIEW,
//     FILTER button, MICROPHONE, crossfader). Those carry `decision:`, so they cannot be
//     "fixed" by inventing an address without also deleting a documented product decision.

/// The OSC message kind, per §14.3. The kind fixes the wire type — int32, float32, or a
/// multi-argument form — so a `.value` row cannot be satisfied by an int, and a `LaneSet`
/// row cannot be satisfied by a single int.
///
/// It does NOT distinguish Trigger from Switch from Hold from Index from Step: §14.3 gives
/// all five a single int32, so on the wire they are identical. Those differences live in
/// press/release behaviour, and are pinned by `testHoldKindsAlwaysRelease`,
/// `testTrackedToggleSwitchesNeverHaveARelease`, and the per-decision tests below.
enum WireKind {
    case trigger(Int32)                  // §14.3 Trigger: any non-zero int, fires once
    case `switch`(Int32)                 // §14.3 Switch: 1 on, 0 off, sets state directly
    case hold(Int32)                     // §14.3 Hold: 1 press, 0 release; always release
    case index(Int32)                    // §14.3 Index: pick from a list, 0-based
    case step(Int32)                     // §14.3 Step: signed amount, 0 does nothing
    case value(Float)                    // §14.3 Value: 0–1 float, or the control's own units
    case cueHold(Int32, Int32)           // §14.6 HotCue: i cue 1–8, i 1 press / 0 release
    case laneSet(Int32, String, Float)   // §14.8 LaneSet: i lane 1–8, s control, f value

    var arguments: [IndirectInputCore.OSCArgument] {
        switch self {
        case let .trigger(v), let .switch(v), let .hold(v), let .index(v), let .step(v):
            return [.int(v)]
        case let .value(v):
            return [.float(v)]
        case let .cueHold(cue, pressed):
            return [.int(cue), .int(pressed)]
        case let .laneSet(lane, control, value):
            return [.int(lane), .string(control), .float(value)]
        }
    }
}

struct Wire {
    let path: String   // without the /Syndicate root
    let kind: WireKind
    var message: IndirectInputCore.OSCMessage { IndirectInputCore.OSCMessage(address: "/Syndicate" + path, arguments: kind.arguments) }
}

func wire(_ path: String, _ kind: WireKind) -> Wire { Wire(path: path, kind: kind) }

/// Everything `MX2Mapping.route` can be steered by, as one value a row can override.
struct AuditContext {
    var firstDeck = 1
    var bank: MX2Native.MX2PadBank = .hotcues
    var shift = false
    var jogMode = false
    var cueActive = false
    var headphoneCue = false
    var pitchPreserve = false
    var cueSlip = false
    var fxEnabled = false
    var browserMode = 0
    var samplerMuted = false
}

final class MX2MappingAuditTests: XCTestCase {
    // MARK: The table

    struct ButtonRow {
        let control: MX2Native.MX2Control
        let pressed: Bool
        var context = AuditContext()
        let doc: String
        let wires: [Wire]
        let note: String
        /// Set only for a pinned product decision: an address that must never be invented.
        var decision: String? = nil
    }

    struct AnalogRow {
        let analog: MX2Native.MX2Analog
        let raw: UInt16
        let doc: String
        let wires: [Wire]
        let note: String
        var decision: String? = nil
    }

    struct EncoderRow {
        let encoder: MX2Native.MX2Encoder
        let delta: Int
        var context = AuditContext()
        let doc: String
        let wires: [Wire]
        let note: String
    }

    // MARK: Deck transport (§14.6)

    static let transportRows: [ButtonRow] = [
        ButtonRow(control: .play(.left), pressed: true, doc: "§14.6 PlayPause Trigger",
                  wires: [wire("/Deck/1/PlayPause", .trigger(1))], note: "press only"),
        ButtonRow(control: .play(.left), pressed: false, doc: "§14.3 Trigger",
                  wires: [], note: "a Trigger has no release"),
        ButtonRow(control: .play(.left), pressed: true, context: AuditContext(shift: true),
                  doc: "§14.6 GridStart Trigger",
                  wires: [wire("/Deck/1/GridStart", .trigger(1))], note: "shift+PLAY is Grid Start"),
        ButtonRow(control: .play(.left), pressed: false, context: AuditContext(shift: true),
                  doc: "§14.3 Trigger", wires: [], note: "no release for Grid Start"),
        ButtonRow(control: .cue(.left), pressed: true, doc: "§14.6 Cue Hold",
                  wires: [wire("/Deck/1/Cue", .hold(1))], note: "deck Cue is Hold, not a toggle"),
        ButtonRow(control: .cue(.left), pressed: false, doc: "§14.6 Cue Hold",
                  wires: [wire("/Deck/1/Cue", .hold(0))], note: "Hold must always send 0 on release"),
        ButtonRow(control: .cue(.left), pressed: true, context: AuditContext(cueActive: true),
                  doc: "§14.6 Cue Hold",
                  wires: [wire("/Deck/1/Cue", .hold(1))], note: "tracked state must not turn it into a Switch"),
        ButtonRow(control: .sync(.left), pressed: true, doc: "§14.6 TempoSync Trigger",
                  wires: [wire("/Deck/1/TempoSync", .trigger(1))], note: "press only"),
        ButtonRow(control: .sync(.left), pressed: false, doc: "§14.3 Trigger", wires: [], note: ""),
        ButtonRow(control: .master(.left), pressed: true, doc: "§14.6 TempoMaster Trigger",
                  wires: [wire("/Deck/1/TempoMaster", .trigger(1))], note: "press only"),
        ButtonRow(control: .master(.left), pressed: false, doc: "§14.3 Trigger", wires: [], note: ""),
        // KEYLOCK / FLUX: Switches fed from tracked state, press-only, and they MUST be
        // able to send 0 — a Switch that only ever sends 1 can never turn the feature off.
        ButtonRow(control: .keyLock(.left), pressed: true, context: AuditContext(pitchPreserve: true),
                  doc: "§14.6 PitchPreserve Switch",
                  wires: [wire("/Deck/1/PitchPreserve", .switch(1))], note: "pressing turned it on"),
        ButtonRow(control: .keyLock(.left), pressed: true, context: AuditContext(pitchPreserve: false),
                  doc: "§14.6 PitchPreserve Switch",
                  wires: [wire("/Deck/1/PitchPreserve", .switch(0))], note: "pressing turned it off"),
        ButtonRow(control: .keyLock(.left), pressed: false, doc: "§14.3 Switch",
                  wires: [], note: "state is pushed by the press, not by the release"),
        ButtonRow(control: .flux(.left), pressed: true, context: AuditContext(cueSlip: true),
                  doc: "§14.6 CueSlip Switch",
                  wires: [wire("/Deck/1/CueSlip", .switch(1))], note: "pressing turned it on"),
        ButtonRow(control: .flux(.left), pressed: true, context: AuditContext(cueSlip: false),
                  doc: "§14.6 CueSlip Switch",
                  wires: [wire("/Deck/1/CueSlip", .switch(0))], note: "pressing turned it off"),
        ButtonRow(control: .flux(.left), pressed: false, doc: "§14.3 Switch",
                  wires: [], note: "state is pushed by the press, not by the release"),
        ButtonRow(control: .reverse(.left), pressed: true, doc: "§14.6 Reverse Switch",
                  wires: [wire("/Deck/1/Reverse", .switch(1))], note: ""),
        ButtonRow(control: .reverse(.left), pressed: false, doc: "§14.6 Reverse Switch",
                  wires: [wire("/Deck/1/Reverse", .switch(0))], note: "momentary: off on release"),
        ButtonRow(control: .turntable(.left), pressed: true, doc: "§14.6 has no jog-mode address",
                  wires: [], note: "local mode flag"),
        ButtonRow(control: .jogMode(.left), pressed: true, doc: "§14.6 has no jog-mode address",
                  wires: [], note: "local mode flag"),
        ButtonRow(control: .shift(.left), pressed: true, doc: "§14.3 has no modifier message",
                  wires: [], note: "local modifier"),
        ButtonRow(control: .jogTouch(.left), pressed: true, doc: "§14.6 has no touch address",
                  wires: [], note: "gates jog routing in the controller, never an OSC action")
    ]

    // MARK: Pads and pad banks (§14.6 HotCue / SetCueLoop / SlipLoop, §14.8 sampler)

    static let padRows: [ButtonRow] = [
        ButtonRow(control: .bank(.left, .hotcues), pressed: true, doc: "§14.5 has no bank selector",
                  wires: [], note: "pad banks are bridge-local"),
        ButtonRow(control: .bank(.left, .loops), pressed: false, doc: "§14.5 has no bank selector",
                  wires: [], note: "a bank release is still local"),
        ButtonRow(control: .pad(.left, 3), pressed: true, doc: "§14.6 HotCue (i cue, i 1/0)",
                  wires: [wire("/Deck/1/HotCue", .cueHold(3, 1))], note: "press-and-hold form"),
        ButtonRow(control: .pad(.left, 3), pressed: false, doc: "§14.6 HotCue (i cue, i 1/0)",
                  wires: [wire("/Deck/1/HotCue", .cueHold(3, 0))], note: "hold must release"),
        ButtonRow(control: .pad(.left, 3), pressed: true, context: AuditContext(shift: true),
                  doc: "§14.6 SetCueLoop (one int, cue 1–8)",
                  wires: [wire("/Deck/1/SetCueLoop", .index(3))], note: "shift+pad launches the cue as a loop"),
        ButtonRow(control: .pad(.left, 3), pressed: false, context: AuditContext(shift: true),
                  doc: "§14.6 SetCueLoop", wires: [], note: "a launch has no release"),
        ButtonRow(control: .pad(.left, 8), pressed: true, context: AuditContext(bank: .loops),
                  doc: "§14.6 SlipLoop/Four Hold",
                  wires: [wire("/Deck/1/SlipLoop/Four", .hold(1))], note: "hold to repeat that bar fraction"),
        ButtonRow(control: .pad(.left, 8), pressed: false, context: AuditContext(bank: .loops),
                  doc: "§14.6 SlipLoop/Four Hold",
                  wires: [wire("/Deck/1/SlipLoop/Four", .hold(0))], note: ""),
        // Stems bank: §14.9 FX macros operate channel inserts, not stems, so there is
        // nothing documented to send. Silence is correct; macros are not a stand-in.
        ButtonRow(control: .pad(.left, 3), pressed: true, context: AuditContext(bank: .stems),
                  doc: "§14.9 has no stem address",
                  wires: [], note: "FX macros are channel insert values, not stems"),
        ButtonRow(control: .pad(.left, 3), pressed: true,
                  context: AuditContext(bank: .stems, shift: true),
                  doc: "§14.9 has no stem address", wires: [], note: "shift does not change that"),
        // Pattern bank: Lane is a zero-based selection Index; LaneSet is one-based and
        // deliberately does not move the selection.
        ButtonRow(control: .pad(.left, 3), pressed: true, context: AuditContext(bank: .pattern),
                  doc: "§14.8 Lane Index 0–7",
                  wires: [wire("/Deck/1/Sampler/Lane", .index(2))], note: "pad 3 → lane index 2"),
        ButtonRow(control: .pad(.left, 3), pressed: false, context: AuditContext(bank: .pattern),
                  doc: "§14.8 Lane Index", wires: [], note: "selection has no release"),
        ButtonRow(control: .pad(.left, 3), pressed: true,
                  context: AuditContext(bank: .pattern, shift: true, samplerMuted: true),
                  doc: "§14.8 LaneSet (i lane 1–8, s control, f value)",
                  wires: [wire("/Deck/1/Sampler/LaneSet", .laneSet(3, "Mute", 1))],
                  note: "one-based lane, Mute is a float; this press muted the lane"),
        ButtonRow(control: .pad(.left, 3), pressed: true,
                  context: AuditContext(bank: .pattern, shift: true, samplerMuted: false),
                  doc: "§14.8 LaneSet",
                  wires: [wire("/Deck/1/Sampler/LaneSet", .laneSet(3, "Mute", 0))],
                  note: "the same pad unmutes a muted lane"),
        ButtonRow(control: .pad(.left, 0), pressed: true, doc: "§14.6/§14.8 indices are 1–8",
                  wires: [], note: "out-of-range pad is dropped in every bank"),
        ButtonRow(control: .pad(.left, 9), pressed: true, doc: "§14.6/§14.8 indices are 1–8",
                  wires: [], note: "out-of-range pad is dropped in every bank")
    ]

    // MARK: Mixer block and centre controls (§14.9, §14.5, §14.4)

    static let mixerRows: [ButtonRow] = [
        // PINNED: the four deck FX buttons are a different physical control from the GFX
        // toggle (they are their own bits, 0–3 per side; the toggle is 62/66). Syndicate
        // exposes exactly ONE insert-chain Switch per channel, and the owner chose the
        // toggle to own it — letting FX 1–4 share it would make two buttons cancel.
        ButtonRow(control: .fxButton(.left, 1), pressed: true, doc: "§14.9 FX is one Switch per channel",
                  wires: [], note: "silent by decision",
                  decision: "deck FX 1–4 send nothing: the channel's one FX Switch belongs to the GFX toggle"),
        ButtonRow(control: .fxButton(.left, 2), pressed: true, doc: "§14.9 FX/Macro is a Value, not a selector",
                  wires: [], note: "silent by decision",
                  decision: "deck FX 1–4 send nothing: macros are continuous Values, not preset selectors"),
        ButtonRow(control: .fxButton(.left, 3), pressed: true, doc: "§14.9 FX/Macro is a Value",
                  wires: [], note: "silent by decision",
                  decision: "deck FX 1–4 send nothing"),
        ButtonRow(control: .fxButton(.left, 4), pressed: false, doc: "§14.9 FX/Macro is a Value",
                  wires: [], note: "silent by decision",
                  decision: "deck FX 1–4 send nothing, press or release"),
        ButtonRow(control: .fxAssign(.left, 1), pressed: true, doc: "§14.9 FX/Macro/1 Value 0–1",
                  wires: [wire("/Mixer/CH1/FX/Macro/1", .value(1))], note: ""),
        ButtonRow(control: .fxAssign(.left, 2), pressed: false, doc: "§14.9 FX/Macro/2 Value",
                  wires: [], note: "no release: a macro is a value push"),
        // PINNED: GFX toggle owns the one insert-chain Switch, keyed by tracked state so
        // it can also turn the chain back off, and it never bypasses on release.
        ButtonRow(control: .channelFX(.left), pressed: true, context: AuditContext(fxEnabled: true),
                  doc: "§14.9 FX Switch",
                  wires: [wire("/Mixer/CH1/FX", .switch(1))], note: "pressing turned the chain on"),
        ButtonRow(control: .channelFX(.left), pressed: true, context: AuditContext(fxEnabled: false),
                  doc: "§14.9 FX Switch",
                  wires: [wire("/Mixer/CH1/FX", .switch(0))], note: "pressing bypassed the chain"),
        ButtonRow(control: .channelFX(.left), pressed: false, doc: "§14.3 Switch",
                  wires: [], note: "releasing the button must not bypass the chain"),
        // PINNED: headphone Cue is a toggle (Switch); deck Cue is Hold. Two different things.
        ButtonRow(control: .headphone(.left), pressed: true, context: AuditContext(headphoneCue: true),
                  doc: "§14.9 Mixer Cue Switch",
                  wires: [wire("/Mixer/CH1/Cue", .switch(1))], note: "toggled on"),
        ButtonRow(control: .headphone(.left), pressed: true, context: AuditContext(headphoneCue: false),
                  doc: "§14.9 Mixer Cue Switch",
                  wires: [wire("/Mixer/CH1/Cue", .switch(0))], note: "toggled off"),
        ButtonRow(control: .headphone(.left), pressed: false, doc: "§14.3 Switch",
                  wires: [], note: "a toggle has no release"),
        // PINNED: global FX 1–4 are preset selectors on the hardware; the OSC surface has
        // no preset selector at all, so there is nothing honest to send.
        ButtonRow(control: .globalFX(1), pressed: true, doc: "§14.9 FX/Macro is a Value",
                  wires: [], note: "silent by decision",
                  decision: "global FX 1–4 send nothing: macros are continuous Values, not preset selectors"),
        ButtonRow(control: .globalFX(3), pressed: true, doc: "§14.9 no preset route",
                  wires: [], note: "silent by decision",
                  decision: "global FX 1–4 send nothing"),
        // PINNED: the centre FILTER button is audio-only. Filter1 is a bipolar 0–1 Value,
        // so 0.5 means "no change" — re-centring the filter on every press is a different
        // feature, not a route for this button.
        ButtonRow(control: .filter, pressed: true, doc: "§14.9 Filter1 is a Value 0–1",
                  wires: [], note: "silent by decision",
                  decision: "FILTER button sends nothing: audio-only control, no button route in 0.3.10"),
        ButtonRow(control: .microphone, pressed: true, doc: "§14.4–14.10 have no mic route",
                  wires: [], note: "silent by decision",
                  decision: "MICROPHONE sends nothing: no OSC route exists"),
        // Browser column (§14.5) and header (§14.4).
        ButtonRow(control: .favorite(.left), pressed: true, doc: "§14.5 Left Trigger",
                  wires: [wire("/Browser/Navigation/Left", .trigger(1))],
                  note: "Navigation/ is a documented alias of Browser/Left"),
        ButtonRow(control: .addToList(.left), pressed: true, doc: "§14.5 Enter Trigger",
                  wires: [wire("/Browser/Navigation/Enter", .trigger(1))],
                  note: "Navigation/ is a documented alias of Browser/Enter"),
        // PINNED: /Browser/Preview does not exist in 0.3.10 (§14.5 lists only navigation,
        // Enter, Back and L1–L4). The preview deck is not addressable, so nothing is sent.
        ButtonRow(control: .preview(.left), pressed: true, doc: "§14.5 has no preview route",
                  wires: [], note: "silent by decision",
                  decision: "PREVIEW sends nothing: /Browser/Preview does not exist in 0.3.10"),
        ButtonRow(control: .view(.left), pressed: true, doc: "§14.4 Browser Index 0/1/2",
                  wires: [wire("/Header/Browser", .index(0))], note: "0 hidden"),
        ButtonRow(control: .view(.left), pressed: true, context: AuditContext(browserMode: 2),
                  doc: "§14.4 Browser Index 0/1/2",
                  wires: [wire("/Header/Browser", .index(2))], note: "2 detached window"),
        ButtonRow(control: .view(.left), pressed: false, doc: "§14.3 Index",
                  wires: [], note: "an Index is not a press/release pair"),
        ButtonRow(control: .browsePress(.left), pressed: true, doc: "§14.5 L1–L4 Trigger",
                  wires: [wire("/Browser/L1", .trigger(1))], note: "loads onto the side's deck"),
        ButtonRow(control: .movePress(.left), pressed: true, doc: "§14.6 LoopIn Trigger",
                  wires: [wire("/Deck/1/LoopIn", .trigger(1))], note: "loop-move encoder push"),
        ButtonRow(control: .sizePress(.left), pressed: true, doc: "§14.6 Loop Trigger",
                  wires: [wire("/Deck/1/Loop", .trigger(1))], note: "loop-size encoder push")
    ]

    // MARK: Analog surface (26 slots) — §14.4 header, §14.6 tempo, §14.9 mixer

    static let analogRows: [AnalogRow] = [
        AnalogRow(analog: .fxKnob(.left, 1), raw: 4095, doc: "§14.9 FX/Macro/1 Value",
                  wires: [wire("/Mixer/CH1/FX/Macro/1", .value(1))], note: "insert macro, 0–1"),
        AnalogRow(analog: .fxKnob(.left, 2), raw: 4095, doc: "§14.9 FX/Macro/2 Value",
                  wires: [wire("/Mixer/CH1/FX/Macro/2", .value(1))], note: ""),
        AnalogRow(analog: .fxKnob(.left, 3), raw: 4095, doc: "§14.9 FX/Macro/3 Value",
                  wires: [wire("/Mixer/CH1/FX/Macro/3", .value(1))], note: ""),
        AnalogRow(analog: .fxKnob(.left, 4), raw: 4095, doc: "§14.9 FX/Macro/4 Value",
                  wires: [wire("/Mixer/CH1/FX/Macro/4", .value(1))], note: ""),
        AnalogRow(analog: .gain(.left), raw: 4095, doc: "§14.9 Trim Value (0.5 = 0 dB)",
                  wires: [wire("/Mixer/CH1/Trim", .value(1))], note: "0 = −6 dB, 1 = +6 dB"),
        AnalogRow(analog: .eqHigh(.left), raw: 4095, doc: "§14.9 EQ/High Value",
                  wires: [wire("/Mixer/CH1/EQ/High", .value(1))], note: "0.5 neutral"),
        AnalogRow(analog: .eqMid(.left), raw: 4095, doc: "§14.9 EQ/Mid Value",
                  wires: [wire("/Mixer/CH1/EQ/Mid", .value(1))], note: "0.5 neutral"),
        AnalogRow(analog: .eqLow(.left), raw: 4095, doc: "§14.9 EQ/Low Value",
                  wires: [wire("/Mixer/CH1/EQ/Low", .value(1))], note: "0.5 neutral"),
        AnalogRow(analog: .channelFX(.left), raw: 4095, doc: "§14.9 Filter1 Value",
                  wires: [wire("/Mixer/CH1/Filter1", .value(1))], note: "detent at 0.5, bipolar filter"),
        AnalogRow(analog: .mainVolume, raw: 4095, doc: "§14.4 MasterVolume Value 0–1",
                  wires: [wire("/Header/MasterVolume", .value(1))], note: ""),
        AnalogRow(analog: .cueMix, raw: 4095, doc: "§14.4 CueMix Value 0–1",
                  wires: [wire("/Header/CueMix", .value(1))], note: "Cue-to-Master blend"),
        AnalogRow(analog: .cueVolume, raw: 4095, doc: "§14.4 CueVolume Value 0–1",
                  wires: [wire("/Header/CueVolume", .value(1))], note: ""),
        AnalogRow(analog: .volume(.left), raw: 4095, doc: "§14.9 Volume Value 0–1",
                  wires: [wire("/Mixer/CH1/Volume", .value(1))],
                  note: "ignored by the app while the fader is locked, which is its business"),
        AnalogRow(analog: .tempo(.left), raw: 4095, doc: "§14.6 TempoSlider Value −1…+1",
                  wires: [wire("/Deck/1/TempoSlider", .value(1))], note: "top of fader = +1"),
        AnalogRow(analog: .tempo(.left), raw: 0, doc: "§14.6 TempoSlider Value −1…+1",
                  wires: [wire("/Deck/1/TempoSlider", .value(-1))], note: "bottom of fader = −1"),
        // PINNED: no OSC crossfader route exists in 0.3.10 (§14.9 lists none; §7.3 describes
        // a mouse/MIDI control only). Emulating it by writing channel volumes fights the
        // app's own crossfader lock, which then overrides and lurches the faders.
        AnalogRow(analog: .crossfader, raw: 2048, doc: "§14.9 has no crossfader address",
                  wires: [], note: "silent by decision",
                  decision: "crossfader sends nothing and is never emulated with channel volumes")
    ]

    // MARK: Encoders (6 slots) — §14.5 navigation, §14.6 skip and loop

    static let encoderRows: [EncoderRow] = [
        EncoderRow(encoder: .browse(.left), delta: 2, doc: "§14.5 Down Trigger",
                   wires: [wire("/Browser/Navigation/Down", .trigger(1)),
                           wire("/Browser/Navigation/Down", .trigger(1))],
                   note: "one Trigger per detent, unshifted is vertical"),
        EncoderRow(encoder: .browse(.left), delta: -1, doc: "§14.5 Up Trigger",
                   wires: [wire("/Browser/Navigation/Up", .trigger(1))], note: "negative is Up"),
        EncoderRow(encoder: .browse(.left), delta: 2, context: AuditContext(shift: true),
                   doc: "§14.5 Right Trigger",
                   wires: [wire("/Browser/Navigation/Right", .trigger(1)),
                           wire("/Browser/Navigation/Right", .trigger(1))],
                   note: "shift switches tree ↔ list"),
        EncoderRow(encoder: .move(.left), delta: -4, doc: "§14.6 BeatSkip Step",
                   wires: [wire("/Deck/1/BeatSkip", .step(-4))],
                   note: "signed amount, one message not four"),
        EncoderRow(encoder: .size(.left), delta: 3, doc: "§14.6 LoopOut Trigger",
                   wires: [wire("/Deck/1/LoopOut", .trigger(1)),
                           wire("/Deck/1/LoopOut", .trigger(1)),
                           wire("/Deck/1/LoopOut", .trigger(1))],
                   note: "one detent = one OUT step"),
        EncoderRow(encoder: .size(.left), delta: -2, doc: "§14.6 LoopIn Trigger",
                   wires: [wire("/Deck/1/LoopIn", .trigger(1)),
                           wire("/Deck/1/LoopIn", .trigger(1))],
                   note: "negative is IN"),
        EncoderRow(encoder: .size(.left), delta: 5, context: AuditContext(shift: true),
                   doc: "§14.6 LoopMoveBeat Step",
                   wires: [wire("/Deck/1/LoopMoveBeat", .step(5))],
                   note: "shift moves the active loop instead of resizing it")
    ]

    static let buttonRows: [ButtonRow] = transportRows + padRows + mixerRows

    // MARK: Routing under an audit context

    func route(_ event: MX2Native.MX2InputEvent, _ context: AuditContext) -> [IndirectInputCore.OSCMessage] {
        let decks = 1...4
        let pads = 1...8
        var mapping = MX2Mapping()
        mapping.firstDeck = context.firstDeck
        return mapping.route(
            event,
            bank: [context.bank, context.bank],
            shift: [context.shift, context.shift],
            jogMode: [context.jogMode, context.jogMode],
            cueActive: Dictionary(uniqueKeysWithValues: decks.map { ($0, context.cueActive) }),
            headphoneCue: Dictionary(uniqueKeysWithValues: decks.map { ($0, context.headphoneCue) }),
            pitchPreserve: Dictionary(uniqueKeysWithValues: decks.map { ($0, context.pitchPreserve) }),
            cueSlip: Dictionary(uniqueKeysWithValues: decks.map { ($0, context.cueSlip) }),
            fxEnabled: Dictionary(uniqueKeysWithValues: decks.map { ($0, context.fxEnabled) }),
            browserMode: context.browserMode,
            samplerMute: Dictionary(uniqueKeysWithValues: decks.map { deck in
                (deck, Dictionary(uniqueKeysWithValues: pads.map { ($0, context.samplerMuted) }))
            })
        )
    }

    // MARK: The audit

    /// Every row in the table, asserted against the mapper. This is the whole surface:
    /// scanning the three tables above is scanning every control the MX2 has.
    func testEveryControlMatchesItsDocumentedOSCContract() {
        XCTAssertEqual(Self.buttonRows.count, 64, "row count is part of the contract")
        for row in Self.buttonRows {
            let actual = route(.button(row.control, pressed: row.pressed), row.context)
            XCTAssertEqual(actual, row.wires.map(\.message),
                           "\(describe(row.control)) pressed=\(row.pressed) — \(row.doc) (\(row.note))")
        }
        XCTAssertEqual(Self.analogRows.count, 16, "row count is part of the contract")
        for row in Self.analogRows {
            let actual = route(.analog(row.analog, value: row.raw), AuditContext())
            XCTAssertEqual(actual, row.wires.map(\.message),
                           "\(describe(row.analog)) raw=\(row.raw) — \(row.doc) (\(row.note))")
        }
        XCTAssertEqual(Self.encoderRows.count, 7, "row count is part of the contract")
        for row in Self.encoderRows {
            let actual = route(.encoder(row.encoder, delta: row.delta), row.context)
            XCTAssertEqual(actual, row.wires.map(\.message),
                           "\(describe(row.encoder)) delta=\(row.delta) — \(row.doc) (\(row.note))")
        }
    }

    /// One address has exactly one kind. This is what stops a Hold being silently relabelled
    /// a Switch: both are int32 on the wire, so the table would otherwise still "pass" while
    /// the pair of messages that makes a Hold a Hold quietly went missing.
    func testEveryAddressUsesExactlyOneWireKind() {
        let allWires = Self.buttonRows.flatMap(\.wires) + Self.analogRows.flatMap(\.wires)
            + Self.encoderRows.flatMap(\.wires)
        var kindsByPath: [String: Set<String>] = [:]
        for oneWire in allWires {
            kindsByPath[oneWire.path, default: []].insert(kindLabel(oneWire.kind))
        }
        XCTAssertFalse(kindsByPath.isEmpty)
        for (path, kinds) in kindsByPath {
            XCTAssertEqual(kinds.count, 1,
                           "\(path) is given more than one OSC kind: \(kinds.sorted())")
        }
    }

    /// §14.3: a Hold "stays active until you send 0. Always send the release." Every Hold
    /// address in the table must therefore have both its press and its release pinned.
    func testHoldKindsAlwaysRelease() {
        let holds = (Self.buttonRows.flatMap(\.wires)).filter {
            if case .hold = $0.kind { return true } else { return false }
        }
        XCTAssertFalse(holds.isEmpty, "the surface has Hold controls")
        for hold in holds {
            XCTAssertTrue(Self.buttonRows.contains { row in
                row.pressed == false && row.wires.contains { other in
                    other.path == hold.path && kindLabel(other.kind) == "hold"
                }
            }, "\(hold.path) is a Hold with no pinned release")
        }
    }

    /// §14.3: a Switch "sets the state directly", so a *toggle* driven by tracked state must
    /// not also emit on release — that would set the state back. `Reverse` is the documented
    /// exception: §14.6 types it a Switch, and it is momentary, so 1 on press / 0 on release
    /// is exactly "set the state directly" and is pinned in the table above.
    func testTrackedToggleSwitchesNeverHaveARelease() {
        let toggles = ["/Deck/1/PitchPreserve", "/Deck/1/CueSlip",
                       "/Mixer/CH1/FX", "/Mixer/CH1/Cue"]
        for path in toggles {
            XCTAssertTrue(Self.buttonRows.contains { row in
                row.pressed && row.wires.contains { $0.path == path }
            }, "\(path) should be covered by the table")
            XCTAssertFalse(Self.buttonRows.contains { row in
                !row.pressed && row.wires.contains { $0.path == path }
            }, "\(path) is a state-driven toggle and must not have a release row")
        }
        // Reverse is the deliberate momentary exception; if this row ever disappears the
        // exception was silently dropped rather than decided.
        XCTAssertTrue(Self.buttonRows.contains { row in
            !row.pressed && row.wires.contains {
                $0.path == "/Deck/1/Reverse" && kindLabel($0.kind) == "switch"
            }
        }, "Reverse is a momentary Switch: it must still release to 0")
    }

    func kindLabel(_ kind: WireKind) -> String {
        switch kind {
        case .trigger: return "trigger"
        case .switch: return "switch"
        case .hold: return "hold"
        case .index: return "index"
        case .step: return "step"
        case .value: return "value"
        case .cueHold: return "cueHold"
        case .laneSet: return "laneSet"
        }
    }

    /// The pinned silences, stated as their own test so a future "fix" has to argue with a
    /// named decision rather than quietly add an address.
    func testPinnedSilencesStaySilent() {
        let pinnedControls = Self.buttonRows.filter { $0.decision != nil }
        XCTAssertEqual(Set(pinnedControls.map { caseName($0.control) }),
                       ["fxButton", "globalFX", "preview", "filter", "microphone"],
                       "each pinned button decision must stay represented")
        for row in pinnedControls {
            XCTAssertTrue(row.wires.isEmpty, "\(describe(row.control)) — \(row.decision ?? "")")
            XCTAssertEqual(route(.button(row.control, pressed: row.pressed), row.context), [],
                           row.decision ?? "")
        }

        let pinnedAnalogs = Self.analogRows.filter { $0.decision != nil }
        XCTAssertEqual(Set(pinnedAnalogs.map { caseName($0.analog) }), ["crossfader"])
        for row in pinnedAnalogs {
            XCTAssertEqual(route(.analog(row.analog, value: 2048), AuditContext()), [],
                           row.decision ?? "")
        }
    }

    /// All four deck FX buttons, both sides, both pairs, press and release: silence.
    func testDeckFXButtonsSendNothingOnEitherSideOrDeckPair() {
        for firstDeck in [1, 3] {
            for side in [MX2Native.MX2Side.left, .right] {
                for index in 1...4 {
                    for pressed in [true, false] {
                        let context = AuditContext(firstDeck: firstDeck)
                        XCTAssertEqual(route(.button(.fxButton(side, index), pressed: pressed), context), [],
                                       "deck FX \(index) \(side) must never touch the channel FX Switch")
                    }
                }
            }
        }
    }

    /// Global FX 1–4 likewise: nothing, anywhere.
    func testGlobalFXPresetsSendNothingOnEitherDeckPair() {
        for firstDeck in [1, 3] {
            for index in 1...4 {
                for pressed in [true, false] {
                    let context = AuditContext(firstDeck: firstDeck)
                    XCTAssertEqual(route(.button(.globalFX(index), pressed: pressed), context), [])
                }
            }
        }
    }

    /// The crossfader must never be faked with channel volumes, at any position — that is
    /// what makes it worth a sweep rather than a single row.
    func testCrossfaderSweepNeverTouchesChannelVolumes() {
        for raw in [UInt16(0), 512, 1024, 2048, 3072, 4095] {
            XCTAssertEqual(route(.analog(.crossfader, value: raw), AuditContext()), [],
                           "crossfader at raw \(raw) must not write channel Volume")
        }
    }

    /// KEYLOCK and FLUX are Switches driven by tracked state, press-only. Asserted through
    /// the controller, because what matters is the second press: it must send 0. A Switch
    /// that can only ever send 1 leaves the feature stuck on with no way back.
    @MainActor
    func testKeyLockAndFluxAreTrackedSwitchesThatCanTurnOff() async {
        let controller = MX2NativeController()
        var messages: [IndirectInputCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        for (control, path) in [(MX2Control.keyLock(.left), "/Syndicate/Deck/1/PitchPreserve"),
                                (MX2Control.flux(.left), "/Syndicate/Deck/1/CueSlip")] {
            messages.removeAll()
            controller.handle(.button(control, pressed: true))
            controller.handle(.button(control, pressed: false))
            controller.handle(.button(control, pressed: true))
            controller.handle(.button(control, pressed: false))
            XCTAssertEqual(messages, [1, 0].map {
                IndirectInputCore.OSCMessage(address: path, integer: $0)
            }, "\(describe(control)) must turn on then off, and never on release")
        }
    }

    /// The same at the mapping layer: it mirrors whatever state it is handed, and both
    /// values are reachable. (The press-only rule is the controller's, above.)
    func testTrackedSwitchesMirrorBothStatesThroughTheMapper() {
        for (control, path, key) in [
            (MX2Control.keyLock(.left), "/Deck/1/PitchPreserve", true),
            (MX2Control.flux(.left), "/Deck/1/CueSlip", false)
        ] {
            let on = key
                ? AuditContext(pitchPreserve: true)
                : AuditContext(cueSlip: true)
            let off = key
                ? AuditContext(pitchPreserve: false)
                : AuditContext(cueSlip: false)
            XCTAssertEqual(route(.button(control, pressed: true), on),
                           [IndirectInputCore.OSCMessage(address: "/Syndicate" + path, integer: 1)])
            XCTAssertEqual(route(.button(control, pressed: true), off),
                           [IndirectInputCore.OSCMessage(address: "/Syndicate" + path, integer: 0)])
            XCTAssertEqual(route(.button(control, pressed: false), on), [],
                           "a Switch is pushed by the press, never by the release")
        }
    }

    /// Deck Cue is Hold; headphone Cue is a Switch. Pinned side by side because they look
    /// alike on the hardware and are the pair most likely to be "unified" by mistake.
    func testDeckCueIsHoldWhileHeadphoneCueIsASwitch() {
        for side in [MX2Native.MX2Side.left, .right] {
            let deck = 1 + side.rawValue
            XCTAssertEqual(route(.button(.cue(side), pressed: true), AuditContext()),
                           [IndirectInputCore.OSCMessage(address: "/Syndicate/Deck/\(deck)/Cue", integer: 1)],
                           "deck Cue is Hold: press sends 1")
            XCTAssertEqual(route(.button(.cue(side), pressed: false), AuditContext()),
                           [IndirectInputCore.OSCMessage(address: "/Syndicate/Deck/\(deck)/Cue", integer: 0)],
                           "deck Cue is Hold and must always release")
            XCTAssertEqual(route(.button(.headphone(side), pressed: true),
                                 AuditContext(headphoneCue: true)),
                           [IndirectInputCore.OSCMessage(address: "/Syndicate/Mixer/CH\(deck)/Cue", integer: 1)],
                           "headphone Cue is a Switch: this press turned it on")
            XCTAssertEqual(route(.button(.headphone(side), pressed: true),
                                 AuditContext(headphoneCue: false)),
                           [IndirectInputCore.OSCMessage(address: "/Syndicate/Mixer/CH\(deck)/Cue", integer: 0)],
                           "headphone Cue is a Switch: this press turned it off")
            XCTAssertEqual(route(.button(.headphone(side), pressed: false), AuditContext()), [],
                           "a Switch has no release message")
        }
    }

    /// No side-typed control may ever address a deck other than `mapping.deck(side)`. This
    /// is the failure mode the hardware cannot catch: the address is well-formed but wrong.
    func testSideTypedControlsOnlyAddressTheirOwnDeck() {
        let cases: [(String, (MX2Native.MX2Side) -> MX2Native.MX2InputEvent, AuditContext)] = [
            ("play", { .button(.play($0), pressed: true) }, AuditContext()),
            ("play+shift", { .button(.play($0), pressed: true) }, AuditContext(shift: true)),
            ("cue", { .button(.cue($0), pressed: true) }, AuditContext()),
            ("sync", { .button(.sync($0), pressed: true) }, AuditContext()),
            ("master", { .button(.master($0), pressed: true) }, AuditContext()),
            ("keyLock", { .button(.keyLock($0), pressed: true) }, AuditContext()),
            ("flux", { .button(.flux($0), pressed: true) }, AuditContext()),
            ("reverse", { .button(.reverse($0), pressed: true) }, AuditContext()),
            ("pad hotcues", { .button(.pad($0, 4), pressed: true) }, AuditContext()),
            ("pad hotcues+shift", { .button(.pad($0, 4), pressed: true) }, AuditContext(shift: true)),
            ("pad loops", { .button(.pad($0, 4), pressed: true) }, AuditContext(bank: .loops)),
            ("pad pattern", { .button(.pad($0, 4), pressed: true) }, AuditContext(bank: .pattern)),
            ("pad pattern+shift", { .button(.pad($0, 4), pressed: true) },
             AuditContext(bank: .pattern, shift: true)),
            ("fxAssign", { .button(.fxAssign($0, 1), pressed: true) }, AuditContext()),
            ("channelFX", { .button(.channelFX($0), pressed: true) }, AuditContext()),
            ("headphone", { .button(.headphone($0), pressed: true) }, AuditContext()),
            ("browsePress", { .button(.browsePress($0), pressed: true) }, AuditContext()),
            ("movePress", { .button(.movePress($0), pressed: true) }, AuditContext()),
            ("sizePress", { .button(.sizePress($0), pressed: true) }, AuditContext()),
            ("moveEncoder", { .encoder(.move($0), delta: 1) }, AuditContext()),
            ("sizeEncoder", { .encoder(.size($0), delta: 1) }, AuditContext()),
            ("sizeEncoder+shift", { .encoder(.size($0), delta: 1) }, AuditContext(shift: true)),
            ("gain", { .analog(.gain($0), value: 4095) }, AuditContext()),
            ("eqHigh", { .analog(.eqHigh($0), value: 4095) }, AuditContext()),
            ("eqMid", { .analog(.eqMid($0), value: 4095) }, AuditContext()),
            ("eqLow", { .analog(.eqLow($0), value: 4095) }, AuditContext()),
            ("channelFilter", { .analog(.channelFX($0), value: 4095) }, AuditContext()),
            ("volume", { .analog(.volume($0), value: 4095) }, AuditContext()),
            ("tempo", { .analog(.tempo($0), value: 4095) }, AuditContext()),
            ("fxKnob 1", { .analog(.fxKnob($0, 1), value: 4095) }, AuditContext()),
            ("fxKnob 4", { .analog(.fxKnob($0, 4), value: 4095) }, AuditContext())
        ]
        for (name, event, base) in cases {
            for side in [MX2Native.MX2Side.left, .right] {
                for firstDeck in [1, 3] {
                    let deck = firstDeck + side.rawValue
                    var context = base
                    context.firstDeck = firstDeck
                    let messages = route(event(side), context)
                    XCTAssertFalse(messages.isEmpty, "\(name)/\(side) should send something")
                    for message in messages {
                        if let referenced = deckReference(in: message.address) {
                            XCTAssertEqual(referenced, deck,
                                           "\(name)/\(side.rawValue) at firstDeck \(firstDeck) addressed deck \(referenced) in \(message.address)")
                        }
                    }
                    XCTAssertTrue(messages.contains { deckReference(in: $0.address) != nil },
                                  "\(name)/\(side.rawValue) must address a deck, not just a global")
                }
            }
        }
    }

    // MARK: Exhaustiveness and count guards

    /// Every enum case and every decoder slot is covered by the tables, so a new case or a
    /// shifted slot fails here instead of shipping unlisted. `caseName` is an exhaustive
    /// switch: adding a case to any of the three enums stops this file compiling.
    func testEveryEnumCaseAndDecoderSlotIsAudited() {
        let buttonSlots = (0..<82).compactMap(control(atBit:))
        XCTAssertEqual(buttonSlots.count, 82, "report 1 carries 82 button bits")
        XCTAssertEqual(Set(buttonSlots.map { caseName($0) }).count, 27, "the MX2Native.MX2Control enum has 27 cases")
        XCTAssertEqual(Dictionary(grouping: buttonSlots.map { caseName($0) }, by: { $0 }).mapValues(\.count),
                       ["fxButton": 8, "favorite": 2, "addToList": 2, "preview": 2, "view": 2,
                        "flux": 2, "reverse": 2, "turntable": 2, "jogMode": 2, "shift": 2,
                        "sync": 2, "master": 2, "keyLock": 2, "bank": 8, "pad": 16,
                        "cue": 2, "play": 2, "fxAssign": 4, "channelFX": 2, "headphone": 2,
                        "globalFX": 4, "filter": 1, "microphone": 1,
                        "browsePress": 2, "movePress": 2, "sizePress": 2, "jogTouch": 2],
                       "the 82-bit table is part of the contract")

        let analogSlots = (0..<26).compactMap(analog(atIndex:))
        XCTAssertEqual(analogSlots.count, 26, "report 2 carries 26 analog axes")
        XCTAssertEqual(Set(analogSlots.map { caseName($0) }), Set(Self.analogRows.map { caseName($0.analog) }),
                       "every analog axis the decoder can report must be in the audit table")

        let encoderSlots = (0..<6).compactMap(encoder(atIndex:))
        XCTAssertEqual(encoderSlots.count, 6, "report 1 carries 6 four-bit encoders")
        XCTAssertEqual(Set(encoderSlots.map { caseName($0) }), Set(Self.encoderRows.map { caseName($0.encoder) }),
                       "every encoder the decoder can report must be in the audit table")

        XCTAssertEqual(Set(Self.buttonRows.map { caseName($0.control) }), Set(buttonSlots.map { caseName($0) }),
                       "every button case the decoder can report must be in the audit table")
    }

    /// The positions confirmed on hardware, pinned so a reordered table is caught. Everything
    /// here matches docs/mx2-native-protocol.md; the 67 unconfirmed bits stay unpinned.
    func testHardwareVerifiedBitPositionsMapToTheDocumentedControls() {
        let verified: [(Int, MX2Native.MX2Control)] = [
            (16, .bank(.left, .hotcues)), (17, .bank(.left, .stems)),
            (18, .bank(.left, .pattern)), (19, .bank(.left, .loops)),
            (20, .pad(.left, 1)), (21, .pad(.left, 2)), (22, .pad(.left, 3)),
            (54, .pad(.right, 5)),
            (60, .fxAssign(.left, 1)), (61, .fxAssign(.left, 2)), (62, .channelFX(.left)),
            (64, .fxAssign(.right, 1)), (65, .fxAssign(.right, 2)),
            (68, .globalFX(1)), (69, .globalFX(2)),
            (72, .filter),
            (80, .jogTouch(.left)), (81, .jogTouch(.right))
        ]
        for (bit, expected) in verified {
            XCTAssertEqual(control(atBit: bit), expected, "bit \(bit) must stay \(describe(expected))")
        }
    }

    /// The GFX toggle and the deck FX buttons are different bits. If a future table edit
    /// collapsed them, the "FX 1–4 are silent" decision would silently become "FX 1–4
    /// bypass the channel", which is exactly the double-cancel bug this pins shut.
    func testDeckFXButtonsAndTheGFXToggleOccupyDifferentBits() {
        XCTAssertEqual(control(atBit: 62), .channelFX(.left))
        XCTAssertEqual(control(atBit: 66), .channelFX(.right))
        let fxBits = (60...61).compactMap(control(atBit:)) + (64...65).compactMap(control(atBit:))
        XCTAssertEqual(fxBits, [.fxAssign(.left, 1), .fxAssign(.left, 2),
                                .fxAssign(.right, 1), .fxAssign(.right, 2)])
        for bit in [60, 61, 64, 65] {
            XCTAssertNotEqual(caseName(control(atBit: bit) ?? .filter), "channelFX",
                              "bit \(bit) belongs to the FX assign buttons, not the channel FX toggle")
        }
    }

    // MARK: Value scaling

    /// The two affine maps on the analog surface, where an off-by-one is inaudible in a
    /// smoke test but wrong: raw/4095 for 0–1 Values, and raw/4095*2−1 for TempoSlider.
    func testAnalogScalingIs12BitAndTempoIsBipolar() {
        for raw in [UInt16(0), 1024, 2048, 4095] {
            XCTAssertEqual(route(.analog(.volume(.left), value: raw), AuditContext()),
                           [IndirectInputCore.OSCMessage(address: "/Syndicate/Mixer/CH1/Volume",
                                       float: Float(raw) / 4095)])
            let tempo = route(.analog(.tempo(.left), value: raw), AuditContext())
            XCTAssertEqual(tempo, [IndirectInputCore.OSCMessage(address: "/Syndicate/Deck/1/TempoSlider",
                                              float: Float(raw) / 4095 * 2 - 1)])
            XCTAssertEqual(tempo.first?.arguments.first, .float(Float(raw) / 4095 * 2 - 1),
                           "TempoSlider must be a float in −1…+1, not a 0…1 Value")
        }
    }

    /// Every emitted address must live under the documented root and exist in a table this
    /// audit cites. A dead address is the one failure the app cannot report: it just never
    /// does anything.
    func testEveryEmittedAddressIsDocumented() {
        var documented: Set<String> = []
        // §14.4 Header
        documented.formUnion(["/Header/Browser", "/Header/MasterVolume", "/Header/CueMix",
                              "/Header/CueVolume"])
        // §14.5 Browser
        documented.formUnion(["/Browser/Up", "/Browser/Down", "/Browser/Left", "/Browser/Right",
                              "/Browser/Enter", "/Browser/Back", "/Browser/Navigation/Up",
                              "/Browser/Navigation/Down", "/Browser/Navigation/Left",
                              "/Browser/Navigation/Right", "/Browser/Navigation/Enter",
                              "/Browser/Navigation/Back"])
        documented.formUnion((1...4).map { "/Browser/L\($0)" })
        // §14.6 track decks
        let deckSuffixes = ["PlayPause", "GridStart", "Cue", "HotCue", "SetCueLoop", "TempoSync",
                            "TempoMaster", "TempoSlider", "Reverse", "PitchPreserve", "CueSlip",
                            "Loop", "LoopIn", "LoopOut", "BeatSkip", "LoopMoveBeat",
                            "SlipLoop/ThirtySecond", "SlipLoop/Sixteenth", "SlipLoop/Eighth",
                            "SlipLoop/Quarter", "SlipLoop/Half", "SlipLoop/One",
                            "SlipLoop/Two", "SlipLoop/Four"]
        for deck in 1...4 { for suffix in deckSuffixes { documented.insert("/Deck/\(deck)/\(suffix)") } }
        // §14.8 sampler decks
        for deck in 1...4 {
            documented.insert("/Deck/\(deck)/Sampler/Lane")
            documented.insert("/Deck/\(deck)/Sampler/LaneSet")
        }
        // §14.9 mixer
        for channel in 1...4 {
            for suffix in ["Volume", "Trim", "EQ/High", "EQ/Mid", "EQ/Low", "Filter1", "FX", "Cue"] {
                documented.insert("/Mixer/CH\(channel)/\(suffix)")
            }
            for macro in 1...8 { documented.insert("/Mixer/CH\(channel)/FX/Macro/\(macro)") }
        }

        let contexts = [AuditContext(), AuditContext(bank: .pattern, shift: true),
                        AuditContext(bank: .loops), AuditContext(firstDeck: 3, fxEnabled: true),
                        AuditContext(headphoneCue: true, pitchPreserve: true, cueSlip: true,
                                     browserMode: 2, samplerMuted: true)]
        var emitted = Set<String>()
        for row in Self.buttonRows {
            for context in contexts {
                var merged = context
                if row.decision == nil { merged.bank = row.context.bank }
                for message in route(.button(row.control, pressed: row.pressed), merged) {
                    emitted.insert(String(message.address.dropFirst("/Syndicate".count)))
                }
            }
        }
        for row in Self.analogRows {
            for message in route(.analog(row.analog, value: row.raw), AuditContext()) {
                emitted.insert(String(message.address.dropFirst("/Syndicate".count)))
            }
        }
        for row in Self.encoderRows {
            for message in route(.encoder(row.encoder, delta: row.delta), AuditContext(shift: false)) {
                emitted.insert(String(message.address.dropFirst("/Syndicate".count)))
            }
            for message in route(.encoder(row.encoder, delta: row.delta), AuditContext(shift: true)) {
                emitted.insert(String(message.address.dropFirst("/Syndicate".count)))
            }
        }
        for address in emitted.sorted() {
            XCTAssertTrue(documented.contains(address), "\(address) is not in §14.4–14.9")
        }
        XCTAssertFalse(emitted.isEmpty)
    }

    // MARK: Helpers

    /// Enumerate the decoder's button table from the outside: press one bit, read the event.
    func control(atBit index: Int) -> MX2Native.MX2Control? {
        var decoder = MX2Native.MX2Decoder()
        _ = decoder.decode([1] + [UInt8](repeating: 0, count: 14))
        var report = [UInt8](repeating: 0, count: 15)
        report[0] = 1
        report[1 + index / 8] = 1 << (index % 8)
        guard case let .button(control, true)? = decoder.decode(report).first else { return nil }
        return control
    }

    func analog(atIndex index: Int) -> MX2Native.MX2Analog? {
        var decoder = MX2Native.MX2Decoder()
        _ = decoder.decode([2] + [UInt8](repeating: 0, count: 52))
        var data = [UInt8](repeating: 0, count: 52)
        data[index * 2] = 0xFF
        data[index * 2 + 1] = 0x0F
        guard case let .analog(control, 4095)? = decoder.decode([2] + data).first else { return nil }
        return control
    }

    func encoder(atIndex index: Int) -> MX2Native.MX2Encoder? {
        var decoder = MX2Native.MX2Decoder()
        _ = decoder.decode([1] + [UInt8](repeating: 0, count: 14))
        var report = [UInt8](repeating: 0, count: 15)
        report[0] = 1
        report[1 + 11 + index / 2] = 1 << (4 * (index % 2))
        guard case let .encoder(control, 1)? = decoder.decode(report).first else { return nil }
        return control
    }

    /// The deck or mixer channel an address refers to, if any. Used to prove that a control
    /// on one side can never address the other side's deck.
    func deckReference(in address: String) -> Int? {
        for marker in ["/Deck/", "/Mixer/CH"] {
            if let range = address.range(of: marker) {
                return Int(address[range.upperBound...].prefix { $0.isNumber })
            }
        }
        if address.hasPrefix("/Syndicate/Browser/L") {
            return Int(address.dropFirst("/Syndicate/Browser/L".count).prefix { $0.isNumber })
        }
        return nil
    }

    /// Exhaustive, no `default:`: a new MX2Native.MX2Control / MX2Native.MX2Analog / MX2Native.MX2Encoder case fails to
    /// compile here, which is the guard the counts above cannot express on their own.
    func caseName(_ control: MX2Native.MX2Control) -> String {
        switch control {
        case .fxButton: return "fxButton"
        case .favorite: return "favorite"
        case .addToList: return "addToList"
        case .preview: return "preview"
        case .view: return "view"
        case .flux: return "flux"
        case .reverse: return "reverse"
        case .turntable: return "turntable"
        case .jogMode: return "jogMode"
        case .shift: return "shift"
        case .sync: return "sync"
        case .master: return "master"
        case .keyLock: return "keyLock"
        case .bank: return "bank"
        case .pad: return "pad"
        case .cue: return "cue"
        case .play: return "play"
        case .fxAssign: return "fxAssign"
        case .channelFX: return "channelFX"
        case .headphone: return "headphone"
        case .globalFX: return "globalFX"
        case .filter: return "filter"
        case .microphone: return "microphone"
        case .browsePress: return "browsePress"
        case .movePress: return "movePress"
        case .sizePress: return "sizePress"
        case .jogTouch: return "jogTouch"
        }
    }

    func caseName(_ analog: MX2Native.MX2Analog) -> String {
        switch analog {
        case .fxKnob: return "fxKnob"
        case .gain: return "gain"
        case .eqHigh: return "eqHigh"
        case .eqMid: return "eqMid"
        case .eqLow: return "eqLow"
        case .channelFX: return "channelFX"
        case .mainVolume: return "mainVolume"
        case .cueMix: return "cueMix"
        case .cueVolume: return "cueVolume"
        case .volume: return "volume"
        case .crossfader: return "crossfader"
        case .tempo: return "tempo"
        }
    }

    func caseName(_ encoder: MX2Native.MX2Encoder) -> String {
        switch encoder {
        case .browse: return "browse"
        case .move: return "move"
        case .size: return "size"
        }
    }

    func describe(_ control: MX2Native.MX2Control) -> String {
        switch control {
        case let .fxButton(side, index): return "fxButton(\(sideLabel(side)), \(index))"
        case let .favorite(side): return "favorite(\(sideLabel(side)))"
        case let .addToList(side): return "addToList(\(sideLabel(side)))"
        case let .preview(side): return "preview(\(sideLabel(side)))"
        case let .view(side): return "view(\(sideLabel(side)))"
        case let .flux(side): return "flux(\(sideLabel(side)))"
        case let .reverse(side): return "reverse(\(sideLabel(side)))"
        case let .turntable(side): return "turntable(\(sideLabel(side)))"
        case let .jogMode(side): return "jogMode(\(sideLabel(side)))"
        case let .shift(side): return "shift(\(sideLabel(side)))"
        case let .sync(side): return "sync(\(sideLabel(side)))"
        case let .master(side): return "master(\(sideLabel(side)))"
        case let .keyLock(side): return "keyLock(\(sideLabel(side)))"
        case let .bank(side, bank): return "bank(\(sideLabel(side)), \(bank))"
        case let .pad(side, index): return "pad(\(sideLabel(side)), \(index))"
        case let .cue(side): return "cue(\(sideLabel(side)))"
        case let .play(side): return "play(\(sideLabel(side)))"
        case let .fxAssign(side, index): return "fxAssign(\(sideLabel(side)), \(index))"
        case let .channelFX(side): return "channelFX(\(sideLabel(side)))"
        case let .headphone(side): return "headphone(\(sideLabel(side)))"
        case let .globalFX(index): return "globalFX(\(index))"
        case .filter: return "filter"
        case .microphone: return "microphone"
        case let .browsePress(side): return "browsePress(\(sideLabel(side)))"
        case let .movePress(side): return "movePress(\(sideLabel(side)))"
        case let .sizePress(side): return "sizePress(\(sideLabel(side)))"
        case let .jogTouch(side): return "jogTouch(\(sideLabel(side)))"
        }
    }

    func describe(_ analog: MX2Native.MX2Analog) -> String {
        switch analog {
        case let .fxKnob(side, index): return "fxKnob(\(sideLabel(side)), \(index))"
        case let .gain(side): return "gain(\(sideLabel(side)))"
        case let .eqHigh(side): return "eqHigh(\(sideLabel(side)))"
        case let .eqMid(side): return "eqMid(\(sideLabel(side)))"
        case let .eqLow(side): return "eqLow(\(sideLabel(side)))"
        case let .channelFX(side): return "channelFX(\(sideLabel(side)))"
        case .mainVolume: return "mainVolume"
        case .cueMix: return "cueMix"
        case .cueVolume: return "cueVolume"
        case let .volume(side): return "volume(\(sideLabel(side)))"
        case .crossfader: return "crossfader"
        case let .tempo(side): return "tempo(\(sideLabel(side)))"
        }
    }

    func describe(_ encoder: MX2Native.MX2Encoder) -> String {
        switch encoder {
        case let .browse(side): return "browse(\(sideLabel(side)))"
        case let .move(side): return "move(\(sideLabel(side)))"
        case let .size(side): return "size(\(sideLabel(side)))"
        }
    }

    func sideLabel(_ side: MX2Native.MX2Side) -> String {
        switch side {
        case .left: return "left"
        case .right: return "right"
        }
    }
}
