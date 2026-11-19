import XCTest
@testable import MX2Feedback
@testable import IndirectInputCore

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

    func testEmptyStateShowsLayoutDimlyButNothingBright() {
        // Contract: with no feedback, the panel is still legible — unmapped controls
        // carry a dim "no signal" tint, state controls sit dim, inactive pad banks show
        // a dim tint — but NOTHING may be bright except a pattern running light. An idle
        // deck must never look like it is doing something.
        for mode in MX2PadMode.allCases {
            let frame = renderer.render(state: MX2FeedbackState(),
                                        context: MX2RenderContext(padMode: mode))
            XCTAssertEqual(frame.count, 105)
            // The active bank indicator is legitimately bright; everything else,
            // including the inactive bank tint and the unmapped tint, must be dim.
            let indicators = [MX2Control.hotcues, .stems, .pattern, .loops]
            let activeIDs = Set(indicators.filter {
                ($0 == .hotcues && mode == .hotcues) || ($0 == .stems && mode == .stems)
                    || ($0 == .pattern && mode == .pattern) || ($0 == .loops && mode == .loops)
            }.map { MX2LEDLayout.id(physicalDeck: 1, control: $0) }
                + indicators.filter {
                ($0 == .hotcues && mode == .hotcues) || ($0 == .stems && mode == .stems)
                    || ($0 == .pattern && mode == .pattern) || ($0 == .loops && mode == .loops)
            }.map { MX2LEDLayout.id(physicalDeck: 2, control: $0) })
            let mayBeLit = Set(activeIDs).union(MX2PadMode.pattern == mode ? [21, 51] : [])
            for id in 1...105 where !mayBeLit.contains(id) {
                let value = byte(frame, id: id)
                XCTAssertNotEqual(value % 4, 2, "\(mode): id \(id) = \(value) should be dim")
            }
            // PLAY is genuinely unknown at startup and must not pretend otherwise; CUE
            // carries its dim tint, which is why it is excluded here.
            for id in Array(30...30) + Array(60...60) + Array(87...104) {
                XCTAssertEqual(byte(frame, id: id), 0, "\(mode): id \(id) must be dark")
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

    func testOnlyActivePadBankIndicatorIsBright() {
        // Contract change, deliberately: inactive banks used to be byte 0. They now
        // carry a DIM tint of their own colour so the whole selector row is visible and
        // an unmapped control is never mistaken for a dark-but-working one. "Only the
        // active one lights" becomes "only the active one is bright".
        for mode in MX2PadMode.allCases {
            let frame = renderer.render(state: MX2FeedbackState(),
                                        context: MX2RenderContext(padMode: mode))
            for control in [MX2Control.hotcues, .stems, .pattern, .loops] {
                let isActive = (mode == .hotcues && control == .hotcues)
                    || (mode == .stems && control == .stems)
                    || (mode == .pattern && control == .pattern)
                    || (mode == .loops && control == .loops)
                let byte = self.control(frame, deck: 1, control)
                XCTAssertNotEqual(byte, 0, "\(mode)/\(control) should be visible")
                if isActive {
                    XCTAssertEqual(byte % 4, 2, "\(mode)/\(control) should be bright")
                } else {
                    XCTAssertEqual(byte % 4, 0, "\(mode)/\(control) should be dim")
                }
            }
        }
    }

    func testUnmappedControlsAreFullyDark() {
        // Contract, reversed deliberately: unmapped controls used to carry a dim magenta
        // "no signal" tint so they were visible at a glance. The owner preferred a black
        // panel - a lamp that never responds to anything is noise, and dark reads as
        // "not wired" more honestly than a colour that means nothing here.
        let frame = renderer.render(state: MX2FeedbackState(), context: MX2RenderContext())
        for control in [MX2Control.fx1, .fx2, .fx3, .fx4, .favorite, .add,
                        .preview, .view, .flux, .reverse, .turntable, .jog] {
            XCTAssertEqual(self.control(frame, deck: 1, control), 0,
                           "\(control) is unmapped and must be dark")
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
        // Deck 1 is empty and not previewing, so its CUE is fully dark. It used to sit
        // dim because the ternary had `.dim` in both arms, so the lamp could never be
        // off and never brightened on press either.
        XCTAssertEqual(control(active, deck: 1, .cue), 0)
    }

    func testFilterAvailabilityDoesNotPretendToBeAnActiveEffect() {
        // Filter1Enabled means "the knob exists", not "a filter is engaged". The mixer
        // lamps at 61-73 are now populated (they were forced dark), but availability
        // must never make one go BRIGHT. Dim is the honest representation of "control
        // present, state unknown".
        var state = MX2FeedbackState()
        state.filterEnabled = [1: true, 2: true, 3: true, 4: true]
        let frame = renderer.render(state: state, context: MX2RenderContext())
        for id in 61...73 {
            XCTAssertNotEqual(byte(frame, id: id) % 4, 2,
                              "availability is not activation: LED \(id) must not be bright")
        }
        // The filter lamp itself is dark: no feedback route exists for it.
        XCTAssertEqual(byte(frame, id: MX2MixerLamp.forButton(72)!), 0)
    }

    func testMixerLampsCoverTheMixerBlockAndOffsetFromButtonIDs() {
        // Measured: mixer buttons are bits 60-73 and their lamps are IDs 61-73, offset
        // by exactly +1. Button 73 (microphone) has no lamp in this block.
        XCTAssertEqual(MX2MixerLamp.forButton(60), 61)
        XCTAssertEqual(MX2MixerLamp.forButton(63), 64)
        XCTAssertEqual(MX2MixerLamp.forButton(67), 68)
        XCTAssertEqual(MX2MixerLamp.forButton(72), 73)
        XCTAssertNil(MX2MixerLamp.forButton(73))
        XCTAssertNil(MX2MixerLamp.forButton(59))

        // With nothing cued every mixer lamp is dark EXCEPT the headphone Cue lamps
        // (64/68), which are the only ones with real state behind them and so stay dim
        // white when off. Everything else has no feedback route and is fully dark.
        let frame = renderer.render(state: MX2FeedbackState(), context: MX2RenderContext())
        let headphoneLamps: Set<Int> = [64, 68]
        for id in 61...73 {
            if headphoneLamps.contains(id) {
                XCTAssertEqual(byte(frame, id: id), MX2LEDColor.white.byte(lit: false),
                               "headphone lamp \(id) should be dim white")
            } else {
                XCTAssertEqual(byte(frame, id: id), 0, "mixer lamp \(id) should be dark")
            }
        }
    }

    func testHeadphoneCueLampsUseTheShiftedMixerIDs() {
        let on = renderer.render(state: MX2FeedbackState(),
                                 context: MX2RenderContext(headphoneCue: [1: true]))
        // Button 63 (headphone left) -> lamp 64.
        XCTAssertEqual(byte(on, id: 64), MX2LEDColor.white.byte(lit: true))
        let off = renderer.render(state: MX2FeedbackState(),
                                  context: MX2RenderContext(headphoneCue: [1: false]))
        XCTAssertEqual(byte(off, id: 64), MX2LEDColor.white.byte(lit: false))
    }

    func testHeadphoneCueDimsRatherThanVanishesWhenOff() {
        // Headphone Cue used to go fully dark when off. With the mixer block now
        // populated it sits dim white instead, so the button stays findable - the same
        // treatment as SYNC/MASTER/KEYLOCK. Lamp 64 is button 63 + 1.
        let state = MX2FeedbackState()
        let on = renderer.render(state: state, context: MX2RenderContext(headphoneCue: [1: true]))
        XCTAssertEqual(byte(on, id: 64), MX2LEDColor.white.byte(lit: true))
        let off = renderer.render(state: state, context: MX2RenderContext(headphoneCue: [1: false]))
        XCTAssertEqual(byte(off, id: 64), MX2LEDColor.white.byte(lit: false))
        XCTAssertEqual(byte(off, id: 64) % 4, 0, "must be dim, not bright")
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
        // Not the master: blue but dim, not black.
        XCTAssertEqual(control(frame, deck: 1, .master), MX2LEDColor.blue.byte(lit: false))
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

    func testHeldPopulatedHotcueLightsWithoutWaitingForFeedbackAndRespectsShift() {
        var state = MX2FeedbackState()
        state[deck: 3].cues[2] = MX2Cue(color: 5)
        var context = MX2RenderContext(
            deckAssignment: MX2DeckAssignment(deckA: 3, deckB: 4),
            heldPads: [1: [2]])
        let held = renderer.render(state: state, context: context)
        XCTAssertEqual(control(held, deck: 1, .pad3), 38)
        XCTAssertEqual(control(held, deck: 2, .pad3), 0)

        context.shiftPressed = true
        XCTAssertEqual(control(renderer.render(state: state, context: context), deck: 1, .pad3), 36)
        context.shiftPressed = false
        context.heldPads = [:]
        XCTAssertEqual(control(renderer.render(state: state, context: context), deck: 1, .pad3), 36)
    }

    func testHeldEmptyPadStillRendersDim() {
        var state = MX2FeedbackState()
        state[deck: 1].loaded = true
        let context = MX2RenderContext(heldPads: [1: [1]])
        let frame = renderer.render(state: state, context: context)
        XCTAssertEqual(control(frame, deck: 1, .pad2), MX2LEDColor.white.byte(lit: false))
    }

    func testHeldLoopPadShowsTheActualHardwarePressWithoutLightingOtherPads() {
        var context = MX2RenderContext(padMode: .loops, heldPads: [2: [5]])
        var frame = renderer.render(state: MX2FeedbackState(), context: context)
        for (index, pad) in MX2Control.pads.enumerated() {
            XCTAssertEqual(control(frame, deck: 2, pad), index == 5 ? 30 : 28)
            XCTAssertEqual(control(frame, deck: 1, pad), 28)
        }
        context.shiftPressed = true
        frame = renderer.render(state: MX2FeedbackState(), context: context)
        XCTAssertEqual(control(frame, deck: 2, .pad6), 28)
        context.shiftPressed = false
        context.heldPads = [:]
        frame = renderer.render(state: MX2FeedbackState(), context: context)
        XCTAssertEqual(control(frame, deck: 2, .pad6), 28)
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

    func testActivePadModeIndicatorOnlyIsBright() {
        let frame = renderer.render(state: MX2FeedbackState(),
                                    context: MX2RenderContext(padMode: .stems))
        XCTAssertEqual(control(frame, deck: 1, .stems), MX2LEDColor.purple.byte(lit: true))
        // Inactive banks are dim tints, not black, so the selector row reads as a row.
        XCTAssertEqual(control(frame, deck: 1, .hotcues), MX2LEDColor.red.byte(lit: false))
        XCTAssertEqual(control(frame, deck: 1, .loops), MX2LEDColor.green.byte(lit: false))
        XCTAssertEqual(control(frame, deck: 1, .pattern), MX2LEDColor.orange.byte(lit: false))
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

    func testNonFiniteMeterFeedbackIsDarkRatherThanFullOrCrashing() {
        for level in [Double.infinity, -Double.infinity, Double.nan] {
            var state = MX2FeedbackState()
            state.meters[1] = level
            let frame = renderer.render(state: state)
            for id in 87...95 {
                XCTAssertEqual(byte(frame, id: id), 0, "invalid meter \(level), LED \(id)")
            }
        }
    }

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
        // The mixer block 61-73 is now fully populated: buttons 60-72 map to lamps
        // 61-73 at a +1 offset. Nothing there may be bright without feedback, but
        // every lamp is present and dim.
        for id in 61...73 {
            XCTAssertEqual(byte(frame, id: id) % 4, 0, "id \(id) must be dim")
        }
        // Bytes outside every defined block stay untouched.
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

// MARK: - Frame composition

extension MX2LEDRendererTests {
    /// Every LED ID must belong to exactly one composed band.
    ///
    /// The frame used to be assembled by copying hard-coded byte slices, and any ID
    /// outside them was silently dropped. That is how the mixer lamps stayed dark while
    /// the renderer was populating them correctly, and it would hide the next band just
    /// as quietly. This asserts the band table covers the deck and mixer regions with no
    /// gaps and no overlaps.
    func testDeckAndMixerBandsPartitionTheLedRegionsWithoutGapsOrOverlaps() {
        var owner: [Int: String] = [:]
        var overlaps: [String] = []

        func claim(_ range: ClosedRange<Int>, _ label: String) {
            for id in range {
                if let existing = owner[id] {
                    overlaps.append("id \(id) claimed by \(existing) and \(label)")
                }
                owner[id] = label
            }
        }

        for deck in 1...2 {
            for (i, band) in MX2LEDLayout.deckBands(forPhysicalDeck: deck).enumerated() {
                claim(band, "deck\(deck).band\(i)")
            }
        }
        claim(MX2LEDLayout.mixerLampRange, "mixer")

        XCTAssertTrue(overlaps.isEmpty, "bands overlap: \(overlaps)")

        // The bands that carry real state must all be claimed. Not asserted: every ID
        // 1-105, because some genuinely have no lamp assignment.
        for deck in 1...2 {
            XCTAssertNotNil(owner[MX2LEDLayout.deckBase(deck)], "deck \(deck) control block")
            XCTAssertNotNil(owner[MX2LEDLayout.undershellBase(deck)], "deck \(deck) under-shell")
            XCTAssertNotNil(owner[MX2LEDLayout.meterBase(deck)], "deck \(deck) meter")
        }
        // CUE and PLAY specifically: the lamps the owner noticed were dead.
        XCTAssertNotNil(owner[MX2LEDLayout.id(physicalDeck: 1, control: .cue)], "deck A CUE")
        XCTAssertNotNil(owner[MX2LEDLayout.id(physicalDeck: 1, control: .play)], "deck A PLAY")
        XCTAssertNotNil(owner[MX2LEDLayout.id(physicalDeck: 2, control: .cue)], "deck B CUE")
        XCTAssertNotNil(owner[61], "first mixer lamp")
        XCTAssertNotNil(owner[73], "last mixer lamp")
    }
}
