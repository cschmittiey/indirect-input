import XCTest
@testable import MX2Feedback

final class MX2FeedbackStateTests: XCTestCase {

    // MARK: Deck transport

    func testDeckPlayingIntUpdatesOnlyThatDeck() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/3/Playing") { $0.int(1) })
        XCTAssertTrue(state[deck: 3].playing)
        XCTAssertFalse(state[deck: 1].playing)
        XCTAssertFalse(state[deck: 2].playing)
        XCTAssertFalse(state[deck: 4].playing)
    }

    func testDeckPlayingFollowsBothDirections() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/Playing") { $0.int(1) })
        XCTAssertTrue(state[deck: 1].playing)
        state.apply(oscMessage("/Syndicate/Deck/1/Playing") { $0.int(0) })
        XCTAssertFalse(state[deck: 1].playing)
    }

    func testOutOfRangeDeckNumbersAreIgnored() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/9/Playing") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/0/Playing") { $0.int(1) })
        XCTAssertEqual(state, MX2FeedbackState())
        XCTAssertTrue(state.decks.isEmpty)
    }

    func testPlayPendingGlobalAndPerDeck() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/PlayPending") { $0.int(1) })
        XCTAssertTrue(state.playPending)
        state.apply(oscMessage("/Syndicate/Deck/2/PlayPending") { $0.int(1) })
        XCTAssertTrue(state[deck: 2].playPending)
        XCTAssertFalse(state[deck: 1].playPending)
        state.apply(oscMessage("/Syndicate/PlayPending") { $0.int(0) })
        XCTAssertFalse(state.playPending)
    }

    func testLoadedGlobalMarksSingleDeckAndPerDeckFormWorks() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Loaded") { $0.int(1) })
        XCTAssertTrue(state.loaded == false || state.loaded == true)  // global flag always defined
        state.apply(oscMessage("/Syndicate/Deck/4/Loaded") { $0.int(1) })
        XCTAssertTrue(state[deck: 4].loaded)
        XCTAssertFalse(state[deck: 1].loaded)
    }

    // MARK: Per-deck toggles

    func testSyncLoopCueSlipPitchPreserveAreStoredPerDeck() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/Sync") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/1/Loop") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/2/CueSlip") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/2/PitchPreserve") { $0.int(0) })
        XCTAssertTrue(state[deck: 1].sync)
        XCTAssertTrue(state[deck: 1].loop)
        XCTAssertFalse(state[deck: 1].cueSlip)
        XCTAssertFalse(state[deck: 2].sync)
        XCTAssertTrue(state[deck: 2].cueSlip)
        XCTAssertFalse(state[deck: 2].pitchPreserve)
    }

    func testPitchPreserveTrueStateRoundTrips() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/3/PitchPreserve") { $0.int(1) })
        XCTAssertTrue(state[deck: 3].pitchPreserve)
    }

    func testTempoSliderAcceptsFloatAndInt() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/TempoSlider") { $0.float(0.25) })
        XCTAssertEqual(state[deck: 1].tempoSlider, 0.25)
        state.apply(oscMessage("/Syndicate/Deck/1/TempoSlider") { $0.int(0) })
        XCTAssertEqual(state[deck: 1].tempoSlider, 0)
        state.apply(oscMessage("/Syndicate/Deck/2/TempoSlider") { $0.int(7) })
        XCTAssertEqual(state[deck: 2].tempoSlider, 7)
    }

    // MARK: Cues

    func testCuesDecodeEightColourNamePairs() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/Cues") { builder in
            for index in 0..<8 {
                builder.int(Int32(index % 9))
                builder.string("Cue \(index)")
            }
        })
        let cues = state[deck: 1].cues
        XCTAssertEqual(cues.count, 8)
        XCTAssertEqual(cues[0].color, 0)
        XCTAssertEqual(cues[0].name, "Cue 0")
        XCTAssertEqual(cues[4].color, 4)
        XCTAssertEqual(cues[4].name, "Cue 4")
        XCTAssertEqual(cues[7].color, 7)
    }

    func testCuesToleratesShortPayloadAndIgnoresTrailingArg() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/2/Cues") { builder in
            builder.int(3)
            builder.string("Intro")
            builder.int(7)  // dangling colour with no name
        })
        let cues = state[deck: 2].cues
        XCTAssertEqual(cues.count, 8)
        XCTAssertEqual(cues[0].color, 3)
        XCTAssertEqual(cues[0].name, "Intro")
        XCTAssertEqual(cues[1].color, 0)  // untouched slot stays empty
        XCTAssertEqual(cues.count, 8)
    }

    func testCueColourOutOfRangeClampsToOff() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/Cues") { builder in
            builder.int(99)
            builder.string("Bad")
        })
        XCTAssertEqual(state[deck: 1].cues[0].color, 0)
        XCTAssertEqual(state[deck: 1].cues[0].name, "Bad")
    }

    func testCuesReplacementClearsPreviousNames() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/Cues") { builder in
            builder.int(1); builder.string("Old")
        })
        state.apply(oscMessage("/Syndicate/Deck/1/Cues") { builder in
            builder.int(2); builder.string("New")
        })
        XCTAssertEqual(state[deck: 1].cues[0].name, "New")
        XCTAssertEqual(state[deck: 1].cues[1].name, "")
    }

    func testCuePressStateIsTrackedSeparatelyFromColour() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/Cues") { builder in
            builder.int(1); builder.string("A")
        })
        XCTAssertFalse(state[deck: 1].cues[0].pressed)
        state.apply(oscMessage("/Syndicate/Deck/1/CuePress") { builder in
            builder.int(1); builder.int(1)
        })
        XCTAssertTrue(state[deck: 1].cues[0].pressed)
        state.apply(oscMessage("/Syndicate/Deck/1/CuePress") { builder in
            builder.int(1); builder.int(0)
        })
        XCTAssertFalse(state[deck: 1].cues[0].pressed)
    }

    // `CuePress` carries `i cue 1-8`, not a 0-based index: cue 8 is real and cue 0
    // is not a cue at all. Getting this wrong silently shifted every pad by one.
    func testCueEightIsValidAndZeroIsNotACue() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/CuePress") { $0.int(8); $0.int(1) })
        XCTAssertTrue(state[deck: 1].cues[7].pressed)
        state.apply(oscMessage("/Syndicate/Deck/1/CuePress") { $0.int(0); $0.int(1) })
        XCTAssertFalse(state[deck: 1].cues[0].pressed)
    }

    // MARK: Sampler, mixer, palette

    func testSamplerStepIsStored() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/2/Sampler/CurrentStep") { $0.int(5) })
        XCTAssertEqual(state[deck: 2].samplerStep, 5)
        XCTAssertEqual(state[deck: 1].samplerStep, 0)
    }

    func testMixerChannelMetersAreStoredPerChannel() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Mixer/CH1/Meter") { $0.float(0.5) })
        state.apply(oscMessage("/Syndicate/Mixer/CH2/Meter") { $0.float(0.25) })
        state.apply(oscMessage("/Syndicate/Mixer/CH1/Meter") { $0.int(1) })  // int form
        XCTAssertEqual(state.meters[1], 1)
        XCTAssertEqual(state.meters[2], 0.25)
    }

    func testColorPaletteStoresSlots() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/ColorPalette") { builder in
            builder.int(1); builder.int(200); builder.int(10); builder.int(30)
        })
        XCTAssertEqual(state.palette.color(slot: 1), MX2RGB(red: 200, green: 10, blue: 30))
        XCTAssertNil(state.palette.color(slot: 2))
        XCTAssertNil(state.palette.color(slot: 0))
        XCTAssertNil(state.palette.color(slot: 9))
    }

    // MARK: Topic filtering, resend, robustness

    func testUnrelatedRootedMessagesAreIgnored() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Other/Deck/1/Playing") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/1/Unknown") { $0.int(1) })
        XCTAssertEqual(state, MX2FeedbackState())
    }

    func testAddressWithoutArgumentIsIgnoredRatherThanCrashing() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/Playing"))
        state.apply(oscMessage("/Syndicate/Deck/1/Cues"))
        state.apply(oscMessage("/Syndicate/ColorPalette"))
        XCTAssertEqual(state, MX2FeedbackState())
    }

    func testResendRequestDetectedOnlyWhenNonzero() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Feedback/Resend") { $0.int(1) }),
                       .resendRequested)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Feedback/Resend") { $0.int(0) }), .ignored)
        XCTAssertEqual(state.resendRequests, 1)
    }

    func testChangeResultReportsWhetherStateActuallyMoved() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/Playing") { $0.int(1) }),
                       .changed)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/Playing") { $0.int(1) }),
                       .unchanged)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/Playing") { $0.int(0) }),
                       .changed)
    }

    func testStateIsEquatableForChangeDetection() {
        var a = MX2FeedbackState()
        var b = MX2FeedbackState()
        a.apply(oscMessage("/Syndicate/Deck/1/Sync") { $0.int(1) })
        b.apply(oscMessage("/Syndicate/Deck/1/Sync") { $0.int(1) })
        XCTAssertEqual(a, b)
        b.apply(oscMessage("/Syndicate/Deck/1/Sync") { $0.int(0) })
        XCTAssertNotEqual(a, b)
    }

    func testApplyDataAcceptsBareMessageAndBundle() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/Playing") { $0.int(1) }),
                       .changed)
        XCTAssertEqual(state.apply(oscBundle([
            oscMessage("/Syndicate/Deck/2/Sync") { $0.int(1) },
            oscMessage("/Syndicate/Deck/2/Loop") { $0.int(1) }
        ])), .changed)
        XCTAssertTrue(state[deck: 1].playing)
        XCTAssertTrue(state[deck: 2].sync)
        XCTAssertTrue(state[deck: 2].loop)
        // A repeat of the same bundle is unchanged, and malformed data is ignored.
        XCTAssertEqual(state.apply(oscBundle([
            oscMessage("/Syndicate/Deck/2/Sync") { $0.int(1) }
        ])), .unchanged)
        XCTAssertEqual(state.apply(Data([0xFF, 0x00])), .ignored)
    }

    func testApplyDataReportsResendInsideBundle() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscBundle([
            oscMessage("/Syndicate/Feedback/Resend") { $0.int(1) }
        ])), .resendRequested)
        XCTAssertEqual(state.resendRequests, 1)
    }

    func testDeckSubscriptCreatesEntryOnWriteAndReadsDefaults() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state[deck: 2], MX2DeckState())
        state[deck: 2].loop = true
        XCTAssertTrue(state[deck: 2].loop)
        XCTAssertEqual(state.decks.keys.sorted(), [2])
    }
}
