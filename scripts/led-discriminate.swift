// Discriminate which HID report shape the MX2 actually accepts for LED frames.
//
// The previous probe tried five candidates back to back and reported IOReturn, but
// IOReturn is useless here: IOKit returns success for every combination including the
// wrong ones. The only reliable signal is whether an LED lights. So this sends one
// candidate at a time with a visible pause and a distinct colour, letting the operator
// report which colours appeared.
//
// IOKit convention matters: IOHIDDeviceSetReport takes the report ID as a separate
// argument, so the buffer should usually NOT repeat it. Both shapes "succeed", so this
// has to be settled by eye.
//
// Build: xcrun swiftc -O -o ~/.hermes/cache/scratch/leddisc scripts/led-discriminate.swift
// Run:   ~/.hermes/cache/scratch/leddisc    (stop the bridge first)

import Foundation
import IOKit.hid

let logPath = NSHomeDirectory() + "/.hermes/cache/scratch/leddisc.out"
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

try? FileManager.default.removeItem(atPath: logPath)

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey: 0x17cc,
    kIOHIDProductIDKey: 0x2420,
    kIOHIDPrimaryUsagePageKey: 0xff01,
    kIOHIDPrimaryUsageKey: 0,
] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    logf("cannot open manager"); exit(1)
}
Thread.sleep(forTimeInterval: 0.5)
guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else {
    logf("no MX2 found"); exit(1)
}
guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    logf("cannot open device — is the bridge running?"); exit(1)
}
Thread.sleep(forTimeInterval: 0.3)

// palette codes: red 1, green 7, blue 11, yellow 5, magenta 15
func frame(palette: UInt8) -> [UInt8] {
    var f = [UInt8](repeating: 0, count: 105)
    for i in 0..<8 { f[i] = palette * 4 + 2 }   // LEDs 1-8, bright
    return f
}

struct Candidate {
    let label: String
    let colour: String
    let palette: UInt8
    let reportID: UInt32
    let includeIDInBuffer: Bool
}

let candidates: [Candidate] = [
    .init(label: "A: report 0xF4, buffer WITHOUT id (IOKit convention)",
          colour: "RED", palette: 1, reportID: 0xF4, includeIDInBuffer: false),
    .init(label: "B: report 0xF4, buffer WITH id prefix",
          colour: "GREEN", palette: 7, reportID: 0xF4, includeIDInBuffer: true),
    .init(label: "C: report 0x80, buffer WITHOUT id",
          colour: "BLUE", palette: 11, reportID: 0x80, includeIDInBuffer: false),
    .init(label: "D: report 0x80, buffer WITH id prefix",
          colour: "YELLOW", palette: 5, reportID: 0x80, includeIDInBuffer: true),
]

for (n, c) in candidates.enumerated() {
    var payload = frame(palette: c.palette)
    if c.includeIDInBuffer { payload = [UInt8(c.reportID)] + payload }

    let result = payload.withUnsafeMutableBufferPointer { p -> IOReturn in
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput,
                             CFIndex(c.reportID), p.baseAddress!, p.count)
    }
    logf("[\(n + 1)/4] \(c.label)")
    logf("        colour \(c.colour), len \(payload.count), IOReturn \(result)")
    logf("        -> watch the deck for \(c.colour) on LEDs 1-8")
    Thread.sleep(forTimeInterval: 5.0)
}

logf("\ndone. LEDs 1-8 held their last accepted colour.")
Thread.sleep(forTimeInterval: 120)
