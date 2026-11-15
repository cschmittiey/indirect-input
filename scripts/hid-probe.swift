// Standalone HID probe for the Traktor MX2.
//
// Purpose: settle control-ID questions against real hardware instead of trusting
// either docs/mx2-native-protocol.md (which contradicts itself on the 66-79 block) or
// the decoder's table (which was written by hand). Press one control at a time and read
// the bit index that changed.
//
// Build:  xcrun swiftc -O -o ~/.hermes/cache/scratch/hidprobe scripts/hid-probe.swift
// Run:    ~/.hermes/cache/scratch/hidprobe
// Stop the bridge first, or it holds the device open exclusively.

import Foundation
import IOKit.hid

let vendorID = 0x17cc
let productID = 0x2420

// The decoder's current hand-written table, so the probe can show what each bit
// *claims* to be alongside the raw index that actually moved.
let claimed: [Int: String] = [
    0: "fxButton(L,1)", 1: "fxButton(L,2)", 2: "fxButton(L,3)", 3: "fxButton(L,4)",
    4: "favorite(L)", 5: "addToList(L)", 6: "preview(L)", 7: "view(L)",
    8: "flux(L)", 9: "reverse(L)", 10: "turntable(L)", 11: "jogMode(L)", 12: "shift(L)",
    13: "sync(L)", 14: "master(L)", 15: "keyLock(L)",
    16: "bank(L,hotcues)", 17: "bank(L,stems)", 18: "bank(L,pattern)", 19: "bank(L,loops)",
    20: "pad(L,1)", 21: "pad(L,2)", 22: "pad(L,3)", 23: "pad(L,4)",
    24: "pad(L,5)", 25: "pad(L,6)", 26: "pad(L,7)", 27: "pad(L,8)",
    28: "cue(L)", 29: "play(L)",
    30: "fxButton(R,1)", 31: "fxButton(R,2)", 32: "fxButton(R,3)", 33: "fxButton(R,4)",
    34: "favorite(R)", 35: "addToList(R)", 36: "preview(R)", 37: "view(R)",
    38: "flux(R)", 39: "reverse(R)", 40: "turntable(R)", 41: "jogMode(R)", 42: "shift(R)",
    43: "sync(R)", 44: "master(R)", 45: "keyLock(R)",
    46: "bank(R,hotcues)", 47: "bank(R,stems)", 48: "bank(R,pattern)", 49: "bank(R,loops)",
    50: "pad(R,1)", 51: "pad(R,2)", 52: "pad(R,3)", 53: "pad(R,4)",
    54: "pad(R,5)", 55: "pad(R,6)", 56: "pad(R,7)", 57: "pad(R,8)",
    58: "cue(R)", 59: "play(R)",
    60: "fxAssign(L,1)", 61: "fxAssign(L,2)", 62: "channelFX(L)", 63: "headphone(L)",
    64: "fxAssign(R,1)", 65: "fxAssign(R,2)", 66: "channelFX(R)", 67: "headphone(R)",
    68: "globalFX(1)", 69: "globalFX(2)", 70: "globalFX(3)", 71: "globalFX(4)",
    72: "filter", 73: "microphone",
    74: "browsePress(L)", 75: "movePress(L)", 76: "sizePress(L)",
    77: "browsePress(R)", 78: "movePress(R)", 79: "sizePress(R)",
    80: "jogTouch(L)", 81: "jogTouch(R)",
]

var previousButtons = [Bool](repeating: false, count: 88)
var previousEncoders = [Int](repeating: 0, count: 6)
var lastJog = [UInt32](repeating: 0, count: 2)
var previousAnalogs = [UInt16](repeating: 0xFFFF, count: 26)
var baselined = false

// Mirrors MX2Decoder.analogs, so an ANALOG line names the control it claims to be.
let analogNames: [String] = [
    "fxKnob(L,1)", "fxKnob(L,2)", "fxKnob(L,3)", "fxKnob(L,4)",
    "fxKnob(R,1)", "fxKnob(R,2)", "fxKnob(R,3)", "fxKnob(R,4)",
    "gain(L)", "eqHigh(L)", "eqMid(L)", "eqLow(L)", "channelFX(L)",
    "gain(R)", "eqHigh(R)", "eqMid(R)", "eqLow(R)", "channelFX(R)",
    "mainVolume", "cueMix", "cueVolume", "volume(L)", "volume(R)", "crossfader",
    "tempo(L)", "tempo(R)",
]
let stamp = DateFormatter()
stamp.dateFormat = "HH:mm:ss.SSS"

