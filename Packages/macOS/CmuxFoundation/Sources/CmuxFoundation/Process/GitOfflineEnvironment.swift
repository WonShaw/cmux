public import Foundation

/// Environment overrides that keep a `git` subprocess strictly local and
/// stop the repository it runs in from executing anything.
///
/// Every `git` child process cmux spawns (app, CLI, packages) must run with
/// these applied. They do two things:
///
/// - No invocation can contact a remote, even indirectly: partial-clone lazy
///   fetches, LFS smudge downloads, credential helpers, askpass prompts, and
///   all transports are neutralised.
/// - A repository the user merely `cd`s into cannot make cmux run a program.
///   cmux runs `git status` and similar commands automatically in whatever
///   directory a terminal reports, so repository-local configuration such as
///   `core.fsmonitor` or hooks would otherwise execute attacker-chosen
///   commands. Configuration passed through `GIT_CONFIG_COUNT` has command-line
///   precedence, so it overrides anything in the repository's `.git/config`.
public enum GitOfflineEnvironment {
    /// Plain environment overrides applied on top of the inherited environment.
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
        // No transport at all is allowed, including the local `file`
        // transport, whose upload-pack command is repository-configurable.
        "GIT_ALLOW_PROTOCOL": "cmux-none",
        "GIT_SSH_COMMAND": "/usr/bin/false",
        "GIT_SSH": "/usr/bin/false",
        // Never page or open an editor.
        "GIT_PAGER": "cat",
        "GIT_EDITOR": "/usr/bin/false",
    ]

    /// Configuration forced with command-line precedence on every invocation.
    public static let configOverrides: [(key: String, value: String)] = [
        // `git status` and index reads run this program.
        ("core.fsmonitor", "false"),
        // Commands such as `worktree add` run hooks.
        ("core.hooksPath", "/dev/null"),
        // A committed directory that looks like a bare repository must not be
        // discovered as one (it carries its own config).
        ("safe.bareRepository", "explicit"),
        // Reset any `safe.directory = *` from the user's global config so git's
        // ownership check protects cmux's own invocations again.
        ("safe.directory", ""),
        ("protocol.allow", "never"),
        ("credential.helper", ""),
        ("core.sshCommand", "/usr/bin/false"),
        ("core.pager", "cat"),
    ]

    /// Environment keys that inject configuration and are replaced wholesale.
    static func isInjectedConfigKey(_ key: String) -> Bool {
        key == "GIT_CONFIG_PARAMETERS" || key == "GIT_CONFIG_COUNT"
            || key.hasPrefix("GIT_CONFIG_KEY_") || key.hasPrefix("GIT_CONFIG_VALUE_")
    }

    /// Returns `environment` with ``overrides`` and ``configOverrides`` applied.
    ///
    /// - Parameter environment: The base environment; defaults to the
    ///   current process environment.
    /// - Returns: The environment to hand to a `git` child process.
    public static func applying(
        to environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = environment.filter { !isInjectedConfigKey($0.key) }
        result.merge(overrides) { _, override in override }
        result["GIT_CONFIG_COUNT"] = String(configOverrides.count)
        for (index, entry) in configOverrides.enumerated() {
            result["GIT_CONFIG_KEY_\(index)"] = entry.key
            result["GIT_CONFIG_VALUE_\(index)"] = entry.value
        }
        return result
    }

    /// `-c` arguments that disable every content filter driver defined by the
    /// repository itself (local or worktree scope), for commands such as
    /// `git status` that may run clean filters.
    ///
    /// Filter drivers cannot be switched off with a single setting, so their
    /// names are read first. Reading configuration never executes anything.
    /// Drivers from the user's global or system configuration (for example
    /// Git LFS) are trusted and left alone.
    ///
    /// - Parameters:
    ///   - gitExecutable: The `git` binary to query.
    ///   - directory: The working directory the real command will run in.
    ///   - environment: The environment for the query, normally the result of
    ///     ``applying(to:)``.
    /// - Returns: Arguments to place before the subcommand. If the query fails
    ///   the caller should not run a filter-capable command.
    public static func repositoryFilterNeutralizingArguments(
        gitExecutable: URL,
        directory: URL,
        environment: [String: String]
    ) -> [String]? {
        let process = Process()
        process.executableURL = gitExecutable
        process.arguments = ["config", "--show-scope", "--name-only", "--get-regexp", "^filter\\."]
        process.currentDirectoryURL = directory
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Exit status 1 means "no matching keys".
        if process.terminationStatus == 1 { return [] }
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return filterNeutralizingArguments(fromScopedNames: text)
    }

    /// Parses `git config --show-scope --name-only` output into `-c`
    /// arguments for repository-scoped filter drivers.
    static func filterNeutralizingArguments(fromScopedNames text: String) -> [String] {
        var drivers: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let scope = parts[0]
            guard scope == "local" || scope == "worktree" || scope == "command" else { continue }
            let name = parts[1]
            guard name.hasPrefix("filter."),
                  let lastDot = name.lastIndex(of: "."),
                  lastDot > name.index(name.startIndex, offsetBy: 7) else { continue }
            let driver = String(name[name.index(name.startIndex, offsetBy: 7)..<lastDot])
            if !drivers.contains(driver) { drivers.append(driver) }
        }
        var arguments: [String] = []
        for driver in drivers {
            for key in ["clean", "smudge", "process"] {
                arguments += ["-c", "filter.\(driver).\(key)="]
            }
            arguments += ["-c", "filter.\(driver).required=false"]
        }
        return arguments
    }
}
