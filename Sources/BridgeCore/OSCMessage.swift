import Foundation

public enum OSCArgument: Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
}

public struct OSCMessage: Equatable, Sendable {
    public let address: String
    public let arguments: [OSCArgument]

    public var integer: Int32 {
        if case let .int(value)? = arguments.first { return value }
        return 0
    }

    public init(address: String, integer: Int32) {
        self.init(address: address, arguments: [.int(integer)])
    }

    public init(address: String, float: Float) {
        self.init(address: address, arguments: [.float(float)])
    }

    public init(address: String, arguments: [OSCArgument]) {
        self.address = address
        self.arguments = arguments
    }

    public var packet: Data {
        var data = Data()
        Self.appendPaddedString(address, to: &data)
        let tags = "," + arguments.map {
            switch $0 {
            case .int: return "i"
            case .float: return "f"
            case .string: return "s"
            }
        }.joined()
        Self.appendPaddedString(tags, to: &data)
        for argument in arguments {
            switch argument {
            case let .int(value):
                var bigEndian = value.bigEndian
                withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
            case let .float(value):
                var bigEndian = value.bitPattern.bigEndian
                withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
            case let .string(value):
                Self.appendPaddedString(value, to: &data)
            }
        }
        return data
    }

    private static func appendPaddedString(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
    }
}

public enum BridgeRouting {
    public static let defaultRoot = "/Syndicate"

    public static func message(for event: BrowseEvent,
                               root: String = defaultRoot,
                               shifted: Bool = false) -> OSCMessage {
        let direction = shifted
            ? (event.direction == .up ? "Left" : "Right")
            : event.direction.rawValue
        return OSCMessage(
            address: "\(root)/Browser/Navigation/\(direction)",
            integer: 1
        )
    }

    public static func loadMessage(deck: Int,
                                   root: String = defaultRoot) -> OSCMessage {
        OSCMessage(address: "\(root)/Browser/L\(deck)", integer: 1)
    }
}
