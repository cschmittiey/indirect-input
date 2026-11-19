import Foundation
import IndirectInputCore

@MainActor
public final class MX2NativeController {
    public var onEvent: ((MX2InputEvent) -> Void)?
    public var onStatus: ((String, Bool) -> Void)?
    public var onRGB: (([UInt8], IOReturn) -> Void)?
    public var onControl: ((OSCMessage) -> Void)?
    public var onRawReport: (([UInt8]) -> Void)?

    let device = MX2HIDDevice()
    public var mapping = MX2Mapping()
    public var banks: [MX2PadBank] = [.hotcues, .hotcues]
    public var shift: [Bool] = [false, false]
    public private(set) var jogTouch: [Bool] = [false, false]
    // Absolute normalized seek estimate, independent for each logical deck.
    // The caller can seed it from Progress feedback (OSC §14.10). Without that
    // feedback it starts at zero; it cannot infer the host's playback position.
    public var jogPosition: [Int: Double] = [:]
    // Mapping sensitivity, not an OSC unit: 960 ticks/revolution, 1% track/turn.
    // Accumulating full signed deltas makes faster spins seek proportionally more.
    private let jogTicksPerTrack: Double = 96_000
    // Toggle state lives in TWO different key spaces, and mixing them is a real bug:
    //   - cueActive / headphoneCue / pitchPreserve / cueSlip / fxEnabled / samplerMute
    //     are keyed by LOGICAL DECK (1-4), so switching the deck pair preserves them.
    //   - banks / shift are keyed by PHYSICAL SIDE (0-1), because a bank
    //     selector physically belongs to the left or right deck.
    // headphoneCue used to be a [Bool] indexed by side, which meant switching to pair
    // 3/4 left CH3 inverted relative to the button while CH1/CH2 kept stale values.
    public var cueActive: [Int: Bool] = [:]
    public var headphoneCue: [Int: Bool] = [:]
    // Switch state is keyed by logical deck, so changing deck pairs preserves it.
    public var pitchPreserve: [Int: Bool] = [:]
    public var cueSlip: [Int: Bool] = [:]
    public var fxEnabled: [Int: Bool] = [:]
    public var samplerMute: [Int: [Int: Bool]] = [:]
    // Header browser mode is global, shared by both VIEW buttons and all pairs.
    public private(set) var browserMode: Int = 0
    public var onStateChange: (() -> Void)?

    private var heldCueDeck: [MX2Side: Int] = [:]
    private var jogReleaseWork: [DispatchWorkItem?] = [nil, nil]
    private var jogReleases: [OSCMessage?] = [nil, nil]
    private var buttonReleases: [MX2Control: [OSCMessage]] = [:]

    public init() {
        device.onEvent = { [weak self] in self?.handle($0) }
        device.onStatus = { [weak self] text, connected in self?.onStatus?(text, connected) }
        device.onRGB = { [weak self] image, status in self?.onRGB?(image, status) }
        device.onRawReport = { [weak self] report in self?.onRawReport?(report) }
    }

    public func start() { device.start() }

    /// Seed the seek origin from playback progress, so grabbing the platter moves the
    /// track relative to where it actually is rather than relative to the start.
    /// Called whenever Syndicate reports `Deck/{n}/Progress`. Non-finite or
    /// out-of-range values are clamped rather than trusted.
    ///
    /// Ignored while a platter driving that deck is touched: Progress lags the seeks
    /// we are sending, so accepting it mid-gesture would yank the platter back.
    public func seedJogPosition(deck: Int, progress: Double) {
        guard (1...4).contains(deck), !isTouched(deck: deck) else { return }
        jogPosition[deck] = MX2Mapping.clampedJogPosition(progress)
    }

    private func isTouched(deck: Int) -> Bool {
        [MX2Side.left, .right].contains { jogTouch[$0.rawValue] && mapping.deck($0) == deck }
    }

