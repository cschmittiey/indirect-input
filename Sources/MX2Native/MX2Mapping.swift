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
                      cueActive: [Bool] = [false, false],
                      headphoneCue: [Bool] = [false, false]) -> [OSCMessage] {
        switch event {
        case let .button(control, pressed):
            return button(control, pressed: pressed, bank: bank, shift: shift, jogMode: jogMode,
                          cueActive: cueActive, headphoneCue: headphoneCue)
        case let .analog(control, raw):
            return analog(control, raw: raw)
        case let .encoder(control, delta):
            return encoder(control, delta: delta, shift: shift)
        case let .jog(side, delta):
            let deck = self.deck(side)
            let sign: Int32 = delta > 0 ? 1 : delta < 0 ? -1 : 0
            return [message("/Deck/\(deck)/PhaseBend", int: sign)]
        }
    }

    private func button(_ control: MX2Control, pressed: Bool,
                        bank: [MX2PadBank], shift: [Bool], jogMode: [Bool],
                        cueActive: [Bool], headphoneCue: [Bool]) -> [OSCMessage] {
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
            return [message("/Deck/\(self.deck(side))/PitchPreserve")]
        case let .flux(side):
            guard pressed else { return [] }
            return [message("/Deck/\(self.deck(side))/CueSlip")]
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
                guard pressed else { return [] }
                return [message("/Mixer/CH\(deck)/FX/Macro/\(index)", float: 1)]
            case .pattern:
                return [] // Lane triggering uses Sampler/LaneSet in a later patch.
            case .loops:
                let sizes = ["ThirtySecond", "Sixteenth", "Eighth", "Quarter", "Half", "One", "Two", "Four"]
                return [message("/Deck/\(deck)/SlipLoop/\(sizes[index - 1])", int: pressed ? 1 : 0)]
            }
        case let .fxButton(side, index):
            guard pressed else { return [] }
            let deck = self.deck(side)
            if index == 1 {
                return [message("/Mixer/CH\(deck)/FX", int: 1)]
            }
            return [message("/Mixer/CH\(deck)/FX/Macro/\(index - 1)", float: 1)]
        case let .fxAssign(side, index):
            guard pressed else { return [] }
            return [message("/Mixer/CH\(self.deck(side))/FX/Macro/\(index)", float: 1)]
        case let .channelFX(side):
            return [message("/Mixer/CH\(self.deck(side))/FX", int: pressed ? 1 : 0)]
        case let .headphone(side):
            guard pressed else { return [] }
            return [message("/Mixer/CH\(self.deck(side))/Cue", int: headphoneCue[side.rawValue] ? 1 : 0)]
        case let .globalFX(index):
            guard pressed else { return [] }
            return [message("/Mixer/CH\(firstDeck)/FX/Macro/\(index)", float: 1)]
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
            guard pressed else { return [] }
            return [message("/Browser/Preview", int: 1)]
        case .view:
            guard pressed else { return [] }
            return [message("/Header/Browser", int: 1)]
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
            return [] // Jog touch is intentionally non-destructive in v1.
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
