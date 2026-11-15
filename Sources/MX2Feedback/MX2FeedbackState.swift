import Foundation

/// One RGB colour as Syndicate reports it in `/Syndicate/ColorPalette`.
public struct MX2RGB: Equatable, Sendable {
    public var red: Int
    public var green: Int
    public var blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = min(max(red, 0), 255)
        self.green = min(max(green, 0), 255)
        self.blue = min(max(blue, 0), 255)
    }

    public static let black = MX2RGB(red: 0, green: 0, blue: 0)

    public var isBlack: Bool { red == 0 && green == 0 && blue == 0 }
}

/// Syndicate's 8-slot colour palette, keyed by the slot numbers used in `/Cues`
/// (1…8) and `/ColorPalette` (1…8). Slot 0 is reserved for "no colour".
public struct MX2ColorPalette: Equatable, Sendable {
    private var slots: [Int: MX2RGB] = [:]

    public init() {}

    public init(slots: [Int: MX2RGB]) {
        for (slot, color) in slots where Self.valid(slot: slot) {
            self.slots[slot] = color
        }
    }

    public func color(slot: Int) -> MX2RGB? { slots[slot] }

    public mutating func set(slot: Int, color: MX2RGB) {
        guard Self.valid(slot: slot) else { return }
        slots[slot] = color
    }

    public var isEmpty: Bool { slots.isEmpty }

    public static func valid(slot: Int) -> Bool { (1...8).contains(slot) }
}

/// One hot cue slot as Syndicate reports it: a palette slot plus the label shown
/// in the app, and whether that cue is currently being pressed.
public struct MX2Cue: Equatable, Sendable {
    /// Palette slot 0…8. 0 means the slot is empty.
    public var color: Int
    public var name: String
    public var pressed: Bool

    public init(color: Int = 0, name: String = "", pressed: Bool = false) {
        // Syndicate defines slots 0…8; 0 means empty. Anything else is treated as
        // empty rather than silently becoming some other colour.
        self.color = (0...8).contains(color) ? color : 0
        self.name = name
        self.pressed = pressed
    }

    public var isEmpty: Bool { color == 0 && name.isEmpty }
}

/// `Deck/{n}/CuePass` — `s name, i cue 0-8, i color 0-8`, sent when audible
/// playback passes a hot cue or jumps past one. The documented "before the first
/// cue" state is `"", 0, 0`, which is also this type's default.
public struct MX2CuePass: Equatable, Sendable {
    public var name: String
    /// Cue number 0…8 as Syndicate reports it; 0 = before the first cue.
    public var cue: Int
    /// Palette slot 0…8; 0 = no colour.
    public var color: Int

    public init(name: String = "", cue: Int = 0, color: Int = 0) {
        self.name = name
        self.cue = (0...8).contains(cue) ? cue : 0
        self.color = (0...8).contains(color) ? color : 0
    }
}

/// `Deck/{n}/TrackInfo` — one message of `s title, s artist, s key, f BPM,
/// f duration, i bars, i beats, s type`, sent on load and whenever any of it
/// changes. (The doc's own list names eight arguments; any trailing argument is
/// ignored rather than shifting the ones we decode.)
public struct MX2TrackInfo: Equatable, Sendable {
    public var title: String
    public var artist: String
    /// Musical key as shown in the app.
    public var key: String
    public var bpm: Double
    /// Seconds.
    public var duration: Double
    public var bars: Int
    public var beats: Int
    /// `track`, `clip`, `sampler`, `arrangement`…
    public var type: String

    public init(title: String = "", artist: String = "", key: String = "",
                bpm: Double = 0, duration: Double = 0,
                bars: Int = 0, beats: Int = 0, type: String = "") {
        self.title = title
        self.artist = artist
        self.key = key
        self.bpm = bpm
        self.duration = duration
        self.bars = bars
        self.beats = beats
        self.type = type
    }
}

/// The deck's loop as Syndicate reports it. Three overlapping addresses fold in
/// here — `Loop` (0/1 toggle), `LoopStart` / `LoopEnd` (seconds) and `LoopInfo`
/// (`i on, f start, f end` together) — see `MX2DeckState.loopInfo` for which one
/// arrived last.
public struct MX2LoopState: Equatable, Sendable {
    public var on = false
    /// Loop start in seconds.
    public var start: Double = 0
    /// Loop end in seconds.
    public var end: Double = 0

    public init() {}
}

