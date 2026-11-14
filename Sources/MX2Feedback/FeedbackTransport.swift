import Foundation

/// Transport constants that must be readable off the main actor: the socket read
/// loop runs on a private queue, so anything it touches has to be isolation-free.
enum FeedbackTransport {
    /// UDP payload ceiling. A datagram cannot exceed this; recv(2) truncates anything
    /// larger, which the parser then rejects as malformed.
    static let maximumDatagramSize = 65_535
}
