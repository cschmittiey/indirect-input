import Foundation
import IndirectInputCore

public enum OSCParseError: Error {
    case malformed
}

public enum OSCParser {
    public static func messages(in data: Data) throws -> [(address: String, arguments: [OSCArgument])] {
        var offset = 0
        return try messages(in: data, offset: &offset)
    }

    private static func messages(in data: Data, offset: inout Int) throws -> [(address: String, arguments: [OSCArgument])] {
        let address = try string(in: data, offset: &offset)
        if address == "#bundle" {
            _ = try string(in: data, offset: &offset) // OSC time tag.
            var messages: [(String, [OSCArgument])] = []
            while offset < data.count {
                let size = try int32(in: data, offset: &offset)
                guard size > 0, offset + Int(size) <= data.count else { throw OSCParseError.malformed }
                messages += try Self.messages(in: data.subdata(in: offset..<offset + Int(size)), offset: &offset)
                offset += Int(size)
            }
            return messages
        }
        guard address.hasPrefix("/") else { throw OSCParseError.malformed }
        let tags = try string(in: data, offset: &offset)
        guard tags.hasPrefix(",") else { throw OSCParseError.malformed }
        var arguments: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i": arguments.append(.int(try int32(in: data, offset: &offset)))
            case "f":
                let bits = try uint32(in: data, offset: &offset)
                arguments.append(.float(Float(bitPattern: bits)))
            case "s": arguments.append(.string(try string(in: data, offset: &offset)))
            default: throw OSCParseError.malformed
            }
        }
        return [(address, arguments)]
    }

    private static func string(in data: Data, offset: inout Int) throws -> String {
        guard let end = data[offset...].firstIndex(of: 0), end < data.count else {
            throw OSCParseError.malformed
        }
        guard let string = String(data: data[offset..<end], encoding: .utf8) else {
            throw OSCParseError.malformed
        }
        offset = (end + 4) & ~3
        guard offset <= data.count else { throw OSCParseError.malformed }
        return string
    }

    private static func int32(in data: Data, offset: inout Int) throws -> Int32 {
        Int32(bitPattern: try uint32(in: data, offset: &offset))
    }

    private static func uint32(in data: Data, offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw OSCParseError.malformed }
        let value = data[offset...].prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }
}