/// The exact contents of the last `LoopInfo` message (`i on, f start, f end`).
/// Non-nil only after one arrived; `nil` again after a bare `Loop` toggle, since
/// that supersedes it. `LoopStart` / `LoopEnd` update `loopState` only and leave
/// this snapshot alone.
public struct MX2LoopInfo: Equatable, Sendable {
    public var on: Bool
    public var start: Double
    public var end: Double

    public init(on: Bool, start: Double, end: Double) {
        self.on = on
        self.start = start
        self.end = end
    }
}

/// `Deck/{n}/Transport` — `i bar, i beat 1-4` on every beat. Bar 1 beat 1 is Grid
/// Start, so bars before it are 0 or negative. `Deck/{n}/Arrangement/Transport`
/// uses the same shape. The state layer keeps the latest position only: a beat
/// that repeats the current position leaves state unchanged, so beat traffic does
/// not wake the renderer (this is state, not an event stream).
public struct MX2Beat: Equatable, Sendable {
    public var bar: Int
    /// 1…4 (0 before any beat arrived).
    public var beat: Int

    public init(bar: Int = 0, beat: Int = 0) {
        self.bar = bar
        self.beat = beat
    }
}

/// `Deck/{n}/Clip/…` — MIDI clip deck feedback. Per 14.10: `Loop` restart-at-end
/// 0/1, `Pitch` transpose in semitones, `MidiOut` 1 when an output is set,
/// `MidiOutDevice` the output device (index into the deck's device list),
/// `MidiChannel` its channel. Integers arrive as `i` ("integers are sent as `i`").
public struct MX2ClipState: Equatable, Sendable {
    public var loop = false
    /// Transpose in semitones.
    public var pitch: Double = 0
    public var midiOut = false
    /// Device index (0-based), −1 before any arrives.
    public var midiOutDevice = -1
    /// MIDI channel, −1 before any arrives.
    public var midiChannel = -1

    public init() {}
}

/// `Deck/{n}/Arrangement/Lane{1-4}/…` — one arrangement lane: `Volume` (f, track
/// trim), `Meter` (f, level 0-1) and `Route` (i, mixer channel 1-4). Values use
/// the same scales as the input routes.
public struct MX2ArrangementLane: Equatable, Sendable {
    public var volume: Double = 0
    public var meter: Double = 0
    /// Mixer channel 1…4.
    public var route = 0

    public init() {}
}

/// One sampler lane's controls, as addressed for the *selected* lane. The split
/// from `MX2SamplerState` follows `Sampler/LaneSet` (14.8): its per-lane controls
/// are `Attack`, `Hold`, `Release`, `Curve`, `Volume`, `Pitch`, `Steps`, `Mute`,
/// `Mono`, `Direction`, `Rhythm` — so of the feedback values, `LaneTitle`, `Pitch`,
/// `Attack`, `Hold`, `Release`, `Volume` and `Steps` are lane-scoped, while
/// `Swing` (no per-lane form exists) is deck-scoped.
public struct MX2SamplerLane: Equatable, Sendable {
    /// `LaneTitle` (s) — the sample loaded in this lane.
    public var title = ""
    /// `Pitch` (f −24…24) — lane pitch in semitones.
    public var pitch: Double = 0
    /// `Attack` / `Hold` / `Release` (f 0–1) — envelope.
    public var attack: Double = 0
    public var hold: Double = 0
    public var release: Double = 0
    /// `Volume` (f 0–1) — lane level.
    public var volume: Double = 0
    /// `Steps` (f 1–16) — lane pattern length.
    public var steps: Double = 0

    public init() {}
}

/// `Deck/{n}/Sampler/…` — sampler feedback. Deck-scoped values plus the selected
/// lane (1…8) whose controls `MX2SamplerLane` holds. Value scales are the input
/// routes' own (14.8/14.10): `GlobalPitch` f −12…12, `Swing` f 0–1,
/// `CurrentStep` i (0 when stopped), `SampleProgress` f (−1 when idle),
/// `Speed` 0.5, 1 or 2, and the 0/1 switches `SpeedHalf`, `SpeedDouble`,
/// `VelocityMode`, `FaderStart`.
public struct MX2SamplerState: Equatable, Sendable {
    /// `Lane` (i 1–8) — the selected lane. 0 = none seen yet, which also makes
    /// lane-scoped values unusable until one arrives.
    public var lane = 0
    /// `GlobalPitch` (f −12…12) — transposes the whole sampler.
    public var globalPitch: Double = 0
    /// `Swing` (f 0–1) — pattern swing (pattern-wide, not per lane).
    public var swing: Double = 0
    /// `CurrentStep` (i) — 0 when stopped.
    public var currentStep = 0
    /// `SampleProgress` (f) — −1 when idle.
    public var sampleProgress: Double = -1
    /// `Speed` — 0.5, 1 or 2 (the input route's 0/1/2 index encodes the same
    /// control differently).
    public var speed: Double = 1
    public var speedHalf = false
    public var speedDouble = false
    public var velocityMode = false
    public var faderStart = false
    /// Lane-scoped values keyed by lane 1…8.
    public var lanes: [Int: MX2SamplerLane] = [:]

