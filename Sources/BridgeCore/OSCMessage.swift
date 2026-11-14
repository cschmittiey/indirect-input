import Foundation

public struct OSCMessage: Equatable, Sendable {
    public let address: String
    public let integer: Int32

    public init(address: String, integer: Int32) {
        self.address = address
        self.integer = integer
    }

    public var packet: Data {
        var data = Data()
        Self.appendPaddedString(address, to: &data)
        Self.appendPaddedString(",i", to: &data)
        var value = integer.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
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
