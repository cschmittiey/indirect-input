import Foundation
import MX2Feedback

@MainActor
public final class MX2FeedbackClient {
    public var onStatus: ((String) -> Void)?
    public var onRGB: (([UInt8]) -> Void)?
    public var onResend: (() -> Void)?
    public var onState: ((MX2FeedbackState) -> Void)?
    public var banks: [MX2PadMode] = [.hotcues, .hotcues] {
        didSet { publish() }
    }
    public var shift: [Bool] = [false, false] {
        didSet { publish() }
    }
    public var cueActive: [Bool] = [false, false] {
        didSet { publish() }
    }
    public var headphoneCue: [Bool] = [false, false] {
        didSet { publish() }
    }

    private let receiver = MX2FeedbackReceiver()
    private let renderer = MX2LEDRenderer()
    private var deckOffset = 0

    public init() {
        receiver.onError = { [weak self] text in self?.onStatus?(text) }
        receiver.onResendRequested = { [weak self] in self?.onResend?() }
        receiver.onStateChange = { [weak self] state in
            guard let self else { return }
            self.onState?(state)
            self.render(state)
        }
    }

    public func start() {
        if receiver.start() {
            onStatus?("Listening on 127.0.0.1:9096")
            publish()
        } else {
            onStatus?("Feedback could not bind UDP 9096")
        }
    }

    public func configure(firstDeck: Int) {
        deckOffset = firstDeck - 1
        publish()
    }

    public func receivePacket(_ data: Data) -> MX2FeedbackState.ApplyResult {
        let result = receiver.ingest(data)
        if result == .ignored {
            onStatus?("Feedback packet did not change recognized state")
        }
        return result
    }

    private func publish() {
        render(receiver.state)
    }

    private func render(_ state: MX2FeedbackState) {
        // The hardware has two independently selected banks. Render each deck with
        // its own context instead of applying the left deck's mode to both.
        var combined = [UInt8](repeating: 0, count: MX2LEDLayout.byteCount)
        for physical in 1...2 {
            let index = physical - 1
            let mode = banks[index]
            let context = MX2RenderContext(
                deckAssignment: MX2DeckAssignment(deckA: deckOffset + 1, deckB: deckOffset + 2),
                padMode: mode,
                shiftPressed: shift[index],
                cueActive: [physical: cueActive[index]],
                headphoneCue: [physical: headphoneCue[index]]
            )
            let frame = renderer.render(state: state, context: context)
            let deckBase = physical == 1 ? 0 : 40
            for offset in 0..<30 { combined[deckBase + offset] = frame[deckBase + offset] }
            let underBase = physical == 1 ? 80 : 86
            for offset in 0..<6 { combined[underBase + offset] = frame[underBase + offset] }
            let meterBase = physical == 1 ? 87 : 96
            for offset in 0..<9 { combined[meterBase + offset] = frame[meterBase + offset] }
            for id in [physical == 1 ? 62 : 66, physical == 1 ? 64 : 68] {
                if let byte = MX2LEDLayout.byteIndex(id: id) { combined[byte] = frame[byte] }
            }
        }
        onRGB?(combined)
    }
}