    public init() {}

    /// Read/write access that never fails: unknown lanes read as defaults and only
    /// materialise once written with a non-default value.
    public subscript(lane lane: Int) -> MX2SamplerLane {
        get { lanes[lane] ?? MX2SamplerLane() }
        set {
            guard (1...8).contains(lane) else { return }
            lanes[lane] = newValue == MX2SamplerLane() ? nil : newValue
        }
    }
}

/// Per-deck feedback. Decks are keyed by Syndicate's own deck number (1…4); the
/// renderer — not this type — decides which of them drive the MX2's two decks.
public struct MX2DeckState: Equatable, Sendable {
    public var cueActive = false
    public var playing = false
    public var loaded = false
    public var playPending = false
    public var sync = false
    public var cueSlip = false
    public var pitchPreserve = false
    public var tempoSlider: Double = 0
    public var playerType = "track"
    public var cues: [MX2Cue] = Array(repeating: MX2Cue(), count: MX2FeedbackState.cueCount)

    /// `Loop` (0/1). Alias of `loopState.on`; kept as the long-standing spelling.
    public var loop: Bool {
        get { loopState.on }
        set { loopState.on = newValue }
    }

    /// `Deck/{n}/TempoSliderEnabled` (i 0/1) — 1 when the tempo slider accepts
    /// control (the deck is the tempo master or SYNC is off), 0 when it doesn't or
    /// the deck is empty. Until one arrives there is no information either way.
    public var tempoSliderEnabled = false
    /// `Deck/{n}/Position` (f, seconds), `Progress` (f, 0–1 through the item) and
    /// `Time` (f, seconds, sent at most once a second).
    public var position: Double = 0
    public var progress: Double = 0
    public var time: Double = 0
    /// `Deck/{n}/BarRamp` (f 0–1 across each bar while the deck moves).
    public var barRamp: Double = 0
    /// `Deck/{n}/PhaseOffset` (f, beats).
    public var phaseOffset: Double = 0
    /// `Deck/{n}/BPM` (f) — current BPM.
    public var bpm: Double = 0
    /// `Deck/{n}/Pitch` (f) — transpose in semitones.
    public var pitch: Double = 0
    /// `LoopStart` / `LoopEnd` (f, seconds) and `LoopInfo` (`i on, f start, f end`)
    /// all fold into here.
    public var loopState = MX2LoopState()
    /// The last `LoopInfo` message as it arrived, or nil if none did (or a bare
    /// `Loop` toggle superseded it). Purely provenance: which of the overlapping
    /// loop addresses last set what.
    public var loopInfo: MX2LoopInfo?
    /// `Deck/{n}/Transport` — `i bar, i beat 1-4` on every beat.
    public var beat = MX2Beat()
    /// `Deck/{n}/Cues` slots beyond the eight hot cues (arrangement decks send
    /// more); those eight live in `cues`.
    public var extraCues: [MX2Cue] = []
    /// `Deck/{n}/CueFire` (i cue) — the hot cue that actually launched.
    public var cueFire = 0
    /// `Deck/{n}/CuePass` (s name, i cue 0-8, i color 0-8).
    public var cuePass = MX2CuePass()
    /// `Deck/{n}/TrackInfo` (s title, s artist, s key, f BPM, f duration, i bars,
    /// i beats, s type).
    public var trackInfo = MX2TrackInfo()
    /// `Deck/{n}/SlipPingPong` (i 0/1) — sent by Syndicate 0.3.10 although 14.10's
    /// feedback list omits it (verified against the binary's `OscFeedback`
    /// registration, which contains it alongside `TempoSliderEnabled`).
    public var slipPingPong = false
    /// `Deck/{n}/Clip/…` (MIDI clip decks).
    public var clip = MX2ClipState()
    /// `Deck/{n}/Arrangement/Transport` — `i bar, i beat` on every beat.
    public var arrangementBeat = MX2Beat()
    /// `Deck/{n}/Arrangement/Lane{1-4}/…`.
    public var arrangementLanes: [Int: MX2ArrangementLane] = [:]
    /// `Deck/{n}/Sampler/…` (sampler decks).
    public var sampler = MX2SamplerState()

