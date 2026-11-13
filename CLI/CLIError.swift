import Foundation

struct CLIError: Error, CustomStringConvertible {
    enum SocketFailureKind: Equatable {
        case pathMissing
        case pathInspectionFailed
        case pathTypeConflict
        case pathOwnershipConflict
        case startupTimeout
    }

    let message: String
    let exitCode: Int32
    /// Structured v2 protocol error code when the failure came from a v2 error response.
    let v2Code: String?
    /// Whether this error was decoded directly from a socket v2 error response.
    /// Local CLI sentinels may reuse ``v2Code`` for their own exit-status contract.
    let isStructuredProtocolResponse: Bool
    /// Whether the v2 error's data marked the failure as retryable (for example a
    /// `busy` answer while the app's process scan settles), so callers can wait
    /// and retry structurally instead of parsing display text.
    let v2Retryable: Bool
    let socketFailureKind: SocketFailureKind?

    init(
        message: String,
        exitCode: Int32 = 1,
        v2Code: String? = nil,
        isStructuredProtocolResponse: Bool = false,
        v2Retryable: Bool = false,
        socketFailureKind: SocketFailureKind? = nil
    ) {
        self.message = message
        self.exitCode = exitCode
        self.v2Code = v2Code
        self.isStructuredProtocolResponse = isStructuredProtocolResponse
        self.v2Retryable = v2Retryable
        self.socketFailureKind = socketFailureKind
    }

    var description: String { message }
}
