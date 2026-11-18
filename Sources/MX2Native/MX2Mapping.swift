import Foundation
import BridgeCore

public struct MX2Mapping: Sendable {
    public var firstDeck: Int = 1
    public var crossfaderCurve: Double = 1

    public init() {}

    public func deck(_ side: MX2Side) -> Int {
        firstDeck + side.rawValue
    }

    public func route(_ event: MX2InputEvent,
                      bank: [MX2PadBank],
                      shift: [Bool],
                      jogMode: [Bool],
                      cueActive: [Int: Bool] = [:],
                      headphoneCue: [Int: Bool] = [:],
                      pitchPreserve: [Int: Bool] = [:],
                      cueSlip: [Int: Bool] = [:],
                      fxEnabled: [Int: Bool] = [:],
                      browserMode: Int = 0,
                      samplerMute: [Int: [Int: Bool]] = [:],
                      jogTouch: [Bool] = [false, false],
                      jogPosition: [Int: Double] = [:]) -> [OSCMessage] {
        switch event {
        case let .button(control, pressed):
            return button(control, pressed: pressed, bank: bank, shift: shift, jogMode: jogMode,
                          cueActive: cueActive, headphoneCue: headphoneCue,
                          pitchPreserve: pitchPreserve, cueSlip: cueSlip, fxEnabled: fxEnabled,
                          browserMode: browserMode, samplerMute: samplerMute)
        case let .analog(control, raw):
            return analog(control, raw: raw)
        case let .encoder(control, delta):
            return encoder(control, delta: delta, shift: shift)
        case let .jog(side, delta):
            let deck = self.deck(side)
            if shift[side.rawValue] {
                guard delta != 0 else { return [] }
                // OSC §14.6: these are Triggers, NOT the WaveformZoom Step route.
                let direction = delta > 0 ? "In" : "Out"
                return [message("/Deck/\(deck)/WaveformZoom\(direction)")]
            }
            if jogTouch[side.rawValue] {
                guard delta != 0 else { return [] }
                // OSC §14.6: absolute track position, quantized when Q is on.
                // This is seek/scrub, not a vinyl velocity/scratch API.
                let position = Self.clampedJogPosition(jogPosition[deck, default: 0])
                return [message("/Deck/\(deck)/WaveformSeek", float: Float(position))]
            }
            // OSC §§14.3/14.6: Bend consumes ONLY the sign, not speed/magnitude;
            // zero releases. Sending larger numbers cannot bend harder.
            let sign: Int32 = delta > 0 ? 1 : delta < 0 ? -1 : 0
            return [message("/Deck/\(deck)/PhaseBend", int: sign)]
        }
    }

    static func clampedJogPosition(_ position: Double) -> Double {
        guard position.isFinite else { return 0 }
        return min(1, max(0, position))
    }