    func handle(_ event: MX2InputEvent) {
        if case let .button(control, pressed) = event {
            switch control {
            case let .shift(side): shift[side.rawValue] = pressed
            case let .jogTouch(side): jogTouch[side.rawValue] = pressed
            case let .bank(side, bank):
                if pressed { banks[side.rawValue] = bank }
            case let .cue(side):
                // Mirror the press-time OSC release target in the local lamp state.
                if pressed {
                    let deck = mapping.deck(side)
                    heldCueDeck[side] = deck
                    cueActive[deck] = true
                } else if let deck = heldCueDeck.removeValue(forKey: side) {
                    cueActive[deck] = false
                }
            case let .keyLock(side):
                if pressed { pitchPreserve[mapping.deck(side), default: false].toggle() }
            case let .flux(side):
                if pressed { cueSlip[mapping.deck(side), default: false].toggle() }
            case let .pad(side, index):
                if pressed, (1...8).contains(index),
                   banks[side.rawValue] == .pattern, shift[side.rawValue] {
                    samplerMute[mapping.deck(side), default: [:]][index, default: false].toggle()
                }
            case let .channelFX(side):
                if pressed { fxEnabled[mapping.deck(side), default: false].toggle() }
            case .view:
                if pressed { browserMode = (browserMode + 1) % 3 }
            case let .headphone(side):
                if pressed { headphoneCue[mapping.deck(side), default: false].toggle() }
            default: break
            }
        }
        if case let .jog(side, delta) = event,
           jogTouch[side.rawValue], !shift[side.rawValue], delta != 0 {
            let deck = mapping.deck(side)
            // Decoder already unwraps the 960-tick platter counter. Do not wrap
            // the track position: hitting an end clamps and reversal moves away.
            //
            // The starting point is the deck's CURRENT playback progress, not zero.
            // Without the seed, the first touched turn jumps toward the start of the
            // track, which feels like a bug and is one. `seedJogPosition` is refreshed
            // from Syndicate's Progress feedback whenever that arrives.
            let position = MX2Mapping.clampedJogPosition(jogPosition[deck, default: 0])
            jogPosition[deck] = MX2Mapping.clampedJogPosition(position + Double(delta) / jogTicksPerTrack)
        }
        var messages = route(event)
        if case let .jog(side, delta) = event {
            let index = side.rawValue
            let release = OSCMessage(address: "/Syndicate/Deck/\(mapping.deck(side))/PhaseBend", integer: 0)
            jogReleaseWork[index]?.cancel()
            jogReleaseWork[index] = nil
            if jogTouch[index] || shift[index] {
                if let previous = jogReleases[index] { messages.insert(previous, at: 0) }
                jogReleases[index] = nil
            } else if delta == 0 {
                messages = [jogReleases[index] ?? release]
                jogReleases[index] = nil
            } else {
                if let previous = jogReleases[index], previous.address != release.address {
                    // A reassignment must not strand a bend on the previous deck.
                    messages.insert(previous, at: 0)
                }
                jogReleases[index] = release
                let work = DispatchWorkItem { [weak self] in
                    self?.jogReleases[index] = nil
                    self?.jogReleaseWork[index] = nil
                    self?.onControl?(release)
                }
                jogReleaseWork[index] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
        }
        if case let .button(control, pressed) = event {
            if pressed {
                // Preserve the press's bank, modifier and logical deck until release.
                // Save empty releases too: a trigger must not release a later bank's hold.
                buttonReleases[control] = route(.button(control, pressed: false))
            } else if let release = buttonReleases.removeValue(forKey: control) {
                messages = release
            }
        }
        if case let .button(control, pressed: true) = event {
            switch control {
            case let .jogTouch(side), let .shift(side):
                // A mode transition ends the physical side's held bend immediately,
                // even if the logical deck has since changed and no jog event follows.
                let index = side.rawValue
                jogReleaseWork[index]?.cancel()
                jogReleaseWork[index] = nil
                if let previous = jogReleases[index] { messages.insert(previous, at: 0) }
                jogReleases[index] = nil
            default: break
            }
        }
        for message in messages { onControl?(message) }
        onEvent?(event)
        onStateChange?()
    }

    private func route(_ event: MX2InputEvent) -> [OSCMessage] {
        var state = MX2ControllerState()
        state.banks = banks
        state.shift = shift
        state.jogTouch = jogTouch
        state.cueActive = cueActive
        state.headphoneCue = headphoneCue
        state.pitchPreserve = pitchPreserve
        state.cueSlip = cueSlip
        state.fxEnabled = fxEnabled
        state.samplerMute = samplerMute
        state.jogPosition = jogPosition
        state.browserMode = browserMode
        return mapping.route(event, state: state)
    }

    public func sendRGB(_ image: [UInt8], force: Bool = false) {
        device.sendRGB(image, force: force)
    }
}
