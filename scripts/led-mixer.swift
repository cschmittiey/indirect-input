// Light LED IDs 61-73 each a distinct colour, to map the mixer lamp block.
import Foundation
import IOKit.hid

let logPath = NSHomeDirectory() + "/.hermes/cache/scratch/ledmixer.out"
func logf(_ s: String) {
    print(s)
    let line = s + "\n"
    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
        defer { try? h.close() }; _ = try? h.seekToEnd()
        try? h.write(contentsOf: line.data(using: .utf8)!)
    } else { try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: logPath)) }
}
try? FileManager.default.removeItem(atPath: logPath)

let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x17cc, kIOHIDProductIDKey: 0x2420,
    kIOHIDPrimaryUsagePageKey: 0xff01, kIOHIDPrimaryUsageKey: 0] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { logf("manager fail"); exit(1) }
Thread.sleep(forTimeInterval: 0.5)
guard let d = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first,
      IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { logf("device fail"); exit(1) }
Thread.sleep(forTimeInterval: 0.3)

var f = [UInt8](repeating: 0, count: 105)
let names = ["red","orange","yellow","green","cyan","blue","purple","magenta"]
for id in 61...73 {
    let c = UInt8([1,3,5,7,9,11,14,15][(id - 61) % 8])
    f[id - 1] = c * 4 + 2
    logf(String(format: "LED %3d -> %@ (bright)", id, names[(id - 61) % 8]))
}
var payload = [UInt8(0x80)] + f
let r = payload.withUnsafeMutableBufferPointer {
    IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(0x80), $0.baseAddress!, $0.count)
}
logf("sent, IOReturn \(r) — look at the MIXER section now")
Thread.sleep(forTimeInterval: 150)
