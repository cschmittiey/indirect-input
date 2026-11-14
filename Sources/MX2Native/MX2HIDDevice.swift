import Foundation
import IOKit.hid

@MainActor
final class MX2HIDDevice {
    var onEvent: ((MX2InputEvent) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onRGB: (([UInt8], IOReturn) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var decoder = MX2Decoder()
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var bufferSize = 0
    private var started = false
    private var lastImage: [UInt8]?
    private var lastSend = Date.distantPast

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
        guard image.count == 105, let device else { return }
        let now = Date()
        guard force || image != lastImage || now.timeIntervalSince(lastSend) > 1 else { return }
        let report = [UInt8(0x80)] + image
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x80,
                                 $0.baseAddress!, $0.count)
        }
        if result == kIOReturnSuccess {
            lastImage = image
            lastSend = now
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