    private func button(_ control: MX2Control, pressed: Bool,
                        bank: [MX2PadBank], shift: [Bool], jogMode: [Bool],
                        cueActive: [Int: Bool], headphoneCue: [Int: Bool],
                        pitchPreserve: [Int: Bool], cueSlip: [Int: Bool],
                        fxEnabled: [Int: Bool], browserMode: Int,
                        samplerMute: [Int: [Int: Bool]]) -> [OSCMessage] {
        switch control {
        case let .play(side):
            guard pressed else { return [] }
            let deck = self.deck(side)
            return shift[side.rawValue]
                ? [message("/Deck/\(deck)/GridStart")]
                : [message("/Deck/\(deck)/PlayPause")]
        case let .cue(side):
            return [message("/Deck/\(self.deck(side))/Cue", int: pressed ? 1 : 0)]
        case let .sync(side):
            guard pressed else { return [] }
            return [message("/Deck/\(self.deck(side))/TempoSync")]
        case let .master(side):
            guard pressed else { return [] }
            return [message("/Deck/\(self.deck(side))/TempoMaster")]
        case let .keyLock(side):
            guard pressed else { return [] }
            let deck = self.deck(side)
            return [message("/Deck/\(deck)/PitchPreserve", int: pitchPreserve[deck, default: false] ? 1 : 0)]
        case let .flux(side):
            guard pressed else { return [] }
            let deck = self.deck(side)
            return [message("/Deck/\(deck)/CueSlip", int: cueSlip[deck, default: false] ? 1 : 0)]
        case let .reverse(side):
            return [message("/Deck/\(self.deck(side))/Reverse", int: pressed ? 1 : 0)]
        case let .bank(side, bank):
            return pressed ? [] : [] // Pad-bank state is local to the bridge.
        case let .pad(side, index):
            guard (1...8).contains(index) else { return [] }
            let deck = self.deck(side)
            let shifted = shift[side.rawValue]
            switch bank[side.rawValue] {
            case .hotcues:
                if shifted {
                    return pressed ? [message("/Deck/\(deck)/SetCueLoop", int: Int32(index))] : []
                }
                return [message("/Deck/\(deck)/HotCue", arguments: [.int(Int32(index)), .int(pressed ? 1 : 0)])]
            case .stems:
                // 0.3.10 documents no stem-control OSC routes. FX macros operate
                // channel inserts, not stems; do not modify unrelated effects.
                return []
            case .pattern:
                guard pressed else { return [] }
                if shifted {
                    // LaneSet takes a ONE-based lane and does not change selection.
                    let muted = samplerMute[deck]?[index] ?? false
                    return [message("/Deck/\(deck)/Sampler/LaneSet", arguments: [
                        .int(Int32(index)), .string("Mute"), .float(muted ? 1 : 0)
                    ])]
                }
                // Lane is a zero-based selection index, not a sample trigger.
                return [message("/Deck/\(deck)/Sampler/Lane", int: Int32(index - 1))]
            case .loops:
                let sizes = ["ThirtySecond", "Sixteenth", "Eighth", "Quarter", "Half", "One", "Two", "Four"]
                return [message("/Deck/\(deck)/SlipLoop/\(sizes[index - 1])", int: pressed ? 1 : 0)]
            }
        case let .fxButton(side, index):
            guard pressed else { return [] }
            // Verified on hardware: FX 1-4 are bits 60/61 (+64/65 right) and the GFX
            // toggle is a separate physical button at 62/66. Syndicate exposes exactly
            // one insert-chain Switch per channel (OSC §14.9 `/Mixer/CH{n}/FX`), and
            // that belongs to the GFX toggle. Letting FX 1-4 share it would make two
            // different buttons cancel each other. FX 2-4 likewise have no generic
            // on/off target: FX/Macro/{1-8} are continuous Values, not effect switches.
            _ = side
            _ = index
            return []
        case let .fxAssign(side, index):
            guard pressed else { return [] }
            return [message("/Mixer/CH\(self.deck(side))/FX/Macro/\(index)", float: 1)]
        case let .channelFX(side):
            guard pressed else { return [] }
            // Repurpose the hardware GFX toggle as the insert-chain Switch
            // documented in OSC 0.3.10 §14.9; it must not bypass on release.
            let deck = self.deck(side)
            return [message("/Mixer/CH\(deck)/FX", int: fxEnabled[deck, default: false] ? 1 : 0)]
        case let .headphone(side):
            guard pressed else { return [] }
            return [message("/Mixer/CH\(self.deck(side))/Cue", int: headphoneCue[self.deck(side), default: false] ? 1 : 0)]
        case .globalFX:
            // Hardware GFX 1–4 select a Quick Effect preset for both decks.
            // OSC 0.3.10 §14.9 has no preset selector: FX is an insert-chain
            // Switch and FX/Macro/{1-8} are continuous insert values, not presets.
            // Legacy native FX routes are accepted but do nothing. No substitute.
            return []
        case .filter:
            // The MX2's centre filter is audio-only. `Filter1` is a bipolar 0-1
            // value (0.5 neutral), so 0.5 expresses "no change" rather than the
            // dead `filter{n}.cut` address this used to target. Re-centring the
            // filter on every press is out-of-scope for a momentary button.
            return []
        case .microphone:
            return []
        case let .favorite(side):
            guard pressed else { return [] }
            return [message("/Browser/Navigation/Left")]
        case let .addToList(side):
            guard pressed else { return [] }
            return [message("/Browser/Navigation/Enter")]
        case .preview:
            // Intent: load/play the selected track in the preview deck.
            // OSC 0.3.10 §14.5 has no route for this; Browser/Preview does not exist.
            return []
        case .view:
            guard pressed else { return [] }
            // OSC 0.3.10 §14.4: Index 0 hidden, 1 embedded, 2 detached.
            return [message("/Header/Browser", int: Int32(browserMode))]
        case let .browsePress(side):
            guard pressed else { return [] }
            return [message("/Browser/L\(self.deck(side))")]
        case let .movePress(side):
            guard pressed else { return [] }
            return [message("/Deck/\(self.deck(side))/LoopIn")]
        case let .sizePress(side):
            guard pressed else { return [] }
            return [message("/Deck/\(self.deck(side))/Loop")]
        case .turntable, .jogMode, .shift:
            return [] // Local mode state, never an accidental deck action.
        case .jogTouch:
            return [] // Touch gates jog routing; the controller owns its state.
        }
    }

