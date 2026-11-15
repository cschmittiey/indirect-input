import Foundation

// MARK: - LED colour

/// MX2 Native LED colour codes. The wire value is `paletteValue * 4`, plus 2 when the
/// LED is lit, so an LED can be shown dim (colour visible, unlit) or bright.
public enum MX2LEDColor: Int, CaseIterable, Sendable {
    case off = 0
    case red = 1
    case orange = 3
    case yellow = 5
    case green = 7
    case cyan = 9
    case blue = 11
    case purple = 14
    case magenta = 15
    case white = 18

    /// Encoded byte: `rawValue * 4 + (lit ? 2 : 0)`. `.off` is always 0.
    public func byte(lit: Bool) -> UInt8 {
        guard self != .off else { return 0 }
        return UInt8(rawValue * 4 + (lit ? 2 : 0))
    }

    /// Representative RGB used to match Syndicate's palette against the MX2's fixed
    /// colour set.
    public var referenceRGB: MX2RGB {
        switch self {
        case .off: return MX2RGB(red: 0, green: 0, blue: 0)
        case .red: return MX2RGB(red: 255, green: 0, blue: 0)
        case .orange: return MX2RGB(red: 255, green: 128, blue: 0)
        case .yellow: return MX2RGB(red: 255, green: 255, blue: 0)
        case .green: return MX2RGB(red: 0, green: 255, blue: 0)
        case .cyan: return MX2RGB(red: 0, green: 255, blue: 255)
        case .blue: return MX2RGB(red: 0, green: 0, blue: 255)
        case .purple: return MX2RGB(red: 128, green: 0, blue: 255)
        case .magenta: return MX2RGB(red: 255, green: 0, blue: 255)
        case .white: return MX2RGB(red: 255, green: 255, blue: 255)
        }
    }

    /// Deliberately outside the palette the hardware uses for real state, so an
    /// unmapped control can never be mistaken for a genuinely lit one. Rendered only
    /// at `dim`, never `lit`.
    public static let dimUnmapped: MX2LEDColor = .magenta

    /// Closest MX2 colour for an arbitrary RGB value (near-black maps to `.off`).
    public static func nearest(to rgb: MX2RGB) -> MX2LEDColor {
        if rgb.red + rgb.green + rgb.blue < 24 { return .off }
        return allCases
            .filter { $0 != .off }
            .min { lhs, rhs in
                squaredDistance(lhs.referenceRGB, rgb) < squaredDistance(rhs.referenceRGB, rgb)
            } ?? .white
    }

    private static func squaredDistance(_ lhs: MX2RGB, _ rhs: MX2RGB) -> Int {
        let dr = lhs.red - rhs.red
        let dg = lhs.green - rhs.green
        let db = lhs.blue - rhs.blue
        return dr * dr + dg * dg + db * db
    }

    /// Syndicate's `/Cues` colour slot (0…8) → MX2 colour, without palette data.
    /// 0 is "empty"; 1 red, 2 orange, 3 yellow, 4 green, 5 cyan, 6 blue, 7 purple,
    /// 8 white. This is the RGB fallback used when only Playing/Cues/loop are known.
    public static func fromCueSlot(_ slot: Int) -> MX2LEDColor {
        switch slot {
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        case 4: return .green
        case 5: return .cyan
        case 6: return .blue
        case 7: return .purple
        case 8: return .white
        default: return .off
        }
    }

    /// Resolves a cue slot, preferring the app-supplied `/ColorPalette` RGB when that
    /// slot's RGB is known and falling back to the fixed slot table otherwise.
    public static func cueColor(slot: Int, palette: MX2ColorPalette) -> MX2LEDColor {
        guard slot != 0 else { return .off }
        if let rgb = palette.color(slot: slot) {
            let matched = nearest(to: rgb)
            if matched != .off { return matched }
        }
        return fromCueSlot(slot)
    }
}

// MARK: - Layout

/// Byte layout of the MX2's 105-byte Native LED frame.
///
/// IDs are the firmware's 1-based LED numbers; the frame stores them at `id - 1`, so
/// a 105-byte array covers IDs 1…105. IDs 61…73 stay 0 except the established
/// headphone-Cue IDs 64 and 68; IDs 86 and 105 are also unused and stay 0.
public enum MX2LEDLayout {
    public static let byteCount = 105

