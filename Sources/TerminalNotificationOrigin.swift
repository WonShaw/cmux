import Foundation

/// Where a notification's text came from, carried with the notification through the
/// store, the hook envelope (`origin`, not hook-patchable), the hook and
/// `notifications.command` environments (`CMUX_NOTIFICATION_ORIGIN`), and the feed
/// history. Remote origins are untrusted emitters: the store clamps their side effects to
/// display (no reply shape, no click action, no agent context, no sound override), and
/// remote-origin notifications never consult project `cmux.json` hooks — only the global
/// config the user wrote on this Mac.
enum TerminalNotificationOrigin: Hashable, Sendable {
    /// A local process (socket caller, OSC from a local PTY, the app itself).
    case local

    static let localWireValue = "local"

    /// `local`; what hooks see
    /// in `CMUX_NOTIFICATION_ORIGIN` and in the envelope's `origin.value`.
    var wireValue: String {
        switch self {
        case .local:
            return Self.localWireValue
        }
    }

    /// Envelope `origin.kind`: `local` or `ssh-relay`.
    var kind: String {
        switch self {
        case .local: return "local"
        }
    }

    var isRemote: Bool {
        if case .local = self { return false }
        return true
    }

    /// Parses a wire value; anything unrecognized reads as `.local`, so a persisted
    /// history record written by a newer build still decodes.
    init(wireValue: String) {
        self = .local
    }
}

extension TerminalNotificationOrigin: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wireValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// The `origin` block of the notification-hook envelope. Informational input for hooks
/// (`case "$CMUX_NOTIFICATION_ORIGIN" in ssh-relay:*) …`), never patchable by them.
struct TerminalNotificationPolicyOriginContext: Codable, Sendable, Equatable {
    var kind: String
    var value: String

    init(_ origin: TerminalNotificationOrigin) {
        kind = origin.kind
        value = origin.wireValue
    }
}
