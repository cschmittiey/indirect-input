import XCTest
@testable import MX2Feedback

final class MX2LEDRendererTests: XCTestCase {

    private let renderer = MX2LEDRenderer()

    private func byte(_ frame: [UInt8], id: Int) -> UInt8 {
        frame[id - 1]
    }

    /// Reads the frame byte for a control on a physical deck.
    private func control(_ frame: [UInt8], deck: Int, _ control: MX2Control) -> UInt8 {
        frame[MX2LEDLayout.index(physicalDeck: deck, control: control)]
    }

    // MARK: Frame shape and layout constants

    func testFrameIsAlways105Bytes() {
        XCTAssertEqual(renderer.render(state: MX2FeedbackState(), context: .init()).count, 105)
        XCTAssertEqual(MX2LEDLayout.byteCount, 105)
    }

    func testEmptyStateLightsNothingOutsideTheSelectedBank() {
        // Contract: with no feedback, the only non-zero bytes are the selected bank's
        // indicator and that bank's pads (dim, so the layout is findable). Everything
        // else — transport, toggles, under-shell, meters — must be 0.
        for mode in MX2PadMode.allCases {
            let frame = renderer.render(state: MX2FeedbackState(),
                                        context: MX2RenderContext(padMode: mode))
            XCTAssertEqual(frame.count, 105)
            let pads = Array(21...28) + Array(51...58)
            let indicators = [17, 18, 19, 20, 47, 48, 49, 50]
            for id in 1...105 where !pads.contains(id) && !indicators.contains(id) {
                XCTAssertEqual(byte(frame, id: id), 0, "\(mode): id \(id) should be dark")
            }
            // A pattern running light is the one thing that may be bright.
            // Both decks read samplerStep 0, so both running lights sit on pad 1.
            let mayBeLit = Set(indicators).union(MX2PadMode.pattern == mode ? [21, 51] : [])
            for id in 1...105 where !mayBeLit.contains(id) {
                let value = byte(frame, id: id)
                XCTAssertNotEqual(value % 4, 2, "\(mode): id \(id) = \(value) should be dim")
            }
        }
    }

    func testEmptyStateShowsOnlyTheSelectedBankDimly() {
        let expected: [MX2PadMode: (indicator: MX2Control, indicatorByte: UInt8,
                                    padByte: UInt8)] = [
            .hotcues: (.hotcues, MX2LEDColor.red.byte(lit: true), 0),  // empty cues are dark
            .loops: (.loops, MX2LEDColor.green.byte(lit: true), MX2LEDColor.green.byte(lit: false)),
            .stems: (.stems, MX2LEDColor.purple.byte(lit: true), MX2LEDColor.purple.byte(lit: false)),
            // samplerStep defaults to 0, so the running light sits on pad 1.
            .pattern: (.pattern, MX2LEDColor.orange.byte(lit: true),
                       MX2LEDColor.orange.byte(lit: true))
        ]
        for (mode, expectation) in expected {
            let frame = renderer.render(state: MX2FeedbackState(),
                                        context: MX2RenderContext(padMode: mode))
            XCTAssertEqual(control(frame, deck: 1, expectation.indicator),
                           expectation.indicatorByte, "\(mode) indicator")
            XCTAssertEqual(control(frame, deck: 1, .pad1), expectation.padByte, "\(mode) pad1")
        }
    }

    func testOnlyActivePadBankIndicatorLights() {
        for mode in MX2PadMode.allCases {
            let frame = renderer.render(state: MX2FeedbackState(),
                                        context: MX2RenderContext(padMode: mode))
            for control in [MX2Control.hotcues, .stems, .pattern, .loops] {
                let isActive = (mode == .hotcues && control == .hotcues)
                    || (mode == .stems && control == .stems)
                    || (mode == .pattern && control == .pattern)
                    || (mode == .loops && control == .loops)
                XCTAssertEqual(self.control(frame, deck: 1, control) != 0, isActive,
                               "\(mode)/\(control)")
            }
        }
    }