    /// Physical deck A (left) LED ID base.
    public static let deckABase = 1
    /// Physical deck B (right) LED ID base.
    public static let deckBBase = 31
    public static let controlsPerDeck = 30

    /// Under-shell (deck glow) LED IDs: A 74…79, B 80…85.
    public static let undershellABase = 74
    public static let undershellBBase = 80
    public static let undershellCount = 6

    /// Channel meter LED IDs: A 87…95, B 96…104.
    public static let meterABase = 87
    public static let meterBBase = 96
    public static let meterCount = 9

    /// Physical deck number (1 = A, 2 = B) → LED ID base.
    public static func deckBase(_ physicalDeck: Int) -> Int {
        physicalDeck == 2 ? deckBBase : deckABase
    }

    public static func undershellBase(_ physicalDeck: Int) -> Int {
        physicalDeck == 2 ? undershellBBase : undershellABase
    }

    public static func meterBase(_ physicalDeck: Int) -> Int {
        physicalDeck == 2 ? meterBBase : meterABase
    }

    /// Frame index for a firmware LED ID. `nil` for IDs outside the frame.
    public static func byteIndex(id: Int) -> Int? {
        (1...byteCount).contains(id) ? id - 1 : nil
    }

    /// Firmware LED ID for a control on a physical deck.
    public static func id(physicalDeck: Int, control: MX2Control) -> Int {
        // `MX2Control.rawValue` is already the 0-based offset from the deck base.
        deckBase(physicalDeck) + control.rawValue
    }

    /// Frame offset for a control on a physical deck (LED ID minus one).
    public static func index(physicalDeck: Int, control: MX2Control) -> Int {
        id(physicalDeck: physicalDeck, control: control) - 1
    }
}

/// Controls inside one deck's 30-LED block, as offsets from the deck base.
public enum MX2Control: Int, CaseIterable, Sendable {
    case fx1 = 0
    case fx2 = 1
    case fx3 = 2
    case fx4 = 3
    case favorite = 4
    case add = 5
    case preview = 6
    case view = 7
    case flux = 8
    case reverse = 9
    case turntable = 10
    case jog = 11
    case shift = 12
    case sync = 13
    case master = 14
    case keylock = 15
    case hotcues = 16
    case stems = 17
    case pattern = 18
    case loops = 19
    case pad1 = 20
    case pad2 = 21
    case pad3 = 22
    case pad4 = 23
    case pad5 = 24
    case pad6 = 25
    case pad7 = 26
    case pad8 = 27
    case cue = 28
    case play = 29

    /// Pad controls in index order, so `pads[0]` is the leftmost pad.
    public static let pads: [MX2Control] = [.pad1, .pad2, .pad3, .pad4,
                                           .pad5, .pad6, .pad7, .pad8]

    public static func pad(_ index: Int) -> MX2Control? { pads[safe: index] }
}

// MARK: - Context

/// Which Syndicate decks drive the MX2's two physical decks. Defaults match the
/// common two-deck layout but is never hardcoded into the renderer's state handling.
public struct MX2DeckAssignment: Equatable, Sendable {
    /// Syndicate deck number (1…4) shown on physical deck A (left).
    public var deckA: Int
    /// Syndicate deck number (1…4) shown on physical deck B (right).
    public var deckB: Int

    public init(deckA: Int = 1, deckB: Int = 2) {
        self.deckA = deckA
        self.deckB = deckB
    }

    public func deck(for physicalDeck: Int) -> Int {
        physicalDeck == 2 ? deckB : deckA
    }
}

/// The pad bank currently shown on the MX2's pads.
public enum MX2PadMode: String, CaseIterable, Sendable {
    case hotcues
    case loops
    case stems
    case pattern
}

