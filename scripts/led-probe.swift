// LED mapping probe for the Traktor MX2.
//
// Lights a contiguous range of LED IDs, each with a DISTINCT colour, so the owner can
// read the mapping off the hardware in one look instead of trying 105 IDs one by one.
// Tell them which colour sits under CUE, PLAY, etc, and you have the real table.
//
// Build: xcrun swiftc -O -o ~/.hermes/cache/scratch/ledprobe scripts/led-probe.swift
// Run:   ~/.hermes/cache/scratch/ledprobe <firstID> <lastID>
//        Stop the bridge first; it holds the device exclusively.

import Foundation
import IOKit.hid

let vendorID = 0x17cc
let productID = 0x2420

// Palette codes from MX2LEDColor: wire byte = palette * 4 + 2 (bright).
let colours: [(name: String, palette: UInt8)] = [
    ("red", 1), ("orange", 3), ("yellow", 5), ("green", 7),
    ("cyan", 9), ("blue", 11), ("purple", 14), ("magenta", 15),
]

let args = CommandLine.arguments
let first = args.count > 1 ? Int(args[1]) ?? 20 : 20
let last = args.count > 2 ? Int(args[2]) ?? 31 : 31

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let criteria: [String: Any] = [
    kIOHIDVendorIDKey: vendorID,
    kIOHIDProductIDKey: productID,
    kIOHIDPrimaryUsagePageKey: 0xff01,
    kIOHIDPrimaryUsageKey: 0,
]
IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("could not open MX2 HID manager")
    exit(1)
}
Thread.sleep(forTimeInterval: 0.4)

guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first,
      IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("could not open MX2 device — is the bridge still running?")
    exit(1)
}

var frame = [UInt8](repeating: 0, count: 105)
print("Lighting LED IDs \(first)...\(last). Each ID gets its own colour:")
for id in first...last {
    let colour = colours[(id - first) % colours.count]
    if (1...105).contains(id) {
        frame[id - 1] = colour.palette * 4 + 2   // bright
    }
    print(String(format: "  LED ID %3d -> %@", id, colour.name))
}

let report = [UInt8(0x80)] + frame
let result = report.withUnsafeBufferPointer {
    IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x80, $0.baseAddress!, $0.count)
}
print(result == kIOReturnSuccess ? "sent (IOReturnSuccess)" : "send failed: \(result)")

// Hold the frame so it can be inspected, then restore a dark frame on exit.
print("\nlook at the deck now. Ctrl-C when done.")
Thread.sleep(forTimeInterval: 90)

for i in 0..<105 { frame[i] = 0 }
let clear = [UInt8(0x80)] + frame
_ = clear.withUnsafeBufferPointer {
    IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x80, $0.baseAddress!, $0.count)
}