    func testDeckBasesMatchNativeIDs() {
        XCTAssertEqual(MX2LEDLayout.id(physicalDeck: 1, control: .fx1), 1)
        XCTAssertEqual(MX2LEDLayout.id(physicalDeck: 1, control: .play), 30)
        XCTAssertEqual(MX2LEDLayout.id(physicalDeck: 2, control: .fx1), 31)
        XCTAssertEqual(MX2LEDLayout.id(physicalDeck: 2, control: .play), 60)
        // Frame offsets are one less than firmware IDs.
        XCTAssertEqual(MX2LEDLayout.index(physicalDeck: 1, control: .fx1), 0)
        XCTAssertEqual(MX2LEDLayout.index(physicalDeck: 2, control: .play), 59)
        XCTAssertEqual(MX2LEDLayout.index(physicalDeck: 2, control: .play), 59)
    }

    func testControlOffsetsMatchNativeIDs() {
        let expected: [MX2Control: Int] = [
            .fx1: 1, .fx2: 2, .fx3: 3, .fx4: 4, .favorite: 5, .add: 6, .preview: 7,
            .view: 8, .flux: 9, .reverse: 10, .turntable: 11, .jog: 12, .shift: 13,
            .sync: 14, .master: 15, .keylock: 16, .hotcues: 17, .stems: 18,
            .pattern: 19, .loops: 20, .pad1: 21, .pad2: 22, .pad3: 23, .pad4: 24,
            .pad5: 25, .pad6: 26, .pad7: 27, .pad8: 28, .cue: 29, .play: 30
        ]
        for (control, id) in expected {
            XCTAssertEqual(MX2LEDLayout.id(physicalDeck: 1, control: control), id,
                           "\(control)")
        }
    }

    func testNearestRGBPicksSensibleColour() {
        XCTAssertEqual(MX2LEDColor.nearest(to: MX2RGB(red: 250, green: 4, blue: 8)), .red)
        XCTAssertEqual(MX2LEDColor.nearest(to: MX2RGB(red: 250, green: 250, blue: 250)), .white)
        XCTAssertEqual(MX2LEDColor.nearest(to: MX2RGB(red: 4, green: 6, blue: 250)), .blue)
        XCTAssertEqual(MX2LEDColor.nearest(to: MX2RGB(red: 3, green: 3, blue: 3)), .off)
    }

    func testRGBClampsAndReportsBlack() {
        let clamped = MX2RGB(red: -50, green: 300, blue: 128)
        XCTAssertEqual(clamped.red, 0)
        XCTAssertEqual(clamped.green, 255)
        XCTAssertEqual(clamped.blue, 128)
        XCTAssertTrue(MX2RGB.black.isBlack)
        XCTAssertFalse(clamped.isBlack)
    }

    func testColorByteEncoding() {
        XCTAssertEqual(MX2LEDColor.off.byte(lit: true), 0)
        XCTAssertEqual(MX2LEDColor.red.byte(lit: true), 6)
        XCTAssertEqual(MX2LEDColor.red.byte(lit: false), 4)
        XCTAssertEqual(MX2LEDColor.green.byte(lit: true), 30)
        XCTAssertEqual(MX2LEDColor.orange.byte(lit: true), 14)
        XCTAssertEqual(MX2LEDColor.yellow.byte(lit: true), 22)
        XCTAssertEqual(MX2LEDColor.cyan.byte(lit: true), 38)
        XCTAssertEqual(MX2LEDColor.blue.byte(lit: true), 46)
        XCTAssertEqual(MX2LEDColor.purple.byte(lit: true), 58)
        XCTAssertEqual(MX2LEDColor.magenta.byte(lit: true), 62)
        XCTAssertEqual(MX2LEDColor.white.byte(lit: true), 74)
    }

    // MARK: Transport