func log(_ s: String) {
    let line = stamp.string(from: Date()) + " " + s + "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    // Also append to a capture file so a guided session survives a terminal timeout.
    let path = NSHomeDirectory() + "/.hermes/cache/scratch/button-capture.log"
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line.data(using: .utf8)!)
    } else {
        try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }
}

func describeButtons(_ data: [UInt8]) {
    var now = [Bool](repeating: false, count: 88)
    for i in 0..<88 {
        now[i] = (data[i / 8] & (1 << (i % 8))) != 0
    }
    if baselined {
        for i in 0..<88 where now[i] != previousButtons[i] {
            let name = claimed[i] ?? "<UNCLAIMED>"
            log("BUTTON bit \(i) \(now[i] ? "PRESS  " : "RELEASE") claimed=\(name)")
        }
    }
    previousButtons = now
}

func describeEncoders(_ data: [UInt8]) {
    for i in 0..<6 {
        let nibble = Int((data[11 + i / 2] >> (4 * (i % 2))) & 0x0F)
        if baselined && nibble != previousEncoders[i] {
            let names = ["browse(L)", "move(L)", "size(L)", "browse(R)", "move(R)", "size(R)"]
            log("ENCODER \(names[i]) \(previousEncoders[i]) -> \(nibble) raw")
        }
        previousEncoders[i] = nibble
    }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let criteria: [String: Any] = [
    kIOHIDVendorIDKey: vendorID,
    kIOHIDProductIDKey: productID,
    kIOHIDPrimaryUsagePageKey: 0xff01,
    kIOHIDPrimaryUsageKey: 0,
]
IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)

IOHIDManagerRegisterInputReportCallback(manager, { _, _, _, _, reportID, report, length in
    let id = Int(reportID)
    let bytes = (0..<length).map { report[$0] }
    // Report 1 is [id][82 button bits][3 bytes of encoder nibbles] = 15 bytes total.
    if id == 1, bytes.count >= 14 {
        let payload = Array(bytes.dropFirst())
        describeButtons(payload)
        describeEncoders(payload)
        if !baselined {
            baselined = true
            log("baselined on report 1 — press one control at a time now")
        }
    } else if id == 2, bytes.count >= 53 {
        // Analog report: 26 little-endian u16 values, 12-bit range. Previously
        // unlogged, which made every knob and fader invisible to this probe.
        let payload = Array(bytes.dropFirst())
        if payload.count >= 52 {
            for i in 0..<26 {
                let v = UInt16(payload[i * 2]) | (UInt16(payload[i * 2 + 1]) << 8)
                if v != previousAnalogs[i] {
                    previousAnalogs[i] = v
                    let name = analogNames[i]
                    log("ANALOG \(i) \(name) value \(v)")
                }
            }
        }
    } else if id == 3 {
        // Jog: two little-endian u32 absolute positions. Report 3 is 20 bytes including
        // the ID, so the payload is 19 bytes and each side's position starts at payload
        // offset 3 + side*8 + 4 — the same layout MX2Decoder uses. Probing showed the
        // naive 4 + side*8 offset reads a byte early (values stepping by 200000 per
        // report, which is a byte shift, not real movement).
        //
        // The jog streams continuously at roughly 2kHz, which buried every button line
        // in 350k lines of noise. Only log a jog line when a position actually moves.
        let payload = Array(bytes.dropFirst())
        if payload.count >= 19 {
            for side in 0..<2 {
                let offset = 3 + side * 8 + 4
                if offset + 4 <= payload.count {
                    let v = UInt32(payload[offset]) | (UInt32(payload[offset + 1]) << 8)
                        | (UInt32(payload[offset + 2]) << 16) | (UInt32(payload[offset + 3]) << 24)
                    if v != lastJog[side] {
                        lastJog[side] = v
                        log("JOG side \(side) abs \(v)")
                    }
                }
            }
        }
    }
}, nil)

IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard opened == kIOReturnSuccess else {
    log("could not open MX2 HID manager: \(opened)")
    exit(1)
}
log("waiting for the Traktor MX2… (stop the bridge first if this hangs)")
CFRunLoopRun()
