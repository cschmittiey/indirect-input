import Foundation
import BridgeCore

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
    public var jogMode: [Bool] = [false, false]
    public var cueActive: [Bool] = [false, false]
    public var headphoneCue: [Bool] = [false, false]
    // Switch state is keyed by logical deck, so changing deck pairs preserves it.
    public var pitchPreserve: [Int: Bool] = [:]
    public var cueSlip: [Int: Bool] = [:]
    public var samplerMute: [Int: [Int: Bool]] = [:]
    public var onStateChange: (() -> Void)?
    var scratchEnabled = false
    var feedback: [String: [OSCArgument]] = [:]

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

    func handle(_ event: MX2InputEvent) {
        if case let .button(control, pressed) = event {
            switch control {
            case let .shift(side): shift[side.rawValue] = pressed
            case let .bank(side, bank):
                if pressed { banks[side.rawValue] = bank }
            case let .turntable(side):
                if pressed { jogMode[side.rawValue] = false }
            case let .jogMode(side):
                if pressed { jogMode[side.rawValue] = true }
            case let .cue(side):
                cueActive[side.rawValue] = pressed // Syndicate Deck/Cue is Hold.
            case let .keyLock(side):
                if pressed { pitchPreserve[mapping.deck(side), default: false].toggle() }
            case let .flux(side):
                if pressed { cueSlip[mapping.deck(side), default: false].toggle() }
            case let .pad(side, index):
                if pressed, (1...8).contains(index),
                   banks[side.rawValue] == .pattern, shift[side.rawValue] {
                    samplerMute[mapping.deck(side), default: [:]][index, default: false].toggle()
                }
            case let .headphone(side):
                if pressed { headphoneCue[side.rawValue].toggle() }
            default: break
            }
        }
        var messages = route(event)
        if case let .jog(side, delta) = event {
            let index = side.rawValue
            let release = OSCMessage(address: "/Syndicate/Deck/\(mapping.deck(side))/PhaseBend", integer: 0)
            jogReleaseWork[index]?.cancel()
            jogReleaseWork[index] = nil
            if delta == 0 {
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
        for message in messages { onControl?(message) }
        onEvent?(event)
        onStateChange?()
    }

    private func route(_ event: MX2InputEvent) -> [OSCMessage] {
        mapping.route(event, bank: banks, shift: shift, jogMode: jogMode,
                      cueActive: cueActive, headphoneCue: headphoneCue,
                      pitchPreserve: pitchPreserve, cueSlip: cueSlip,
                      samplerMute: samplerMute)
    }

    public func sendRGB(_ image: [UInt8], force: Bool = false) {
        device.sendRGB(image, force: force)
    }
}
