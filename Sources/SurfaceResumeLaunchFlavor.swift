import Foundation

/// Selects where a saved resume command is allowed to execute.
///
/// This build only runs resume commands locally. Bindings persisted by older
/// builds for a cmux-managed ssh session decode as ``unsupportedRemote`` so
/// their command is never typed into a local shell automatically.
enum SurfaceResumeLaunchFlavor: Equatable, Hashable, Sendable {
    case local
    case unsupportedRemote

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    var executionLocationRawValue: String {
        switch self {
        case .local:
            return "local"
        case .unsupportedRemote:
            return "unsupported_remote"
        }
    }
}

extension SurfaceResumeLaunchFlavor: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind)
        // Anything other than an explicit local flavor (legacy "persistentSSH",
        // or a value written by a newer build) is not runnable here.
        self = kind == "local" ? .local : .unsupportedRemote
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode("local", forKey: .kind)
        case .unsupportedRemote:
            try container.encode("unsupportedRemote", forKey: .kind)
        }
    }
}
