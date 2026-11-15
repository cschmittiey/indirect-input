// Find which report ID / type the MX2 accepts an LED frame on.
//
// The descriptor advertises an OUTPUT report 0xF4 (244) of 33 bytes (usage 244 size 8
// + usage 245 size 248) and MaxFeatureReportSize 33. The app has been sending 0x80,
// which is the INPUT LED report ID — the likely reason nothing lights.
//
// This tries each candidate and reports the IOReturn, then lights one LED so the
// result can be confirmed with eyes.
//
// Build: xcrun swiftc -O -o ~/.hermes/cache/scratch/ledreport scripts/led-report-probe.swift
// Run:   ~/.hermes/cache/scratch/ledreport      (stop the bridge first)

import Foundation
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let criteria: [String: Any] = [
    kIOHIDVendorIDKey: 0x17cc,
    kIOHIDProductIDKey: 0x2420,
    kIOHIDPrimaryUsagePageKey: 0xff01,
    kIOHIDPrimaryUsageKey: 0,
]
IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("cannot open manager"); exit(1)
}
Thread.sleep(forTimeInterval: 0.4)
guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else {
    print("no MX2 found"); exit(1)
}
guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("cannot open device — is the bridge running?"); exit(1)
}

let logPath = NSHomeDirectory() + "/.hermes/cache/scratch/ledreport.out"
func logf(_ s: String) {
    print(s)
    let line = s + "\n"
    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line.data(using: .utf8)!)
    } else {
        try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: logPath))
    }
}

func num(_ device: IOHIDDevice, _ key: String) -> Int? {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
}
logf("MaxInputReportSize  = \(num(device, kIOHIDMaxInputReportSizeKey) ?? -1)")
logf("MaxOutputReportSize = \(num(device, kIOHIDMaxOutputReportSizeKey) ?? -1)")
logf("MaxFeatureReportSize= \(num(device, kIOHIDMaxFeatureReportSizeKey) ?? -1)")
print("")

// A frame that lights the FIRST eight LEDs red so success is obvious.
var image = [UInt8](repeating: 0, count: 105)
for i in 0..<8 { image[i] = 1 * 4 + 2 }   // red, bright

func trySend(reportID: UInt32, type: IOHIDReportType, label: String,
             payload: [UInt8]) -> IOReturn {
    var buffer = payload
    let result = buffer.withUnsafeMutableBufferPointer { p -> IOReturn in
        IOHIDDeviceSetReport(device, type, CFIndex(reportID), p.baseAddress!, p.count)
    }
    logf(String(format: "%-38s id=0x%02X len=%3d -> %@",
                 (label as NSString).utf8String!, reportID, payload.count,
                 result == kIOReturnSuccess ? "SUCCESS" : "fail \(result)"))
    return result
}

logf("candidates:")
_ = trySend(reportID: 0xF4, type: kIOHIDReportTypeOutput,  label: "output 0xF4, [id]+105", payload: [UInt8(0xF4)] + image)
_ = trySend(reportID: 0xF4, type: kIOHIDReportTypeOutput,  label: "output 0xF4, 105 only", payload: image)
_ = trySend(reportID: 0xF4, type: kIOHIDReportTypeFeature, label: "feature 0xF4, [id]+105", payload: [UInt8(0xF4)] + image)
_ = trySend(reportID: 0x80, type: kIOHIDReportTypeOutput,  label: "output 0x80, [id]+105", payload: [UInt8(0x80)] + image)
_ = trySend(reportID: 0x80, type: kIOHIDReportTypeFeature, label: "feature 0x80, [id]+105", payload: [UInt8(0x80)] + image)

logf("\nthe first eight LEDs should be red if any candidate worked. holding 60s.")
Thread.sleep(forTimeInterval: 60)
