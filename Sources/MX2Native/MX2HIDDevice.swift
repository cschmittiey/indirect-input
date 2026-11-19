import Foundation
import IOKit.hid

@MainActor
final class MX2HIDDevice {
    var onEvent: ((MX2InputEvent) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onRGB: (([UInt8], IOReturn) -> Void)?
    var onRawReport: (([UInt8]) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var decoder = MX2Decoder()
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var bufferSize = 0
    private var started = false
    private var lastImage: [UInt8]?
    private var lastSend = Date.distantPast

    /// The 105-byte LED frame goes out as OUTPUT report 0x80, with the report ID
    /// repeated as the first byte of the buffer. Do not "tidy" this to IOKit's usual
    /// separate-ID convention: the device rejects the 105-byte form and accepts the
    /// 106-byte one, and IOKit returns kIOReturnSuccess for BOTH, so the only way to
    /// tell them apart is watching an LED. Verified by sending four candidates with a
    /// distinct colour each — only 0x80-with-prefix lit anything.
    ///
    /// Descriptor evidence: ReportID=128, Type=Output, Usage 131 (696 bits) +
    /// Usage 129 (144 bits) = 840 bits = 105 bytes; MaxOutputReportSize=106.
    /// Report 0xF4 is an unrelated 32-byte output and will silently do nothing.
    static let ledReportID: UInt32 = 0x80

    func start() {
        guard !started else { return }
        started = true
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let criteria: [String: Any] = [
            kIOHIDVendorIDKey: 0x17cc,
            kIOHIDProductIDKey: 0x2420,
            kIOHIDPrimaryUsagePageKey: 0xff01,
            kIOHIDPrimaryUsageKey: 0
        ]
        IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let owner = Unmanaged<MX2HIDDevice>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in owner.attach(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let owner = Unmanaged<MX2HIDDevice>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in owner.detach(device) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            onStatus?("Could not open MX2 HID manager: \(result)", false)
            return
        }
        for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
            attach(device)
        }
    }

    func sendRGB(_ image: [UInt8], force: Bool = false) {
        guard image.count == 105 else {
            onStatus?("RGB frame rejected: \(image.count) bytes, expected 105", false)
            return
        }
        guard let device else {
            onStatus?("RGB frame dropped: no MX2 HID device attached", false)
            return
        }
        let now = Date()
        guard force || image != lastImage || now.timeIntervalSince(lastSend) > 1 else { return }
        // Report 0x80 with the ID prefixed into the buffer — see ledReportID above for
        // why this shape and not IOKit's usual separate-ID form.
        let report = [UInt8(MX2HIDDevice.ledReportID)] + image
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput,
                                 CFIndex(MX2HIDDevice.ledReportID),
                                 $0.baseAddress!, $0.count)
        }
        if result == kIOReturnSuccess {
            lastImage = image
            lastSend = now
        }
        // Always surface the transport result through `onRGB`. A silent success here is
        // what hid the wrong-report-ID bug for hours, so never swallow it. Failures also
        // go through `onStatus`; a success status per frame would flood the log at
        // meter rate, and `onRGB` already carries it.
        if result != kIOReturnSuccess {
            onStatus?("RGB SetReport failed: \(result)", false)
        }
        onRGB?(image, result)
    }

    private func attach(_ device: IOHIDDevice) {
        guard self.device == nil, isMX2(device) else { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            onStatus?("Could not open MX2 HID: \(result)", false)
            return
        }
        self.device = device
        bufferSize = max(64, numeric(device, kIOHIDMaxInputReportSizeKey) ?? 64)
        guard bufferSize <= 4096 else {
            detach(device)
            return
        }
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer!, bufferSize, { context, _, _, _, _, bytes, count in
            guard let context else { return }
            let owner = Unmanaged<MX2HIDDevice>.fromOpaque(context).takeUnretainedValue()
            let report = Array(UnsafeBufferPointer(start: bytes, count: count))
            Task { @MainActor in owner.receive(report) }
        }, Unmanaged.passUnretained(self).toOpaque())
        decoder = MX2Decoder()
        onStatus?("Traktor MX2 · Native connected", true)
        seed()
    }

    private func detach(_ device: IOHIDDevice) {
        guard let current = self.device, CFEqual(current, device) else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.device = nil
        buffer?.deallocate()
        buffer = nil
        lastImage = nil
        onStatus?("Traktor MX2 disconnected · waiting", false)
    }

    private func receive(_ report: [UInt8]) {
        onRawReport?(report)
        for event in decoder.decode(report) { onEvent?(event) }
    }

    private func seed() {
        guard let device else { return }
        for id in [1, 2] {
            var data = [UInt8](repeating: 0, count: id == 1 ? 15 : 53)
            data[0] = UInt8(id)
            var count = data.count
            _ = data.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, id,
                                     $0.baseAddress!, &count)
            }
        }
    }

    private func numeric(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private func isMX2(_ device: IOHIDDevice) -> Bool {
        numeric(device, kIOHIDVendorIDKey) == 0x17cc
            && numeric(device, kIOHIDProductIDKey) == 0x2420
            && numeric(device, kIOHIDPrimaryUsagePageKey) == 0xff01
            && numeric(device, kIOHIDPrimaryUsageKey) == 0
    }
}
