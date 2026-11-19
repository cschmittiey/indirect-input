import Combine
import XCTest
import IndirectInputCore
import MX2Feedback
import MX2Native
@testable import IndirectInputApp

/// Behavior of the signal-path indicators. These strings are the view's contract,
/// so they are asserted literally rather than by enum case.
@MainActor
final class BridgeIndicatorTests: XCTestCase {

    private func makeModel() -> BridgeModel {
        // No HID manager, no feedback socket, no OSC socket: the handlers are
        // driven directly so the tests need neither hardware nor a free port.
        BridgeModel(startServices: false)
    }

    func testIndicatorsStartIdle() {
        let model = makeModel()
        XCTAssertEqual(model.hidIndicator, "Idle")
        XCTAssertEqual(model.feedbackIndicator, "Idle")
        XCTAssertEqual(model.rgbIndicator, "Idle")
    }

    // MARK: - HID

    func testHIDConnectAndDisconnect() {
        let model = makeModel()
        model.handleNativeStatus("Traktor MX2 · Native connected", connected: true)
        XCTAssertEqual(model.hidIndicator, "Connected")

        model.handleNativeStatus("Traktor MX2 disconnected · waiting", connected: false)
        XCTAssertEqual(model.hidIndicator, "Waiting")
    }

    func testHIDOpenFailureIsError() {
        let model = makeModel()
        model.handleNativeStatus("Could not open MX2 HID: \(kIOReturnExclusiveAccess)", connected: false)
        XCTAssertEqual(model.hidIndicator, "Error")
    }

    /// The HID lamp must never be driven by an LED transport message. A working
    /// controller with a broken RGB path has to stay "Connected" with RGB at Error.
    func testRGBStatusDoesNotMoveHIDIndicator() {
        let model = makeModel()
        model.handleNativeStatus("Traktor MX2 · Native connected", connected: true)
        XCTAssertEqual(model.hidIndicator, "Connected")

        model.handleNativeStatus("RGB SetReport failed: \(kIOReturnError)", connected: false)
        XCTAssertEqual(model.hidIndicator, "Connected", "RGB failure must not mark HID down")
        XCTAssertEqual(model.rgbIndicator, "Error")

        model.handleNativeStatus("RGB sent 12 lit on report 0x80", connected: true)
        XCTAssertEqual(model.hidIndicator, "Connected")
        XCTAssertEqual(model.rgbIndicator, "Accepted")
    }

    func testRGBFrameAcknowledgementIsSeparateFromHID() {
        let model = makeModel()
        model.handleNativeStatus("Traktor MX2 · Native connected", connected: true)
        model.handleRGBStatus([UInt8](repeating: 0, count: 105), status: kIOReturnSuccess)
        XCTAssertEqual(model.rgbIndicator, "Accepted")
        XCTAssertEqual(model.hidIndicator, "Connected")

        model.handleRGBStatus([UInt8](repeating: 0, count: 105), status: kIOReturnError)
        XCTAssertEqual(model.rgbIndicator, "Error")
        XCTAssertEqual(model.hidIndicator, "Connected")
    }

    // MARK: - Feedback

    func testFeedbackListeningThenReceived() {
        let model = makeModel()
        model.handleFeedbackStatus("Listening on 127.0.0.1:9096")
        XCTAssertEqual(model.feedbackIndicator, "Listening")

        model.handleFeedbackState(MX2FeedbackState())
        XCTAssertEqual(model.feedbackIndicator, "Received")
    }

    func testOnlyProgressChangesReseedTheJogOrigin() {
        let model = makeModel()
        var state = MX2FeedbackState()
        state[deck: 1].progress = 0.4
        model.handleFeedbackState(state)
        XCTAssertEqual(model.native.jogPosition[1], 0.4)

        // The controller moved the origin (a seek); a meter-only frame must keep it.
        model.native.jogPosition[1] = 0.7
        state.meters[1] = 0.9
        model.handleFeedbackState(state)
        XCTAssertEqual(model.native.jogPosition[1], 0.7)

        state[deck: 1].progress = 0.71
        model.handleFeedbackState(state)
        XCTAssertEqual(model.native.jogPosition[1], 0.71)
    }