    /// `Deck/{n}/Sampler/CurrentStep` — long-standing mirror of
    /// `sampler.currentStep`, kept for the renderer's pad walk.
    public var samplerStep: Int {
        get { sampler.currentStep }
        set { sampler.currentStep = newValue }
    }

    public init() {}

    /// Read/write access that never fails: unknown lanes read as defaults and only
    /// materialise once written with a non-default value.
    public subscript(arrangementLane lane: Int) -> MX2ArrangementLane {
        get { arrangementLanes[lane] ?? MX2ArrangementLane() }
        set {
            guard (1...4).contains(lane) else { return }
            arrangementLanes[lane] = newValue == MX2ArrangementLane() ? nil : newValue
        }
    }
}

/// `Mixer/CH{n}/…` values that have no long-standing accessor of their own
/// (`Meter`, `Cue` and the filter-enabled flags keep their own dictionaries on
/// `MX2FeedbackState`). All 0–1 on the same scales as the input routes (14.9).
public struct MX2MixerChannelState: Equatable, Sendable {
    /// `Volume` (f 0–1) — channel volume.
    public var volume: Double = 0
    /// `Trim` (f 0–1) — 0.5 is 0 dB.
    public var trim: Double = 0
    /// `EQ/Low` · `EQ/Mid` · `EQ/High` (f 0–1) — 0.5 neutral.
    public var eqLow: Double = 0
    public var eqMid: Double = 0
    public var eqHigh: Double = 0
    /// `Filter1` · `Filter2` (f 0–1).
    public var filter1: Double = 0
    public var filter2: Double = 0
    /// `Mute` · `Solo` (i 0/1).
    public var mute = false
    public var solo = false

    public init() {}
}

/// Aggregate feedback state for the whole app.
///
/// `apply(_:)` is the single entry point: it folds one parsed OSC message into the
/// state and reports whether anything actually moved, so a receiver can skip
/// waking the UI or the LED renderer for redundant packets.
public struct MX2FeedbackState: Equatable, Sendable {
    public enum ApplyResult: Equatable, Sendable {
        /// State changed; observers should re-render.
        case changed
        /// Recognised message that left state identical.
        case unchanged
        /// Not ours, or unusable for this address.
        case ignored
        /// `/Syndicate/Feedback/Resend` with a nonzero argument.
        case resendRequested
    }

    public static let root = "Syndicate"
    public static let cueCount = 8
    public static let deckRange = 1...4

    public var decks: [Int: MX2DeckState] = [:]
    /// `/Syndicate/PlayPending` — a global "a start is pending" flag.
    public var playPending = false
    /// `/Syndicate/Loaded` — a global "something is loaded" flag.
    public var loaded = false
    /// `/Syndicate/Sampler/CurrentStep` — global sampler step.
    public var samplerStep = 0
    /// Mixer channel meters keyed by 1-based channel number (`Meter`, 0–1).
    public var meters: [Int: Double] = [:]
    /// `Mixer/CH{n}/Cue` — headphone cue per channel.
    public var headphoneCue: [Int: Bool] = [:]
    /// `Mixer/CH{n}/Filter1Enabled` — filter-1 knob availability per channel.
    public var filterEnabled: [Int: Bool] = [:]
    /// `Mixer/CH{n}/Filter2Enabled` — filter-2 knob availability per channel.
    /// Separate from `filterEnabled`: they are two flags, even if the doc says
    /// both are currently always 1.
    public var filter2Enabled: [Int: Bool] = [:]
    /// `Mixer/CH{n}/…` values with no accessor of their own, per channel.
    public var mixer: [Int: MX2MixerChannelState] = [:]
    public var palette = MX2ColorPalette()
    public var resendRequests = 0

    /// `/Header/BPM` (f) — master tempo.
    public var bpm: Double = 0
    /// `/Header/Clock` (i) — beat in the bar, 1–4, on every master beat. 0 = none.
    public var clockBeat = 0
    /// `/Header/MasterVolume` · `CueVolume` (f 0–1).
    public var masterVolume: Double = 0
    public var cueVolume: Double = 0
    /// `/Header/Metronome` (i 0/1).
    public var metronome = false

    public init() {}

    /// Read/write access that never fails: unknown decks read as defaults and only
    /// materialise once written with a non-default value.
    public subscript(deck deck: Int) -> MX2DeckState {
        get { decks[deck] ?? MX2DeckState() }
        set {
            guard Self.validDeck(deck) else { return }
            decks[deck] = newValue == MX2DeckState() ? nil : newValue
        }
    }

