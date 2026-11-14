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

/// Per-deck feedback. Decks are keyed by Syndicate's own deck number (1…4); the
/// renderer — not this type — decides which of them drive the MX2's two decks.
public struct MX2DeckState: Equatable, Sendable {
    public var cueActive = false
    public var playing = false
    public var loaded = false
    public var playPending = false
    public var sync = false
    public var loop = false
    public var cueSlip = false
    public var pitchPreserve = false
    public var tempoSlider: Double = 0
    public var cues: [MX2Cue] = Array(repeating: MX2Cue(), count: MX2FeedbackState.cueCount)

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
    public var samplerStep = 0
    /// Mixer channel meters keyed by 1-based channel number.
    public var meters: [Int: Double] = [:]
    public var headphoneCue: [Int: Bool] = [:]
    public var filterEnabled: [Int: Bool] = [:]
    public var palette = MX2ColorPalette()
    public var resendRequests = 0

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

        // /Syndicate/Sampler/CurrentStep
        if components.count == 3, components[1] == "Sampler" {
            guard components[2] == "CurrentStep", let step = message.int(0) else { return .ignored }
            return assign(\.samplerStep, step)
        }

        // /Syndicate/Mixer/CH{n}/{Meter,Cue,Filter1Enabled}
        if components.count == 4, components[1] == "Mixer",
           let channel = Self.channel(from: components[2]) {
            switch components[3] {
            case "Meter":
                guard let level = message.number(0) else { return .ignored }
                guard meters[channel] != level else { return .unchanged }
                meters[channel] = level
                return .changed
            case "Cue", "Filter1Enabled":
                guard let value = message.flag(0) else { return .ignored }
                if components[3] == "Cue" {
                    guard headphoneCue[channel] != value else { return .unchanged }
                    headphoneCue[channel] = value
                } else {
                    guard filterEnabled[channel] != value else { return .unchanged }
                    filterEnabled[channel] = value
                }
                return .changed
            default:
                break
            }
        }

        // /Syndicate/Deck/{n}/...
        guard components.count >= 3, components[1] == "Deck",
              let deck = Int(components[2]), Self.validDeck(deck) else { return .ignored }

        if components.count == 4 {
            switch components[3] {
            case "Cues":
                let cues = Self.decodeCues(message)
                guard !cues.isEmpty else { return .ignored }
                return mutateDeck(deck) { $0.cues = cues }
            case "CuePress":
                guard let index = message.int(0), (0..<Self.cueCount).contains(index),
                      let pressed = message.flag(1) else { return .ignored }
                return mutateDeck(deck) { $0.cues[index].pressed = pressed }
            case "CueActive", "CueMomentary", "CuePreview":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.cueActive = value }
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
                return mutateDeck(deck) { $0.loop = value }
            case "CueSlip":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.cueSlip = value }
            case "PitchPreserve":
                guard let value = message.flag(0) else { return .ignored }
                return mutateDeck(deck) { $0.pitchPreserve = value }
            case "TempoSlider":
                guard let value = message.number(0) else { return .ignored }
                return mutateDeck(deck) { $0.tempoSlider = value }
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

    /// Decodes the 16-argument `/Cues` payload into exactly 8 slots. A short payload
    /// fills from the start and leaves the rest empty; a trailing colour without a
    /// name is dropped.
    static func decodeCues(_ message: OSCMessage) -> [MX2Cue] {
        var cues = Array(repeating: MX2Cue(), count: cueCount)
        var index = 0
        var argument = 0
        while index < cueCount, argument + 1 < message.arguments.count {
            guard let color = message.int(argument),
                  let name = message.string(argument + 1) else { return cues }
            cues[index] = MX2Cue(color: color, name: name)
            index += 1
            argument += 2
        }
        return cues
    }

    /// `CH1` → 1. Only positive channel numbers are meaningful.
    static func channel(from component: String) -> Int? {
        guard component.hasPrefix("CH") else { return nil }
        guard let value = Int(component.dropFirst(2)), value >= 1 else { return nil }
        return value
    }
}
