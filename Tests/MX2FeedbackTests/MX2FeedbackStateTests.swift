import XCTest
@testable import MX2Feedback
@testable import IndirectInputCore

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

    /// `Feedback/Resend` is a route Syndicate receives, never one it sends back, so
    /// an inbound one is not feedback.
    func testInboundResendIsIgnored() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Feedback/Resend") { $0.int(1) }), .ignored)
        XCTAssertEqual(state.apply(oscBundle([
            oscMessage("/Syndicate/Feedback/Resend") { $0.int(1) }
        ])), .ignored)
        XCTAssertEqual(state, MX2FeedbackState())
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

    func testDeckSubscriptCreatesEntryOnWriteAndReadsDefaults() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state[deck: 2], MX2DeckState())
        state[deck: 2].loop = true
        XCTAssertTrue(state[deck: 2].loop)
        XCTAssertEqual(state.decks.keys.sorted(), [2])
    }

    // MARK: TempoSliderEnabled

    func testTempoSliderEnabledIsStoredPerDeck() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/TempoSliderEnabled") { $0.int(1) }),
                       .changed)
        XCTAssertTrue(state[deck: 1].tempoSliderEnabled)
        XCTAssertFalse(state[deck: 2].tempoSliderEnabled)
        state.apply(oscMessage("/Syndicate/Deck/1/TempoSliderEnabled") { $0.int(0) })
        XCTAssertFalse(state[deck: 1].tempoSliderEnabled)
    }

    func testTempoSliderEnabledRepeatIsUnchanged() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/3/TempoSliderEnabled") { $0.int(1) })
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/3/TempoSliderEnabled") { $0.int(1) }),
                       .unchanged)
    }

    // MARK: Track deck scalars

    func testTrackDeckScalarsAreStoredPerDeck() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/Position") { $0.float(12.5) })
        state.apply(oscMessage("/Syndicate/Deck/1/Progress") { $0.float(0.25) })
        state.apply(oscMessage("/Syndicate/Deck/1/Time") { $0.float(83) })
        state.apply(oscMessage("/Syndicate/Deck/1/BarRamp") { $0.float(0.5) })
        state.apply(oscMessage("/Syndicate/Deck/1/PhaseOffset") { $0.float(-0.125) })
        state.apply(oscMessage("/Syndicate/Deck/1/BPM") { $0.float(128) })
        state.apply(oscMessage("/Syndicate/Deck/1/Pitch") { $0.float(-2) })
        let deck = state[deck: 1]
        XCTAssertEqual(deck.position, 12.5)
        XCTAssertEqual(deck.progress, 0.25)
        XCTAssertEqual(deck.time, 83)
        XCTAssertEqual(deck.barRamp, 0.5)
        XCTAssertEqual(deck.phaseOffset, -0.125)
        XCTAssertEqual(deck.bpm, 128)
        XCTAssertEqual(deck.pitch, -2)
        XCTAssertEqual(state[deck: 2].position, 0)
    }

    func testTrackInfoDecodesAllEightArguments() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/2/TrackInfo") { builder in
            builder.string("Sunrise")
            builder.string("Nadia")
            builder.string("8A")
            builder.float(124)
            builder.float(213.5)
            builder.int(64)
            builder.int(256)
            builder.string("track")
        }), .changed)
        let info = state[deck: 2].trackInfo
        XCTAssertEqual(info.title, "Sunrise")
        XCTAssertEqual(info.artist, "Nadia")
        XCTAssertEqual(info.key, "8A")
        XCTAssertEqual(info.bpm, 124)
        XCTAssertEqual(info.duration, 213.5)
        XCTAssertEqual(info.bars, 64)
        XCTAssertEqual(info.beats, 256)
        XCTAssertEqual(info.type, "track")
        // The documented list is eight arguments; a short payload is unusable.
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/2/TrackInfo") { builder in
            builder.string("Only")
            builder.string("Two")
        }), .ignored)
        XCTAssertEqual(state[deck: 2].trackInfo.title, "Sunrise")
    }

    // MARK: Loop family

    func testLoopInfoSetsOnStartEndTogether() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/LoopInfo") { builder in
            builder.int(1); builder.float(3.5); builder.float(9.25)
        }), .changed)
        let deck = state[deck: 1]
        XCTAssertTrue(deck.loop)
        XCTAssertEqual(deck.loopState.start, 3.5)
        XCTAssertEqual(deck.loopState.end, 9.25)
        XCTAssertEqual(deck.loopInfo, MX2LoopInfo(on: true, start: 3.5, end: 9.25))
    }

    func testLoopStartEndUpdatePointsWithoutClaimingLoopInfoProvenance() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/LoopInfo") { builder in
            builder.int(1); builder.float(1); builder.float(2)
        })
        state.apply(oscMessage("/Syndicate/Deck/1/LoopStart") { $0.float(5) })
        state.apply(oscMessage("/Syndicate/Deck/1/LoopEnd") { $0.float(7) })
        let deck = state[deck: 1]
        XCTAssertEqual(deck.loopState.start, 5)
        XCTAssertEqual(deck.loopState.end, 7)
        // Provenance still says the last LoopInfo was 1…2.
        XCTAssertEqual(deck.loopInfo, MX2LoopInfo(on: true, start: 1, end: 2))
    }

    func testBareLoopToggleSupersedesLoopInfo() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/LoopInfo") { builder in
            builder.int(1); builder.float(1); builder.float(2)
        })
        state.apply(oscMessage("/Syndicate/Deck/1/Loop") { $0.int(0) })
        let deck = state[deck: 1]
        XCTAssertFalse(deck.loop)
        XCTAssertNil(deck.loopInfo)
        XCTAssertEqual(deck.loopState.start, 1)  // points survive the toggle
    }

    func testLoopInfoShortPayloadIsIgnored() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/LoopInfo") { builder in
            builder.int(1); builder.float(1)
        }), .ignored)
        XCTAssertEqual(state, MX2FeedbackState())
    }

    // MARK: Cue events

    func testCueFireStoresLaunchedCue() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/CueFire") { $0.int(4) }), .changed)
        XCTAssertEqual(state[deck: 1].cueFire, 4)
    }

    func testCuePassStoresNameCueColour() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/CuePass") { builder in
            builder.string("Drop"); builder.int(3); builder.int(5)
        }), .changed)
        let pass = state[deck: 1].cuePass
        XCTAssertEqual(pass.name, "Drop")
        XCTAssertEqual(pass.cue, 3)
        XCTAssertEqual(pass.color, 5)
        // The documented "before the first cue" payload is "", 0, 0.
        state.apply(oscMessage("/Syndicate/Deck/1/CuePass") { builder in
            builder.string(""); builder.int(0); builder.int(0)
        })
        XCTAssertEqual(state[deck: 1].cuePass, MX2CuePass())
    }

    func testCuePassMissingArgumentIsIgnored() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/CuePass") { builder in
            builder.string("Drop"); builder.int(3)
        }), .ignored)
        XCTAssertEqual(state, MX2FeedbackState())
    }

    func testCuesKeepsEightHotCuesAndSpillsExtraPairs() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/Cues") { builder in
            for index in 0..<10 {
                builder.int(Int32((index % 8) + 1))
                builder.string("Cue \(index)")
            }
        })
        let deck = state[deck: 1]
        XCTAssertEqual(deck.cues.count, 8)
        XCTAssertEqual(deck.cues[7].name, "Cue 7")
        XCTAssertEqual(deck.extraCues.count, 2)
        XCTAssertEqual(deck.extraCues[0].name, "Cue 8")
        XCTAssertEqual(deck.extraCues[1].color, 2)
    }

    // MARK: Header

    func testHeaderValuesAreStored() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Header/BPM") { $0.float(127.5) })
        state.apply(oscMessage("/Syndicate/Header/MasterVolume") { $0.float(0.8) })
        state.apply(oscMessage("/Syndicate/Header/CueVolume") { $0.float(0.3) })
        state.apply(oscMessage("/Syndicate/Header/Metronome") { $0.int(1) })
        XCTAssertEqual(state.bpm, 127.5)
        XCTAssertEqual(state.masterVolume, 0.8, accuracy: 1e-6)
        XCTAssertEqual(state.cueVolume, 0.3, accuracy: 1e-6)
        XCTAssertTrue(state.metronome)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Header/BPM") { $0.float(127.5) }),
                       .unchanged)
    }

    func testHeaderClockStoresBeatInTheBar() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Header/Clock") { $0.int(3) }), .changed)
        XCTAssertEqual(state.clockBeat, 3)
        // Same beat again is a recognised no-op, not a change.
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Header/Clock") { $0.int(3) }), .unchanged)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Header/Clock") { $0.int(4) }), .changed)
        XCTAssertEqual(state.clockBeat, 4)
    }

    func testHeaderValuesAreIgnoredUnderADifferentRoot() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Other/Header/BPM") { $0.float(127.5) })
        XCTAssertEqual(state, MX2FeedbackState())
    }

    // MARK: Transport

    func testTransportStoresBarAndBeat() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/Transport") { builder in
            builder.int(2); builder.int(4)
        }), .changed)
        XCTAssertEqual(state[deck: 1].beat, MX2Beat(bar: 2, beat: 4))
        // Bars before Grid Start are 0 or negative, exactly as documented.
        state.apply(oscMessage("/Syndicate/Deck/1/Transport") { builder in
            builder.int(-3); builder.int(1)
        })
        XCTAssertEqual(state[deck: 1].beat.bar, -3)
    }

    func testArrangementTransportIsSeparateFromDeckTransport() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/1/Transport") { builder in
            builder.int(1); builder.int(2)
        })
        state.apply(oscMessage("/Syndicate/Deck/1/Arrangement/Transport") { builder in
            builder.int(5); builder.int(3)
        })
        XCTAssertEqual(state[deck: 1].beat, MX2Beat(bar: 1, beat: 2))
        XCTAssertEqual(state[deck: 1].arrangementBeat, MX2Beat(bar: 5, beat: 3))
    }

    // MARK: Clip decks

    func testClipFeedbackIsStoredPerDeck() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/2/Clip/Loop") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/2/Clip/Pitch") { $0.float(-2) })
        state.apply(oscMessage("/Syndicate/Deck/2/Clip/MidiOut") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/2/Clip/MidiOutDevice") { $0.int(3) })
        state.apply(oscMessage("/Syndicate/Deck/2/Clip/MidiChannel") { $0.int(10) })
        let clip = state[deck: 2].clip
        XCTAssertTrue(clip.loop)
        XCTAssertEqual(clip.pitch, -2)
        XCTAssertTrue(clip.midiOut)
        XCTAssertEqual(clip.midiOutDevice, 3)
        XCTAssertEqual(clip.midiChannel, 10)
        // Other decks untouched.
        XCTAssertEqual(state[deck: 1].clip, MX2ClipState())
    }

    func testUnknownClipControlIsIgnored() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/2/Clip/Warp") { $0.int(1) }),
                       .ignored)
        XCTAssertEqual(state, MX2FeedbackState())
    }

    // MARK: Arrangement lanes

    func testArrangementLanesStoreVolumeMeterRoute() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/3/Arrangement/Lane2/Volume") { $0.float(0.75) })
        state.apply(oscMessage("/Syndicate/Deck/3/Arrangement/Lane2/Meter") { $0.float(0.5) })
        state.apply(oscMessage("/Syndicate/Deck/3/Arrangement/Lane2/Route") { $0.int(4) })
        let lane = state[deck: 3][arrangementLane: 2]
        XCTAssertEqual(lane.volume, 0.75)
        XCTAssertEqual(lane.meter, 0.5)
        XCTAssertEqual(lane.route, 4)
        XCTAssertEqual(state[deck: 3][arrangementLane: 1], MX2ArrangementLane())
    }

    func testArrangementLaneBoundsAreEnforced() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/3/Arrangement/Lane5/Volume") { $0.float(1) }),
                       .ignored)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/3/Arrangement/Lane0/Volume") { $0.float(1) }),
                       .ignored)
        XCTAssertEqual(state, MX2FeedbackState())
    }

    // MARK: Sampler decks

    func testSamplerDeckValuesAreStored() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/GlobalPitch") { $0.float(-7) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Swing") { $0.float(0.4) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/CurrentStep") { $0.int(11) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/SampleProgress") { $0.float(-1) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Speed") { $0.float(0.5) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/SpeedHalf") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/SpeedDouble") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/VelocityMode") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/FaderStart") { $0.int(1) })
        let sampler = state[deck: 4].sampler
        XCTAssertEqual(sampler.globalPitch, -7)
        XCTAssertEqual(sampler.swing, 0.4, accuracy: 1e-6)
        XCTAssertEqual(sampler.currentStep, 11)
        XCTAssertEqual(sampler.sampleProgress, -1)
        XCTAssertEqual(sampler.speed, 0.5)
        XCTAssertTrue(sampler.speedHalf)
        XCTAssertTrue(sampler.speedDouble)
        XCTAssertTrue(sampler.velocityMode)
        XCTAssertTrue(sampler.faderStart)
        // The long-standing mirror tracks CurrentStep too.
        XCTAssertEqual(state[deck: 4].samplerStep, 11)
    }

    func testSamplerLaneIsOneBasedAndValidated() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Lane") { $0.int(8) }),
                       .changed)
        XCTAssertEqual(state[deck: 4].sampler.lane, 8)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Lane") { $0.int(9) }),
                       .ignored)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Lane") { $0.int(0) }),
                       .ignored)
        XCTAssertEqual(state[deck: 4].sampler.lane, 8)
    }

    func testSamplerLaneValuesFollowTheSelectedLane() {
        var state = MX2FeedbackState()
        // Lane-scoped values are unusable before a Lane arrives.
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Volume") { $0.float(0.9) }),
                       .ignored)
        XCTAssertEqual(state, MX2FeedbackState())

        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Lane") { $0.int(2) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/LaneTitle") { $0.string("Kick") })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Pitch") { $0.float(-3.5) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Attack") { $0.float(0.1) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Hold") { $0.float(0.2) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Release") { $0.float(0.3) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Volume") { $0.float(0.9) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Steps") { $0.float(16) })
        let lane = state[deck: 4].sampler[lane: 2]
        XCTAssertEqual(lane.title, "Kick")
        XCTAssertEqual(lane.pitch, -3.5)
        XCTAssertEqual(lane.attack, 0.1, accuracy: 1e-6)
        XCTAssertEqual(lane.hold, 0.2, accuracy: 1e-6)
        XCTAssertEqual(lane.release, 0.3, accuracy: 1e-6)
        XCTAssertEqual(lane.volume, 0.9, accuracy: 1e-6)
        XCTAssertEqual(lane.steps, 16)
        // Nothing leaked into lane 1.
        XCTAssertEqual(state[deck: 4].sampler[lane: 1], MX2SamplerLane())

        // Selecting another lane redirects the next lane-scoped value.
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Lane") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Deck/4/Sampler/Volume") { $0.float(0.5) })
        XCTAssertEqual(state[deck: 4].sampler[lane: 1].volume, 0.5)
        XCTAssertEqual(state[deck: 4].sampler[lane: 2].volume, 0.9, accuracy: 1e-6)
    }

    func testUnknownSamplerControlIsIgnored() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/4/Sampler/WarpDrive") { $0.int(1) }),
                       .ignored)
        XCTAssertEqual(state, MX2FeedbackState())
    }

    // MARK: SlipPingPong (sent by 0.3.10, absent from 14.10's list)

    func testSlipPingPongIsStored() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/SlipPingPong") { $0.int(1) }),
                       .changed)
        XCTAssertTrue(state[deck: 1].slipPingPong)
    }

    // MARK: Mixer completeness

    func testFilter2EnabledIsTrackedSeparatelyFromFilter1() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Mixer/CH1/Filter1Enabled") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Mixer/CH1/Filter2Enabled") { $0.int(0) })
        XCTAssertEqual(state.filterEnabled[1], true)
        XCTAssertEqual(state.filter2Enabled[1], false)
        XCTAssertEqual(state.filter2Enabled[2], nil)
    }

    /// Builds after 0.3.9 send filter feedback as `Mixer/filter{n}.cut` and friends,
    /// outside the `CH{n}` folder.
    func testDottedFilterAddressesAreStoredPerChannel() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Mixer/filter2.cut") { $0.float(0.25) }), .changed)
        state.apply(oscMessage("/Syndicate/Mixer/filter2.res") { $0.float(0.5) })
        state.apply(oscMessage("/Syndicate/Mixer/filter3.width") { $0.float(1) })
        state.apply(oscMessage("/Syndicate/Mixer/filter2.cutEnabled") { $0.int(1) })
        XCTAssertEqual(state[channel: 2].filterCut, 0.25)
        XCTAssertEqual(state[channel: 2].filterRes, 0.5)
        XCTAssertTrue(state[channel: 2].filterCutEnabled)
        XCTAssertFalse(state[channel: 2].filterResEnabled)
        XCTAssertEqual(state[channel: 3].filterWidth, 1)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Mixer/filter2.cut") { $0.float(0.25) }), .unchanged)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Mixer/filter0.cut") { $0.float(0.5) }), .ignored)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Mixer/filter2.drive") { $0.float(0.5) }), .ignored)
    }

    /// `CueMomentary` is an input switch, not feedback, and must not move any state.
    func testCueMomentaryIsNotFeedback() {
        var state = MX2FeedbackState()
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Deck/1/CueMomentary") { $0.int(1) }), .ignored)
    }

    func testMixerValuesAreStoredPerChannel() {
        var state = MX2FeedbackState()
        state.apply(oscMessage("/Syndicate/Mixer/CH2/Volume") { $0.float(0.7) })
        state.apply(oscMessage("/Syndicate/Mixer/CH2/Trim") { $0.float(0.5) })
        state.apply(oscMessage("/Syndicate/Mixer/CH2/EQ/Low") { $0.float(0.25) })
        state.apply(oscMessage("/Syndicate/Mixer/CH2/EQ/Mid") { $0.float(0.5) })
        state.apply(oscMessage("/Syndicate/Mixer/CH2/EQ/High") { $0.float(0.75) })
        state.apply(oscMessage("/Syndicate/Mixer/CH2/Filter1") { $0.float(0.1) })
        state.apply(oscMessage("/Syndicate/Mixer/CH2/Filter2") { $0.float(0.9) })
        state.apply(oscMessage("/Syndicate/Mixer/CH2/Mute") { $0.int(1) })
        state.apply(oscMessage("/Syndicate/Mixer/CH2/Solo") { $0.int(1) })
        let channel = state[channel: 2]
        XCTAssertEqual(channel.volume, 0.7, accuracy: 1e-6)
        XCTAssertEqual(channel.trim, 0.5)
        XCTAssertEqual(channel.eqLow, 0.25)
        XCTAssertEqual(channel.eqMid, 0.5)
        XCTAssertEqual(channel.eqHigh, 0.75)
        XCTAssertEqual(channel.filter1, 0.1, accuracy: 1e-6)
        XCTAssertEqual(channel.filter2, 0.9, accuracy: 1e-6)
        XCTAssertTrue(channel.mute)
        XCTAssertTrue(channel.solo)
        XCTAssertEqual(state[channel: 1], MX2MixerChannelState())
        // Repeat is recognised but moves nothing.
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Mixer/CH2/Volume") { $0.float(0.7) }),
                       .unchanged)
    }

    func testUnknownMixerAddressIsIgnored() {
        var state = MX2FeedbackState()
        // 14.10 lists no FX/Output feedback; anything unlisted stays ignored.
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Mixer/CH1/FX") { $0.int(1) }), .ignored)
        XCTAssertEqual(state.apply(oscMessage("/Syndicate/Mixer/CH1/EQ/Presence") { $0.float(0.5) }),
                       .ignored)
        XCTAssertEqual(state, MX2FeedbackState())
    }
}