    func testFeedbackBindFailureIsError() {
        let model = makeModel()
        model.handleFeedbackStatus("Feedback could not bind UDP 9096")
        XCTAssertEqual(model.feedbackIndicator, "Error")
    }

    func testPortUnavailableIsError() {
        let model = makeModel()
        model.handleFeedbackStatus("Port 9096 unavailable: Address already in use")
        XCTAssertEqual(model.feedbackIndicator, "Error")
    }

    /// Ordinary traffic notices must not flip a listening receiver to Error.
    func testNonFailureFeedbackNoticesLeaveIndicatorAlone() {
        let model = makeModel()
        model.handleFeedbackStatus("Listening on 127.0.0.1:9096")
        model.handleFeedbackStatus("Feedback packet did not change recognized state")
        XCTAssertEqual(model.feedbackIndicator, "Listening")
        model.handleFeedbackStatus("Ignored malformed OSC packet (7 bytes)")
        XCTAssertEqual(model.feedbackIndicator, "Listening")
    }

    // MARK: - Transitions only

    /// `@Published` fires on every assignment, so the indicator must only be
    /// written when the value actually changes. A stream of identical statuses is
    /// exactly what the feedback log rate limiter produces.
    func testIndicatorsOnlyPublishOnTransition() {
        let model = makeModel()
        var hidUpdates = 0
        var feedbackUpdates = 0
        var rgbUpdates = 0
        let hid = model.$hidIndicator.dropFirst().sink { _ in hidUpdates += 1 }
        let fb = model.$feedbackIndicator.dropFirst().sink { _ in feedbackUpdates += 1 }
        let rgb = model.$rgbIndicator.dropFirst().sink { _ in rgbUpdates += 1 }
        defer { hid.cancel(); fb.cancel(); rgb.cancel() }

        for _ in 0..<20 {
            model.handleNativeStatus("Traktor MX2 · Native connected", connected: true)
            model.handleFeedbackStatus("Listening on 127.0.0.1:9096")
            model.handleRGBStatus([UInt8](repeating: 0, count: 105), status: kIOReturnSuccess)
        }
        XCTAssertEqual(hidUpdates, 1)
        XCTAssertEqual(feedbackUpdates, 1)
        XCTAssertEqual(rgbUpdates, 1)

        model.handleNativeStatus("Traktor MX2 disconnected · waiting", connected: false)
        XCTAssertEqual(hidUpdates, 2)
    }

    // MARK: - Classification helpers

    func testRGBStatusClassificationCoversSendFailures() {
        XCTAssertTrue(BridgeModel.isRGBStatus("RGB sent 12 lit on report 0x80"))
        XCTAssertTrue(BridgeModel.isRGBStatus("RGB frame rejected: 104 bytes, expected 105"))
        XCTAssertTrue(BridgeModel.isRGBStatus("RGB frame dropped: no MX2 HID device attached"))
        XCTAssertFalse(BridgeModel.isRGBStatus("Traktor MX2 · Native connected"))
        XCTAssertFalse(BridgeModel.isRGBStatus("Could not open MX2 HID: -536870203"))
    }

    func testFeedbackIndicatorIgnoresStatusesItDoesNotClassify() {
        XCTAssertNil(BridgeModel.feedbackIndicatorValue(for: "Feedback not started"))
        XCTAssertEqual(BridgeModel.feedbackIndicatorValue(for: "Listening on 127.0.0.1:9096"), .listening)
        XCTAssertEqual(BridgeModel.feedbackIndicatorValue(for: "Feedback could not bind UDP 9096"), .error)
    }
}
