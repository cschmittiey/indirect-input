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
    public var onStateChange: (() -> Void)?
    var scratchEnabled = false
    var feedback: [String: [OSCArgument]] = [:]

    private var jogReleaseWork: [DispatchWorkItem?] = [nil, nil]

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
            case let .headphone(side):
                if pressed { headphoneCue[side.rawValue].toggle() }
            default: break
            }
        }
        if case let .jog(side, delta) = event {
            if delta == 0 {
                onControl?(OSCMessage(address: "/Syndicate/Deck/\(mapping.deck(side))/PhaseBend", integer: 0))
            } else {
                jogReleaseWork[side.rawValue]?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.onControl?(OSCMessage(
                        address: "/Syndicate/Deck/\(self?.mapping.deck(side) ?? 1)/PhaseBend",
                        integer: 0))
                }
                jogReleaseWork[side.rawValue] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
        }
        for message in mapping.route(event, bank: banks, shift: shift, jogMode: jogMode,
                                     cueActive: cueActive, headphoneCue: headphoneCue) {
            onControl?(message)
        }
        onEvent?(event)
        onStateChange?()
    }

    public func sendRGB(_ image: [UInt8], force: Bool = false) {
        device.sendRGB(image, force: force)
    }
}
