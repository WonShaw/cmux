import Foundation

/// Decides whether a local feature-flag override may outrank a remote value.
/// No flag currently grants that exception, so remote values always win.
struct CmuxFeatureFlagOverrideCapability: Equatable, Sendable {
    init(bundle: Bundle = .main) {}

    func policy(for definition: CmuxFeatureFlagDefinition) -> CmuxFeatureFlagOverridePolicy {
        .remoteFirst
    }
}
