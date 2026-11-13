public import Foundation

/// Environment overrides that keep a `git` subprocess strictly local.
///
/// Every `git` child process cmux spawns (app, CLI, packages) must run with
/// these applied so that no invocation can contact a remote, even
/// indirectly: partial-clone lazy fetches, LFS smudge downloads, credential
/// helpers, askpass prompts, and SSH/HTTP transports are all neutralised.
public enum GitOfflineEnvironment {
    /// The overrides applied on top of the inherited environment.
    public static let overrides: [String: String] = [
        // Never fetch missing objects from a promisor remote on demand.
        "GIT_NO_LAZY_FETCH": "1",
        // Never prompt on the terminal for credentials.
        "GIT_TERMINAL_PROMPT": "0",
        // Never download LFS objects through the smudge filter.
        "GIT_LFS_SKIP_SMUDGE": "1",
        // Neutralise credential/passphrase helpers.
        "GIT_ASKPASS": "/usr/bin/true",
        "SSH_ASKPASS": "/usr/bin/true",
        "SSH_ASKPASS_REQUIRE": "never",
        "GCM_INTERACTIVE": "never",
        // Only the local `file` transport is allowed; any accidental
        // network transport fails instead of connecting.
        "GIT_ALLOW_PROTOCOL": "file",
        "GIT_SSH_COMMAND": "/usr/bin/false",
        "GIT_SSH": "/usr/bin/false",
    ]

    /// Returns `environment` with ``overrides`` applied.
    ///
    /// - Parameter environment: The base environment; defaults to the
    ///   current process environment.
    /// - Returns: The environment to hand to a `git` child process.
    public static func applying(
        to environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        environment.merging(overrides) { _, override in override }
    }
}