    private func analog(_ control: MX2Analog, raw: UInt16) -> [OSCMessage] {
        let value = Float(raw) / 4095
        switch control {
        case let .fxKnob(side, index):
            let deck = self.deck(side)
            return index == 1
                ? [message("/Mixer/CH\(deck)/FX/Macro/1", float: value)]
                : [message("/Mixer/CH\(deck)/FX/Macro/\(index)", float: value)]
        case let .gain(side): return [message("/Mixer/CH\(self.deck(side))/Trim", float: value)]
        case let .eqHigh(side): return [message("/Mixer/CH\(self.deck(side))/EQ/High", float: value)]
        case let .eqMid(side): return [message("/Mixer/CH\(self.deck(side))/EQ/Mid", float: value)]
        case let .eqLow(side): return [message("/Mixer/CH\(self.deck(side))/EQ/Low", float: value)]
        // The MX2's channel filter knob is bipolar with a centre detent, and a raw
        // 0-4095 reading already normalises to 0..1 with 0.5 at the detent — exactly
        // what `Filter1` wants. The old `filter{n}.cut` address was dropped from
        // Syndicate 0.3.10, so this knob was sending into the void.
        case let .channelFX(side):
            return [message("/Mixer/CH\(self.deck(side))/Filter1", float: value)]
        case .mainVolume: return [message("/Header/MasterVolume", float: value)]
        case .cueMix: return [message("/Header/CueMix", float: value)]
        case .cueVolume: return [message("/Header/CueVolume", float: value)]
        case let .volume(side): return [message("/Mixer/CH\(self.deck(side))/Volume", float: value)]
        case .crossfader:
            // Syndicate 0.3.10 exposes no OSC crossfader control. Do not emulate
            // channel volumes: the app's own crossfader lock can override them.
            return []
        case let .tempo(side):
            return [message("/Deck/\(self.deck(side))/TempoSlider", float: value * 2 - 1)]
        }
    }

    private func encoder(_ control: MX2Encoder, delta: Int, shift: [Bool]) -> [OSCMessage] {
        switch control {
        case let .browse(side):
            let forward = delta > 0
            let direction = shift[side.rawValue]
                ? (forward ? "Right" : "Left")
                : (forward ? "Down" : "Up")
            return Array(repeating: message("/Browser/Navigation/\(direction)"), count: abs(delta))
        case let .move(side):
            return [message("/Deck/\(self.deck(side))/BeatSkip", int: Int32(delta))]
        case let .size(side):
            let deck = self.deck(side)
            if shift[side.rawValue] {
                return [message("/Deck/\(deck)/LoopMoveBeat", int: Int32(delta))]
            }
            let direction = delta > 0 ? "Out" : "In"
            return Array(repeating: message("/Deck/\(deck)/Loop\(direction)"), count: abs(delta))
        }
    }

    private func message(_ path: String, int: Int32 = 1) -> OSCMessage {
        OSCMessage(address: "/Syndicate" + path, integer: int)
    }

    private func message(_ path: String, float: Float) -> OSCMessage {
        OSCMessage(address: "/Syndicate" + path, float: float)
    }

    private func message(_ path: String, arguments: [OSCArgument]) -> OSCMessage {
        OSCMessage(address: "/Syndicate" + path, arguments: arguments)
    }
}