    func testPlayingLightsPlayGreenOnly() {
        let frame = renderer.render(state: .playingDecks(playing: [1]), context: .init())
        XCTAssertEqual(control(frame, deck: 1, .play), MX2LEDColor.green.byte(lit: true))
        XCTAssertEqual(control(frame, deck: 2, .play), 0)
        XCTAssertEqual(control(frame, deck: 1, .cue), MX2LEDColor.orange.byte(lit: false))
    }

    func testLoadedButIdlePlayLedIsDimGreen() {
        var state = MX2FeedbackState()
        state[deck: 1].loaded = true
        let frame = renderer.render(state: state, context: .init())
        XCTAssertEqual(control(frame, deck: 1, .play), MX2LEDColor.green.byte(lit: false))
    }

    func testPlayPendingLightsPlayYellow() {
        var state = MX2FeedbackState()
        state[deck: 1].loaded = true
        state[deck: 1].playPending = true
        let frame = renderer.render(state: state, context: .init())
        XCTAssertEqual(control(frame, deck: 1, .play), MX2LEDColor.yellow.byte(lit: true))
    }

    func testGlobalPlayPendingLightsBothDecks() {
        var state = MX2FeedbackState()
        state.playPending = true
        let frame = renderer.render(state: state, context: .init())
        XCTAssertEqual(control(frame, deck: 1, .play), MX2LEDColor.yellow.byte(lit: true))
        XCTAssertEqual(control(frame, deck: 2, .play), MX2LEDColor.yellow.byte(lit: true))
    }

    func testCueLedReflectsPreviewStateSeparatelyFromLoaded() {
        var state = MX2FeedbackState()
        state[deck: 2].loaded = true
        let loaded = renderer.render(state: state, context: .init())
        XCTAssertEqual(control(loaded, deck: 2, .cue), MX2LEDColor.orange.byte(lit: false))
        let context = MX2RenderContext(cueActive: [2: true])
        let active = renderer.render(state: state, context: context)
        XCTAssertEqual(control(active, deck: 2, .cue), MX2LEDColor.orange.byte(lit: true))
        XCTAssertEqual(control(active, deck: 1, .cue), 0)
    }

    func testHeadphoneCueTurnsCompletelyOff() {
        let state = MX2FeedbackState()
        let on = renderer.render(state: state, context: MX2RenderContext(headphoneCue: [1: true]))
        XCTAssertEqual(byte(on, id: 64), MX2LEDColor.white.byte(lit: true))
        let off = renderer.render(state: state, context: MX2RenderContext(headphoneCue: [1: false]))
        XCTAssertEqual(byte(off, id: 64), 0)
    }

    // MARK: Toggles

    func testSyncMasterKeylockAreBlue() {
        var state = MX2FeedbackState()
        state[deck: 1].sync = true
        state[deck: 1].pitchPreserve = true
        let context = MX2RenderContext(masterPhysicalDeck: 2)
        let frame = renderer.render(state: state, context: context)
        XCTAssertEqual(control(frame, deck: 1, .sync), MX2LEDColor.blue.byte(lit: true))
        XCTAssertEqual(control(frame, deck: 1, .keylock), MX2LEDColor.blue.byte(lit: true))
        XCTAssertEqual(control(frame, deck: 1, .master), 0)
        XCTAssertEqual(control(frame, deck: 2, .master), MX2LEDColor.blue.byte(lit: true))
    }

    func testShiftLightsWhiteAndDimsPads() {
        var state = MX2FeedbackState()
        state[deck: 1].loaded = true
        state[deck: 1].loop = true
        let base = MX2RenderContext(padMode: .loops)
        let shifted = MX2RenderContext(padMode: .loops, shiftPressed: true)

        let unshifted = renderer.render(state: state, context: base)
        XCTAssertEqual(control(unshifted, deck: 1, .shift), 0)
        XCTAssertEqual(control(unshifted, deck: 1, .loops), MX2LEDColor.green.byte(lit: true))
        XCTAssertEqual(control(unshifted, deck: 1, .pad1), MX2LEDColor.green.byte(lit: true))

        let frame = renderer.render(state: state, context: shifted)
        XCTAssertEqual(control(frame, deck: 1, .shift), MX2LEDColor.white.byte(lit: true))
        // The bank indicator still marks the selected bank while Shift is held.
        XCTAssertEqual(control(frame, deck: 1, .loops), MX2LEDColor.green.byte(lit: true))
        XCTAssertEqual(control(frame, deck: 1, .pad1), MX2LEDColor.green.byte(lit: false))
    }

