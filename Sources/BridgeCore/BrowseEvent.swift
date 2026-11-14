import Foundation

public enum BrowseDirection: String, Sendable {
    case up = "Up"
    case down = "Down"
}

public struct BrowseEvent: Equatable, Sendable {
    public let direction: BrowseDirection
    public let value: UInt8

    public init(direction: BrowseDirection, value: UInt8) {
        self.direction = direction
        self.value = value
    }

    public init?(channel: UInt8, controller: UInt8, value: UInt8) {
        guard controller == 16 || controller == 19 else { return nil }
        switch value {
        case 63: self.init(direction: .up, value: value)
        case 65: self.init(direction: .down, value: value)
        default: return nil
        }
    }
}