/// Everything the renderer needs that does not come from OSC feedback.
public struct MX2RenderContext: Equatable, Sendable {
    public var deckAssignment: MX2DeckAssignment
    public var padMode: MX2PadMode
    /// Hardware Shift state; also previews the shift layer on the pads.
    public var shiftPressed: Bool
    /// Physical deck (1 or 2) → pad indices (0…7) currently held on the hardware.
    public var heldPads: [Int: Set<Int>]
    /// Physical deck currently acting as master, if known; lights its MASTER LED.
    public var masterPhysicalDeck: Int?
    /// Physical deck → mixer channel used for its meter. Defaults to the assigned
    /// Syndicate deck number (deck 1 → CH1).
    public var meterChannel: [Int: Int]
    /// Locally tracked transport preview, per physical deck.
    public var cueActive: [Int: Bool]
    /// Mixer headphone Cue is distinct from transport preview.
    public var headphoneCue: [Int: Bool]

    public init(deckAssignment: MX2DeckAssignment = MX2DeckAssignment(),
                padMode: MX2PadMode = .hotcues,
                shiftPressed: Bool = false,
                heldPads: [Int: Set<Int>] = [:],
                masterPhysicalDeck: Int? = nil,
                meterChannel: [Int: Int] = [:],
                cueActive: [Int: Bool] = [:],
                headphoneCue: [Int: Bool] = [:]) {
        self.deckAssignment = deckAssignment
        self.padMode = padMode
        self.shiftPressed = shiftPressed
        self.heldPads = heldPads
        self.masterPhysicalDeck = masterPhysicalDeck
        self.meterChannel = meterChannel
        self.cueActive = cueActive
        self.headphoneCue = headphoneCue
    }
}

/// Mixer section lamp IDs.
///
/// The mixer's 13 lamps occupy IDs 61-73, one per button, and they are offset by
/// exactly +1 from the corresponding BUTTON ids (button 60 -> lamp 61). Both facts
/// were measured: the mixer buttons were identified by pressing them (bits
/// 60-73), and the lamp block was identified by lighting 61-73 and having the
/// owner confirm the whole mixer section came alive.
///
/// This block used to be forced to 0 because nobody knew what lived there, which is
/// why the mixer looked broken. Mixer lamp IDs are a DIFFERENT numbering space from
/// deck lamps - never derive one from the other.
public enum MX2MixerLamp {
    public static let first = 61
    public static let count = 13

    /// Lamp for a mixer control, given its BUTTON id.
    public static func forButton(_ buttonID: Int) -> Int? {
        let id = buttonID + 1
        return (first..<(first + count)).contains(id) ? id : nil
    }
}

// MARK: - Renderer

/// Turns `MX2FeedbackState` into the MX2's 105-byte Native LED frame.
///
/// Pure and synchronous: no HID, no timers, no I/O. The caller sends the returned
/// bytes and supplies hardware-only inputs (pad mode, Shift, held pads) via
/// `MX2RenderContext`.
///
/// Behaviour, per deck (physical A ← `deckA`, B ← `deckB`):
/// - PLAY green: lit while playing, dim when loaded, yellow while play-pending.
/// - CUE orange: lit when loaded.
/// - SYNC blue: lit when synced. MASTER blue: lit for the master deck.
/// - KEYLOCK blue: lit when pitch-preserve is on.
/// - SHIFT white: lit while Shift is held; pads drop to a dim preview of the bank.
/// - Pad bank, per `padMode`:
///   - hotcues: `Cues` slots with their palette colours; lit when pressed.
///   - loops: green, lit while the deck's loop is active.
///   - stems: purple (pads 1–4) and cyan (pads 5–8), lit when the deck is loaded.
///   - pattern: orange with the sampler step as a running light.
/// - Under-shell 6 LEDs repeat the deck state colour; the 9 meter LEDs are a VU.
public struct MX2LEDRenderer: Sendable {

    public init() {}