    // MARK: Pad banks

    func testHotcuePadsUseCueColorsAndPressState() {
        var state = MX2FeedbackState()
        state[deck: 1].loaded = true
        state[deck: 1].cues[0] = MX2Cue(color: 1, name: "A", pressed: true)
        state[deck: 1].cues[2] = MX2Cue(color: 4, name: "C")
        let frame = renderer.render(state: state, context: MX2RenderContext(padMode: .hotcues))

        XCTAssertEqual(control(frame, deck: 1, .pad1), MX2LEDColor.red.byte(lit: true))
        XCTAssertEqual(control(frame, deck: 1, .pad3), MX2LEDColor.green.byte(lit: false))
        XCTAssertEqual(control(frame, deck: 1, .pad2), 0)  // empty slot
        XCTAssertEqual(control(frame, deck: 1, .hotcues), MX2LEDColor.red.byte(lit: true))
    }

    func testCueSlotColourMappingCoversAllEight() {
        let expected: [MX2LEDColor] = [.off, .red, .orange, .yellow,
                                       .green, .cyan, .blue, .purple, .white]
        for slot in 0...8 {
            XCTAssertEqual(MX2LEDColor.fromCueSlot(slot), expected[slot], "slot \(slot)")
        }
        XCTAssertEqual(MX2LEDColor.fromCueSlot(-1), .off)
        XCTAssertEqual(MX2LEDColor.fromCueSlot(9), .off)
    }

    func testCueColorPrefersPaletteRGBAndFallsBackToSlotTable() {
        var palette = MX2ColorPalette()
        palette.set(slot: 1, color: MX2RGB(red: 0, green: 0, blue: 255))  // slot 1 is red; palette says blue
        XCTAssertEqual(MX2LEDColor.cueColor(slot: 1, palette: palette), .blue)
        // Slot 3 has no palette entry → fixed table (yellow).
        XCTAssertEqual(MX2LEDColor.cueColor(slot: 3, palette: palette), .yellow)
        // Empty slot always off.
        XCTAssertEqual(MX2LEDColor.cueColor(slot: 0, palette: palette), .off)
    }

    func testCueColorFallsBackWhenPaletteSlotIsBlack() {
        var palette = MX2ColorPalette()
        palette.set(slot: 2, color: .black)
        XCTAssertEqual(MX2LEDColor.cueColor(slot: 2, palette: palette), .orange)
    }

    func testHeldEmptyPadStillRendersDim() {
        var state = MX2FeedbackState()
        state[deck: 1].loaded = true
        let context = MX2RenderContext(heldPads: [1: [1]])
        let frame = renderer.render(state: state, context: context)
        XCTAssertEqual(control(frame, deck: 1, .pad2), MX2LEDColor.white.byte(lit: false))
    }

    func testLoopBankLightsGreenWhenLooping() {
        var state = MX2FeedbackState()
        state[deck: 2].loop = true
        let frame = renderer.render(state: state, context: MX2RenderContext(padMode: .loops))
        for control in MX2Control.pads {
            XCTAssertEqual(self.control(frame, deck: 2, control),
                           MX2LEDColor.green.byte(lit: true), "\(control)")
        }
        // Deck 1 is not looping: its pads sit dim green, not dark, because the loop
        // bank is the selected bank.
        XCTAssertEqual(self.control(frame, deck: 1, .pad1), MX2LEDColor.green.byte(lit: false))
    }

