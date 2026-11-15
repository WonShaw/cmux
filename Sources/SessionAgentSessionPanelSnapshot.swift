import Foundation

/// Decodes agent session panel entries from sessions saved by older builds.
/// The agent session web panel was removed, so these entries are ignored on
/// restore; the fields are kept loose so old snapshots still decode.
struct SessionAgentSessionPanelSnapshot: Codable, Sendable {
    var rendererKind: String?
    var providerID: String?
    var workingDirectory: String?
}