    public func render(state: MX2FeedbackState,
                       context: MX2RenderContext = MX2RenderContext()) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: MX2LEDLayout.byteCount)
        for physicalDeck in 1...2 {
            let deckNumber = context.deckAssignment.deck(for: physicalDeck)
            let deck = state[deck: deckNumber]
            render(deck: deck, physicalDeck: physicalDeck, state: state,
                   context: context, into: &frame)
            renderUndershell(deck: deck, physicalDeck: physicalDeck, into: &frame)
            renderMeter(level: meterLevel(deckNumber: deckNumber, physicalDeck: physicalDeck,
                                          state: state, context: context),
                        physicalDeck: physicalDeck, into: &frame)
        }
        renderMixer(state: state, context: context, into: &frame)
        return frame
    }

    private func renderMixer(state: MX2FeedbackState, context: MX2RenderContext,
                             into frame: inout [UInt8]) {
        // Buttons 60-72 map to lamps 61-73, one-to-one in order:
        //   60/61 FX assign L, 62 channel FX L, 63 headphone L,
        //   64/65 FX assign R, 66 channel FX R, 67 headphone R,
        //   68-71 global FX 1-4, 72 filter.
        // The microphone (button 73) has no lamp in this block; 74 onwards is the
        // under-shell, which is a different thing entirely.
        func lamp(_ buttonID: Int, _ colour: MX2LEDColor, lit: Bool) {
            guard let lampID = MX2MixerLamp.forButton(buttonID),
                  let index = MX2LEDLayout.byteIndex(id: lampID) else { return }
            frame[index] = lit ? colour.byte(lit: true) : colour.byte(lit: false)
        }

        // Headphone Cue: the one mixer lamp with real feedback behind it.
        for physicalDeck in 1...2 {
            let deckNumber = context.deckAssignment.deck(for: physicalDeck)
            let enabled = context.headphoneCue[physicalDeck]
                ?? state.headphoneCue[deckNumber] ?? false
            lamp(physicalDeck == 1 ? 63 : 67, .white, lit: enabled)
        }

        // Everything else sits dim. 0.3.10 exposes no per-control state for these, so
        // nothing may go bright - dim only, which keeps the mixer looking like a lit
        // panel without ever claiming activity that is not happening.
        for buttonID in [60, 61, 62, 64, 65, 66, 68, 69, 70, 71, 72] {
            lamp(buttonID, .blue, lit: false)
        }
    }

    // MARK: Deck controls

    /// How bright an LED should be. `off` emits 0, which is what unused controls need;
    /// the earlier design encoded "unlit colour" and so left dark LEDs glowing dimly.
    private enum Level {
        case off
        case dim
        case lit
    }

    private func render(deck: MX2DeckState, physicalDeck: Int, state: MX2FeedbackState,
                        context: MX2RenderContext, into frame: inout [UInt8]) {
        func set(_ control: MX2Control, _ color: MX2LEDColor) {
            set(control, color, color == .off ? .off : .dim)
        }

        func set(_ control: MX2Control, _ color: MX2LEDColor, _ level: Level) {
            let index = MX2LEDLayout.index(physicalDeck: physicalDeck, control: control)
            guard frame.indices.contains(index) else { return }
            switch level {
            case .off: frame[index] = 0
            case .dim: frame[index] = color.byte(lit: false)
            case .lit: frame[index] = color.byte(lit: true)
            }
        }

        // Indicators with no feedback source show a dim magenta "no signal" tint
        // rather than going black. Two reasons: an unmapped control is then visible at
        // a glance instead of indistinguishable from a working control in its off state,
        // and a totally dark panel reads as "broken" rather than "idle". They are
        // deliberately DIM and deliberately not a colour any real deck state uses.
        for control in [MX2Control.fx1, .fx2, .fx3, .fx4, .favorite, .add,
                        .preview, .view, .flux, .reverse, .turntable, .jog] {
            set(control, .dimUnmapped, .dim)
        }
        set(.shift, .white, context.shiftPressed ? .lit : .off)
        set(.sync, .blue, deck.sync ? .lit : .dim)
        set(.master, .blue, context.masterPhysicalDeck == physicalDeck ? .lit : .dim)
        set(.keylock, .blue, deck.pitchPreserve ? .lit : .dim)
        let previewActive = context.cueActive[physicalDeck] ?? deck.cueActive
        // CUE lamp: bright while the transport CUE is held, dim whenever the deck has
        // something loaded (so the button is findable), dark when empty. The previous
        // version had `deck.loaded ? .dim : .dim` — both arms identical, so the lamp
        // could never brighten and pressing CUE looked like nothing happened.
        set(.cue, .orange, previewActive ? .lit : (deck.loaded ? .dim : .off))

        // Transport: pending wins over playing wins over loaded.
        if deck.playPending || state.playPending {
            set(.play, .yellow, .lit)
        } else if deck.playing {
            set(.play, .green, .lit)
        } else if deck.loaded {
            set(.play, .green, .dim)
        } else {
            set(.play, .off, .off)
        }

        // Pad-bank indicators: the active bank is lit; the others show a dim tint of
        // their own colour so the whole row is visible and you can see which banks
        // exist, without claiming one is active.
        set(.hotcues, .red, context.padMode == .hotcues ? .lit : .dim)
        set(.stems, .purple, context.padMode == .stems ? .lit : .dim)
        set(.pattern, .orange, context.padMode == .pattern ? .lit : .dim)
        set(.loops, .green, context.padMode == .loops ? .lit : .dim)

        let held = context.heldPads[physicalDeck] ?? []
        for (index, control) in MX2Control.pads.enumerated() {
            let (color, level) = padStyle(index: index, deck: deck, state: state,
                                         context: context, held: held.contains(index))
            set(control, color, level)
        }
    }

    private func padStyle(index: Int, deck: MX2DeckState, state: MX2FeedbackState,
                          context: MX2RenderContext, held: Bool) -> (MX2LEDColor, Level) {
        // While Shift is held the pads show their bank colour only faintly, so the
        // shift layer reads as "preview" rather than as active state.
        let preview = context.shiftPressed
        let active: Level = preview ? .dim : .lit

        switch context.padMode {
        case .hotcues:
            let cue = deck.cues[safe: index] ?? MX2Cue()
            guard cue.color != 0 else {
                // Empty slot: dark, unless held, where a dim white confirms the press.
                return held ? (.white, .dim) : (.off, .off)
            }
            let color = MX2LEDColor.cueColor(slot: cue.color, palette: state.palette)
            return (color, cue.pressed || held ? active : .dim)

        case .loops:
            // Feedback knows only whether a loop is active, not which size pad
            // started it. Hardware holds can identify a pad without inventing size.
            return (.green, deck.loop || held ? active : .dim)

        case .stems:
            let color: MX2LEDColor = index < 4 ? .purple : .cyan
            return (color, deck.loaded ? active : .dim)

        case .pattern:
            // `CurrentStep` drives a running light; the rest of the bank sits dim.
            let step = ((deck.samplerStep % MX2Control.pads.count)
                        + MX2Control.pads.count) % MX2Control.pads.count
            return (.orange, !preview && step == index ? .lit : .dim)
        }
    }

    // MARK: Under-shell glow

    private func renderUndershell(deck: MX2DeckState, physicalDeck: Int,
                                  into frame: inout [UInt8]) {
        let base = MX2LEDLayout.undershellBase(physicalDeck)
        // The glow restates deck transport: pending, playing, loaded, or dark. A
        // constant blue was the bug that made both decks look permanently active.
        let color: MX2LEDColor
        let lit: Bool
        if deck.playPending {
            (color, lit) = (.yellow, true)
        } else if deck.playing {
            (color, lit) = (.green, true)
        } else if deck.loaded {
            (color, lit) = (.green, false)
        } else {
            (color, lit) = (.off, false)
        }
        for offset in 0..<MX2LEDLayout.undershellCount {
            guard let index = MX2LEDLayout.byteIndex(id: base + offset) else { continue }
            frame[index] = color.byte(lit: lit)
        }
    }

    // MARK: Meter

    private func meterLevel(deckNumber: Int, physicalDeck: Int,
                            state: MX2FeedbackState,
                            context: MX2RenderContext) -> Double {
        let channel = context.meterChannel[physicalDeck] ?? deckNumber
        guard let level = state.meters[channel], level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }

    private func renderMeter(level: Double, physicalDeck: Int, into frame: inout [UInt8]) {
        let base = MX2LEDLayout.meterBase(physicalDeck)
        let count = MX2LEDLayout.meterCount
        // Square-root scaling so quiet passages still show a couple of segments.
        let litCount = Int((Double(count) * level.squareRoot()).rounded())
        for offset in 0..<count {
            guard let index = MX2LEDLayout.byteIndex(id: base + offset) else { continue }
            guard offset < litCount else {
                frame[index] = MX2LEDColor.off.byte(lit: false)
                continue
            }
            let color: MX2LEDColor
            switch offset {
            case 0..<5: color = .green
            case 5..<7: color = .yellow
            default: color = .red
            }
            frame[index] = color.byte(lit: true)
        }
    }
}