    func testStemBankSplitsPurpleAndCyan() {
        var state = MX2FeedbackState()
        state[deck: 1].loaded = true
        let frame = renderer.render(state: state, context: MX2RenderContext(padMode: .stems))
        for index in 0..<4 {
            XCTAssertEqual(control(frame, deck: 1, MX2Control.pads[index]),
                           MX2LEDColor.purple.byte(lit: true))
        }
        for index in 4..<8 {
            XCTAssertEqual(control(frame, deck: 1, MX2Control.pads[index]),
                           MX2LEDColor.cyan.byte(lit: true))
        }
    }

    func testPatternBankIsRunningLightFromSamplerStep() {
        var state = MX2FeedbackState()
        state[deck: 1].samplerStep = 3
        let frame = renderer.render(state: state, context: MX2RenderContext(padMode: .pattern))
        for (index, control) in MX2Control.pads.enumerated() {
            let expected = index == 3
                ? MX2LEDColor.orange.byte(lit: true)
                : MX2LEDColor.orange.byte(lit: false)
            XCTAssertEqual(self.control(frame, deck: 1, control), expected, "pad \(index)")
        }
    }

    func testPatternBankWrapsOutOfRangeSamplerSteps() {
        var state = MX2FeedbackState()
        state[deck: 1].samplerStep = 9
        let frame = renderer.render(state: state, context: MX2RenderContext(padMode: .pattern))
        XCTAssertEqual(control(frame, deck: 1, .pad2), MX2LEDColor.orange.byte(lit: true))
    }

    func testActivePadModeIndicatorOnlyIsLit() {
        let frame = renderer.render(state: MX2FeedbackState(),
                                    context: MX2RenderContext(padMode: .stems))
        XCTAssertEqual(control(frame, deck: 1, .stems), MX2LEDColor.purple.byte(lit: true))
        XCTAssertEqual(control(frame, deck: 1, .hotcues), 0)
        XCTAssertEqual(control(frame, deck: 1, .loops), 0)
        XCTAssertEqual(control(frame, deck: 1, .pattern), 0)
    }

    // MARK: Deck pair mapping

    func testDeckAssignmentMapsSyndicateDecksToPhysicalDecks() {
        var state = MX2FeedbackState()
        state[deck: 3].playing = true
        state[deck: 3].loaded = true
        state[deck: 1].playing = true
        state[deck: 1].loaded = true
        let context = MX2RenderContext(deckAssignment: MX2DeckAssignment(deckA: 3, deckB: 4))
        let frame = renderer.render(state: state, context: context)
        XCTAssertEqual(control(frame, deck: 1, .play), MX2LEDColor.green.byte(lit: true))
        XCTAssertEqual(control(frame, deck: 2, .play), 0)
    }

    func testDeckAssignmentDefaultsToDecksOneAndTwo() {
        let assignment = MX2DeckAssignment()
        XCTAssertEqual(assignment.deck(for: 1), 1)
        XCTAssertEqual(assignment.deck(for: 2), 2)
    }

    // MARK: Under-shell glow

    func testUndershellGlowFollowsTransport() {
        var state = MX2FeedbackState()
        state[deck: 1].playing = true
        state[deck: 1].loaded = true
        var frame = renderer.render(state: state, context: .init())
        for id in 74...79 {
            XCTAssertEqual(byte(frame, id: id), MX2LEDColor.green.byte(lit: true), "id \(id)")
        }
        for id in 80...85 {
            XCTAssertEqual(byte(frame, id: id), 0, "id \(id)")
        }

        state[deck: 2].loaded = true
        frame = renderer.render(state: state, context: .init())
        for id in 80...85 {
            XCTAssertEqual(byte(frame, id: id), MX2LEDColor.green.byte(lit: false), "id \(id)")
        }
    }

    // MARK: Meters

    func testSilentMeterIsDark() {
        let frame = renderer.render(state: MX2FeedbackState(), context: .init())
        for id in 87...95 { XCTAssertEqual(byte(frame, id: id), 0, "id \(id)") }
    }