    /// Same never-failing access for mixer channels.
    public subscript(channel channel: Int) -> MX2MixerChannelState {
        get { mixer[channel] ?? MX2MixerChannelState() }
        set {
            guard channel >= 1 else { return }
            mixer[channel] = newValue == MX2MixerChannelState() ? nil : newValue
        }
    }

    public var deckNumbers: [Int] { decks.keys.sorted() }

    public static func validDeck(_ number: Int) -> Bool { deckRange.contains(number) }

    // MARK: - Apply

    @discardableResult
    public mutating func apply(_ message: OSCMessage) -> ApplyResult {
        let components = message.address.split(separator: "/").map(String.init)
        guard components.first == Self.root, components.count >= 2 else { return .ignored }

        // /Syndicate/Feedback/Resend
        if components.count == 3, components[1] == "Feedback", components[2] == "Resend" {
            guard let request = message.flag(0), request else { return .ignored }
            resendRequests += 1
            return .resendRequested
        }

        // Globals
        if components.count == 2 {
            switch components[1] {
            case "PlayPending":
                guard let value = message.flag(0) else { return .ignored }
                return assign(\.playPending, value)
            case "Loaded":
                guard let value = message.flag(0) else { return .ignored }
                return assign(\.loaded, value)
            case "ColorPalette":
                guard let slot = message.int(0), let red = message.int(1),
                      let green = message.int(2), let blue = message.int(3),
                      MX2ColorPalette.valid(slot: slot) else { return .ignored }
                let color = MX2RGB(red: red, green: green, blue: blue)
                guard palette.color(slot: slot) != color else { return .unchanged }
                palette.set(slot: slot, color: color)
                return .changed
            default:
                return .ignored
            }
        }

        // /Syndicate/Header/…
        if components.count == 3, components[1] == "Header" {
            switch components[2] {
            case "BPM":
                guard let value = message.number(0) else { return .ignored }
                return assign(\.bpm, value)
            case "Clock":
                // Beat in the bar, 1–4 (i), on every master beat.
                guard let beat = message.int(0) else { return .ignored }
                return assign(\.clockBeat, beat)
            case "MasterVolume":
                guard let value = message.number(0) else { return .ignored }
                return assign(\.masterVolume, value)
            case "CueVolume":
                guard let value = message.number(0) else { return .ignored }
                return assign(\.cueVolume, value)
            case "Metronome":
                guard let value = message.flag(0) else { return .ignored }
                return assign(\.metronome, value)
            default:
                return .ignored
            }
        }

        // /Syndicate/Sampler/CurrentStep
        if components.count == 3, components[1] == "Sampler" {
            guard components[2] == "CurrentStep", let step = message.int(0) else { return .ignored }
            return assign(\.samplerStep, step)
        }

        // /Syndicate/Mixer/CH{n}/…
        if components.count >= 4, components[1] == "Mixer",
           let channel = Self.channel(from: components[2]) {
            switch (components.count, components[3]) {
            case (4, "Meter"):
                guard let level = message.number(0) else { return .ignored }
                guard meters[channel] != level else { return .unchanged }
                meters[channel] = level
                return .changed
            case (4, "Cue"):
                guard let value = message.flag(0) else { return .ignored }
                guard headphoneCue[channel] != value else { return .unchanged }
                headphoneCue[channel] = value
                return .changed
            case (4, "Filter1Enabled"):
                guard let value = message.flag(0) else { return .ignored }
                guard filterEnabled[channel] != value else { return .unchanged }
                filterEnabled[channel] = value
                return .changed
            case (4, "Filter2Enabled"):
                guard let value = message.flag(0) else { return .ignored }
                guard filter2Enabled[channel] != value else { return .unchanged }
                filter2Enabled[channel] = value
                return .changed
            case (4, "Mute"):
                guard let value = message.flag(0) else { return .ignored }
                return mutateMixer(channel) { $0.mute = value }
            case (4, "Solo"):
                guard let value = message.flag(0) else { return .ignored }
                return mutateMixer(channel) { $0.solo = value }
            case (4, "Volume"):
                guard let value = message.number(0) else { return .ignored }
                return mutateMixer(channel) { $0.volume = value }
            case (4, "Trim"):
                guard let value = message.number(0) else { return .ignored }
                return mutateMixer(channel) { $0.trim = value }
            case (4, "Filter1"):
                guard let value = message.number(0) else { return .ignored }
                return mutateMixer(channel) { $0.filter1 = value }
            case (4, "Filter2"):
                guard let value = message.number(0) else { return .ignored }
                return mutateMixer(channel) { $0.filter2 = value }
            case (5, "EQ"):
                guard let value = message.number(0) else { return .ignored }
                switch components[4] {
                case "Low": return mutateMixer(channel) { $0.eqLow = value }
                case "Mid": return mutateMixer(channel) { $0.eqMid = value }
                case "High": return mutateMixer(channel) { $0.eqHigh = value }
                default: return .ignored
                }
            default:
                return .ignored
            }
        }

        // /Syndicate/Deck/{n}/...
        guard components.count >= 3, components[1] == "Deck",
              let deck = Int(components[2]), Self.validDeck(deck) else { return .ignored }

        if components.count == 4 {
            switch components[3] {
            case "Cues":
                let decoded = Self.decodeCues(message)
                return mutateDeck(deck) {
                    $0.cues = decoded.cues
                    $0.extraCues = decoded.extra
                }
            case "CuePress":
                guard let cue = message.int(0), (1...Self.cueCount).contains(cue),
                      let pressed = message.flag(1) else { return .ignored }
                return mutateDeck(deck) { $0.cues[cue - 1].pressed = pressed }
            case "CueFire":
                guard let cue = message.int(0) else { return .ignored }
                return mutateDeck(deck) { $0.cueFire = cue }
            case "CuePass":
                // `s name, i cue 0-8, i color 0-8` ("", 0, 0 before the first cue).
                guard let name = message.string(0), let cue = message.int(1),
                      let color = message.int(2) else { return .ignored }
                return mutateDeck(deck) {
                    $0.cuePass = MX2CuePass(name: name, cue: cue, color: color)
                }
            case "CueActive", "CueMomentary", "CuePreview":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.cueActive = value }
            case "PlayerType":
                guard let type = message.string(0) else { return .ignored }
                return mutateDeck(deck) { $0.playerType = type }
            case "Playing":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.playing = value }
            case "PlayPending":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.playPending = value }
            case "Loaded":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.loaded = value }
            case "Sync":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.sync = value }
            case "Loop":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) {
                    // A bare toggle supersedes whatever `LoopInfo` reported.
                    $0.loopState.on = value
                    $0.loopInfo = nil
                }
            case "LoopStart":
                // Seconds. Updates the loop point only; `loopInfo` keeps its
                // provenance (the last `LoopInfo` message) untouched.
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.loopState.start = value }
            case "LoopEnd":
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.loopState.end = value }
            case "LoopInfo":
                // `i on, f start, f end` together.
                guard let on = message.flag(0), let start = message.number(1),
                      let end = message.number(2) else { return .ignored }
                return mutateDeck(deck) {
                    $0.loopState = MX2LoopState()
                    $0.loopState.on = on
                    $0.loopState.start = start
                    $0.loopState.end = end
                    $0.loopInfo = MX2LoopInfo(on: on, start: start, end: end)
                }
            case "CueSlip":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.cueSlip = value }
            case "SlipPingPong":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.slipPingPong = value }
            case "PitchPreserve":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.pitchPreserve = value }
            case "TempoSlider":
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.tempoSlider = value }
            case "TempoSliderEnabled":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.tempoSliderEnabled = value }
            case "Position":
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.position = value }
            case "Progress":
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.progress = value }
            case "Time":
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.time = value }
            case "BarRamp":
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.barRamp = value }
            case "PhaseOffset":
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.phaseOffset = value }
            case "BPM":
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.bpm = value }
            case "Pitch":
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.pitch = value }
            case "Transport":
                // `i bar, i beat 1-4` on every beat.
                guard let bar = message.int(0), let beat = message.int(1) else { return .ignored }
                return mutateDeck(deck) { $0.beat = MX2Beat(bar: bar, beat: beat) }
            case "TrackInfo":
                // `s title, s artist, s key, f BPM, f duration, i bars, i beats, s type`.
                guard let title = message.string(0), let artist = message.string(1),
                      let key = message.string(2), let infoBPM = message.number(3),
                      let duration = message.number(4), let bars = message.int(5),
                      let beats = message.int(6), let type = message.string(7) else {
                    return .ignored
                }
                let info = MX2TrackInfo(title: title, artist: artist, key: key,
                                        bpm: infoBPM, duration: duration,
                                        bars: bars, beats: beats, type: type)
                return mutateDeck(deck) { $0.trackInfo = info }
            default:
                return .ignored
            }
        }

        if components.count == 5 {
            switch components[3] {
            case "Clip":
                return applyClip(deck: deck, name: components[4], message: message)
            case "Sampler":
                return applySampler(deck: deck, name: components[4], message: message)
            case "Arrangement":
                guard components[4] == "Transport" else { return .ignored }
                guard let bar = message.int(0), let beat = message.int(1) else { return .ignored }
                return mutateDeck(deck) {
                    $0.arrangementBeat = MX2Beat(bar: bar, beat: beat)
                }
            default:
                return .ignored
            }
        }

        if components.count == 6, components[3] == "Arrangement",
           components[4].hasPrefix("Lane"),
           let lane = Int(components[4].dropFirst(4)), (1...4).contains(lane) {
            // /Syndicate/Deck/{n}/Arrangement/Lane{l}/{Volume,Meter,Route}
            switch components[5] {
            case "Volume":
                guard let value = message.number(0) else { return .ignored }
                return mutateArrangementLane(deck, lane) { $0.volume = value }
            case "Meter":
                guard let value = message.number(0) else { return .ignored }
                return mutateArrangementLane(deck, lane) { $0.meter = value }
            case "Route":
                guard let value = message.int(0) else { return .ignored }
                return mutateArrangementLane(deck, lane) { $0.route = value }
            default:
                return .ignored
            }
        }

        return .ignored
    }

    /// Applies every message in a packet (bare message or bundle) and reports the
    /// strongest outcome: any change wins, otherwise a resend request, then unchanged.
    @discardableResult
    public mutating func apply(_ data: Data) -> ApplyResult {
        let messages = OSCMessage.parseAll(data)
        guard !messages.isEmpty else { return .ignored }
        var result = ApplyResult.ignored
        for message in messages {
            switch apply(message) {
            case .changed: result = .changed
            case .resendRequested:
                if result != .changed { result = .resendRequested }
            case .unchanged:
                if result == .ignored { result = .unchanged }
            case .ignored:
                break
            }
        }
        return result
    }

    // MARK: - Clip and sampler feedback

    private mutating func applyClip(deck: Int, name: String,
                                    message: OSCMessage) -> ApplyResult {
        switch name {
        case "Loop":
            guard let value = message.flag(0) else { return .ignored }
            return mutateDeck(deck) { $0.clip.loop = value }
        case "Pitch":
            guard let value = message.number(0) else { return .ignored }
            return mutateDeck(deck) { $0.clip.pitch = value }
        case "MidiOut":
            guard let value = message.flag(0) else { return .ignored }
            return mutateDeck(deck) { $0.clip.midiOut = value }
        case "MidiOutDevice":
            guard let value = message.int(0) else { return .ignored }
            return mutateDeck(deck) { $0.clip.midiOutDevice = value }
        case "MidiChannel":
            guard let value = message.int(0) else { return .ignored }
            return mutateDeck(deck) { $0.clip.midiChannel = value }
        default:
            return .ignored
        }
    }

    private mutating func applySampler(deck: Int, name: String,
                                       message: OSCMessage) -> ApplyResult {
        switch name {
        case "Lane":
            // 1…8 as the feedback docs define it (the input route's index is 0–7).
            guard let value = message.int(0), (1...8).contains(value) else { return .ignored }
            return mutateDeck(deck) { $0.sampler.lane = value }
        case "GlobalPitch":
            guard let value = message.number(0) else { return .ignored }
            return mutateDeck(deck) { $0.sampler.globalPitch = value }
        case "Swing":
            guard let value = message.number(0) else { return .ignored }
            return mutateDeck(deck) { $0.sampler.swing = value }
        case "CurrentStep":
            guard let value = message.int(0) else { return .ignored }
            return mutateDeck(deck) { $0.sampler.currentStep = value }
        case "SampleProgress":
            guard let value = message.number(0) else { return .ignored }
            return mutateDeck(deck) { $0.sampler.sampleProgress = value }
        case "Speed":
            guard let value = message.number(0) else { return .ignored }
            return mutateDeck(deck) { $0.sampler.speed = value }
        case "SpeedHalf":
            guard let value = message.flag(0) else { return .ignored }
            return mutateDeck(deck) { $0.sampler.speedHalf = value }
        case "SpeedDouble":
            guard let value = message.flag(0) else { return .ignored }
            return mutateDeck(deck) { $0.sampler.speedDouble = value }
        case "VelocityMode":
            guard let value = message.flag(0) else { return .ignored }
            return mutateDeck(deck) { $0.sampler.velocityMode = value }
        case "FaderStart":
            guard let value = message.flag(0) else { return .ignored }
            return mutateDeck(deck) { $0.sampler.faderStart = value }
        case "LaneTitle":
            guard let value = message.string(0) else { return .ignored }
            return mutateSamplerLane(deck) { $0.title = value }
        case "Pitch":
            guard let value = message.number(0) else { return .ignored }
            return mutateSamplerLane(deck) { $0.pitch = value }
        case "Attack":
            guard let value = message.number(0) else { return .ignored }
            return mutateSamplerLane(deck) { $0.attack = value }
        case "Hold":
            guard let value = message.number(0) else { return .ignored }
            return mutateSamplerLane(deck) { $0.hold = value }
        case "Release":
            guard let value = message.number(0) else { return .ignored }
            return mutateSamplerLane(deck) { $0.release = value }
        case "Volume":
            guard let value = message.number(0) else { return .ignored }
            return mutateSamplerLane(deck) { $0.volume = value }
        case "Steps":
            guard let value = message.number(0) else { return .ignored }
            return mutateSamplerLane(deck) { $0.steps = value }
        default:
            return .ignored
        }
    }

    // MARK: - Mutation helpers

    private mutating func assign<T: Equatable>(_ keyPath: WritableKeyPath<MX2FeedbackState, T>,
                                               _ value: T) -> ApplyResult {
        guard self[keyPath: keyPath] != value else { return .unchanged }
        self[keyPath: keyPath] = value
        return .changed
    }

    /// Mutates one deck, dropping the entry again if it returns to all-defaults so
    /// that "no feedback yet" and "explicitly off" stay indistinguishable.
    private mutating func mutateDeck(_ deck: Int,
                                     _ body: (inout MX2DeckState) -> Void) -> ApplyResult {
        let before = decks[deck] ?? MX2DeckState()
        var updated = before
        body(&updated)
        guard updated != before else { return .unchanged }
        decks[deck] = updated == MX2DeckState() ? nil : updated
        return .changed
    }

    /// Mutates the selected sampler lane of one deck: lane-scoped values land on
    /// the lane `sampler.lane` currently names. Without a `Lane` message there is
    /// nothing to attribute them to, so they are unusable and ignored.
    private mutating func mutateSamplerLane(_ deck: Int,
                                            _ body: (inout MX2SamplerLane) -> Void) -> ApplyResult {
        let lane = (decks[deck] ?? MX2DeckState()).sampler.lane
        guard (1...8).contains(lane) else { return .ignored }
        return mutateDeck(deck) { state in
            var laneState = state.sampler.lanes[lane] ?? MX2SamplerLane()
            body(&laneState)
            state.sampler.lanes[lane] = laneState == MX2SamplerLane() ? nil : laneState
        }
    }

    private mutating func mutateArrangementLane(_ deck: Int, _ lane: Int,
                                                _ body: (inout MX2ArrangementLane) -> Void) -> ApplyResult {
        mutateDeck(deck) { state in
            var laneState = state.arrangementLanes[lane] ?? MX2ArrangementLane()
            body(&laneState)
            state.arrangementLanes[lane] = laneState == MX2ArrangementLane() ? nil : laneState
        }
    }

    private mutating func mutateMixer(_ channel: Int,
                                      _ body: (inout MX2MixerChannelState) -> Void) -> ApplyResult {
        let before = mixer[channel] ?? MX2MixerChannelState()
        var updated = before
        body(&updated)
        guard updated != before else { return .unchanged }
        mixer[channel] = updated == MX2MixerChannelState() ? nil : updated
        return .changed
    }

    /// Decodes the `/Cues` payload into exactly 8 hot-cue slots plus any pairs
    /// beyond them (arrangement decks send more slots than the eight hot cues).
    /// A short payload fills from the start and leaves the rest empty; a trailing
    /// colour without a name is dropped.
    static func decodeCues(_ message: OSCMessage) -> (cues: [MX2Cue], extra: [MX2Cue]) {
        var cues = Array(repeating: MX2Cue(), count: cueCount)
        var extra: [MX2Cue] = []
        var index = 0
        var argument = 0
        while argument + 1 < message.arguments.count {
            guard let color = message.int(argument),
                  let name = message.string(argument + 1) else { break }
            let cue = MX2Cue(color: color, name: name)
            if index < cueCount {
                cues[index] = cue
            } else {
                extra.append(cue)
            }
            index += 1
            argument += 2
        }
        return (cues, extra)
    }

    /// `CH1` → 1. Only positive channel numbers are meaningful.
    static func channel(from component: String) -> Int? {
        guard component.hasPrefix("CH") else { return nil }
        guard let value = Int(component.dropFirst(2)), value >= 1 else { return nil }
        return value
    }
}
