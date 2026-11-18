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
    /// Cue state keyed by LOGICAL DECK (1-4), because the mixer routes by deck number.
    /// Keying these by physical side instead made the lamp follow the wrong deck after
    /// a deck-pair change. The renderer looks them up by Syndicate deck number too.
    public var cueActive: [Int: Bool] = [:] {
        didSet { publish() }
    }
    public var headphoneCue: [Int: Bool] = [:] {
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

    func renderForTesting() -> [UInt8] {
        var image: [UInt8] = []
        let old = onRGB
        onRGB = { image = $0 }
        publish()
        onRGB = old
        return image
    }

    private func publish() {
        render(receiver.state)
    }

    private func render(_ state: MX2FeedbackState) {
        // The hardware has two independently selected banks, so each physical deck needs
        // its own pad mode. Compose the frame from exactly THREE renders - deck A, deck B
        // and one global pass for the mixer band - and merge them by ID band rather than
        // by hand-maintained byte ranges.
        //
        // Why this shape: the previous version copied slices (0-29, 30-59, 73-78,
        // 79-84, 86-94) and every byte outside those ranges was silently dropped. That
        // is what hid the mixer lamps for hours, and it would hide any future band just
        // the same. The bands now come from one declarative table, so adding a lamp
        // region means editing the table, not hunting for a copy loop.
        var combined = [UInt8](repeating: 0, count: MX2LEDLayout.byteCount)

        for physical in 1...2 {
            let index = physical - 1
            let context = MX2RenderContext(
                deckAssignment: MX2DeckAssignment(deckA: deckOffset + 1, deckB: deckOffset + 2),
                padMode: banks[index],
                shiftPressed: shift[index],
                cueActive: [physical: cueActive[deckOffset + index + 1, default: false]],
                headphoneCue: [physical: headphoneCue[deckOffset + index + 1, default: false]]
            )
            merge(renderer.render(state: state, context: context),
                  bands: MX2LEDLayout.deckBands(forPhysicalDeck: physical),
                  into: &combined)
        }

        // Mixer lamps are one global band, addressed by physical channel while
        // headphoneCue is keyed by logical deck, so map through the active pair.
        let mixerContext = MX2RenderContext(
            headphoneCue: [1: headphoneCue[deckOffset + 1, default: false],
                           2: headphoneCue[deckOffset + 2, default: false]]
        )
        merge(renderer.render(state: state, context: mixerContext),
              bands: [MX2LEDLayout.mixerLampRange], into: &combined)

        onRGB?(combined)
    }

    /// Copy the given ID ranges from `frame` into `combined`. Ranges are 1-based
    /// firmware LED IDs, matching every other table in the renderer.
    private func merge(_ frame: [UInt8], bands: [ClosedRange<Int>],
                       into combined: inout [UInt8]) {
        for band in bands {
            for id in band {
                guard let index = MX2LEDLayout.byteIndex(id: id),
                      frame.indices.contains(index),
                      combined.indices.contains(index) else { continue }
                combined[index] = frame[index]
            }
        }
    }
}