    func testFullMeterLightsAllSegmentsWithGreenToRedRamp() {
        var state = MX2FeedbackState()
        state.meters[1] = 1
        let frame = renderer.render(state: state, context: .init())
        for id in 87...91 { XCTAssertEqual(byte(frame, id: id), MX2LEDColor.green.byte(lit: true)) }
        for id in 92...93 { XCTAssertEqual(byte(frame, id: id), MX2LEDColor.yellow.byte(lit: true)) }
        for id in 94...95 { XCTAssertEqual(byte(frame, id: id), MX2LEDColor.red.byte(lit: true)) }
    }

    func testMeterIsPerDeckAndCanFollowACustomChannel() {
        var state = MX2FeedbackState()
        state.meters[4] = 1
        // Deck B's meter follows CH2 by default, so nothing lights.
        var frame = renderer.render(state: state, context: .init())
        for id in 96...104 { XCTAssertEqual(byte(frame, id: id), 0, "id \(id)") }
        for id in 87...95 { XCTAssertEqual(byte(frame, id: id), 0, "id \(id)") }

        frame = renderer.render(state: state, context: MX2RenderContext(meterChannel: [2: 4]))
        XCTAssertNotEqual(byte(frame, id: 104), 0)
    }

    func testQuietMeterLightsFewerSegments() {
        var state = MX2FeedbackState()
        state.meters[1] = 0.09
        let frame = renderer.render(state: state, context: .init())
        let litCount = (87...95).filter { byte(frame, id: $0) != 0 }.count
        XCTAssertEqual(litCount, 3)  // sqrt(0.09) * 9 ≈ 2.7 → 3
    }

    // MARK: Fallback

    func testRenderingWithOnlyPlayingAndCuesStillProducesColoredPads() {
        // Simulates a Resend that returned transport and cue colours but no palette.
        var state = MX2FeedbackState()
        state[deck: 1].playing = true
        state[deck: 1].loaded = true
        state[deck: 1].cues = [
            MX2Cue(color: 2), MX2Cue(color: 5), MX2Cue(color: 8),
            MX2Cue(), MX2Cue(), MX2Cue(), MX2Cue(), MX2Cue(color: 6)
        ]
        let frame = renderer.render(state: state, context: MX2RenderContext(padMode: .hotcues))
        XCTAssertEqual(control(frame, deck: 1, .pad1), MX2LEDColor.orange.byte(lit: false))
        XCTAssertEqual(control(frame, deck: 1, .pad2), MX2LEDColor.cyan.byte(lit: false))
        XCTAssertEqual(control(frame, deck: 1, .pad3), MX2LEDColor.white.byte(lit: false))
        XCTAssertEqual(control(frame, deck: 1, .pad8), MX2LEDColor.blue.byte(lit: false))
        XCTAssertEqual(control(frame, deck: 1, .play), MX2LEDColor.green.byte(lit: true))
    }

    func testUnusedFrameBytesStayZero() {
        var state = MX2FeedbackState()
        state[deck: 1].playing = true
        state[deck: 2].playing = true
        state.meters[1] = 1
        state.meters[2] = 1
        state[deck: 1].cues[0] = MX2Cue(color: 1, pressed: true)
        let frame = renderer.render(state: state, context: .init())
        let controlledMixerIDs: Set<Int> = [62, 64, 66, 68]
        for id in 61...73 where !controlledMixerIDs.contains(id) {
            XCTAssertEqual(byte(frame, id: id), 0, "id \(id)")
        }
        XCTAssertEqual(byte(frame, id: 86), 0)
        XCTAssertEqual(byte(frame, id: 105), 0)
    }

    func testRenderIsDeterministicForIdenticalInput() {
        var state = MX2FeedbackState()
        state[deck: 1].playing = true
        state[deck: 1].loaded = true
        state.meters[1] = 0.7
        let context = MX2RenderContext(padMode: .stems, shiftPressed: true)
        XCTAssertEqual(renderer.render(state: state, context: context),
                       renderer.render(state: state, context: context))
    }
}
