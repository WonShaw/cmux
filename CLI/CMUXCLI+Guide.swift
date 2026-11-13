import Foundation

extension CMUXCLI {
    /// Guides are handled before socket discovery, authentication, and window focus.
    /// Only these command positions belong to cmux; an agent or exec payload can
    /// contain `--skill` without being intercepted.
    func runGuideCommand(command: String, commandArgs: [String], jsonOutput: Bool) throws -> Bool {
        guard command == "guide" || command == "--skill" else { return false }
        let remaining = commandArgs

        let invocation = "cmux guide | cmux --skill"
        let usageLabel = CMUXDiffViewerLocalization.string("cli.guide.usage", defaultValue: "Usage:")
        let usage = "\(usageLabel) \(invocation) [--json]\n\n" + Self.guideDescription
        if remaining == ["--help"] || remaining == ["-h"] {
            print(usage)
            return true
        }
        guard remaining.isEmpty else {
            throw CLIError(message: usage, exitCode: 2)
        }

        let content = Self.overviewGuide
        if jsonOutput {
            print(jsonString(["topic": "cmux", "format": "markdown", "content": content]))
        } else {
            print(content)
        }
        return true
    }

    static var guideDescription: String {
        CMUXDiffViewerLocalization.string(
            "cli.guide.description",
            defaultValue: "Read a short guide and find specific methods. No running app, network access, or sign-in is needed to read it."
        )
    }

    static var overviewGuide: String {
        """
        # cmux guide

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.intro", defaultValue: "cmux puts terminals, browsers, and agents in one workspace. Use this guide to choose a method, then read its help before acting. `cmux --skill` prints this same guide."))

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.targets", defaultValue: "## Find your target\n\nA window contains workspaces. A workspace contains split panes. Each pane contains surfaces, such as a terminal or browser tab. Inspect the caller and use the returned IDs. Keep the caller's workspace and surface context; use explicit targets and `--focus false` where supported."))

        ```sh
        cmux identify --json
        cmux tree --all --json
        cmux capabilities --json
        ```

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.terminals", defaultValue: "## Work with terminals\n\nCreate a workspace for a task, add panes for parallel work, and read terminal output before sending input. `send` enters text; `send-key` sends keys. Read the screen again to check the result."))

        `cmux new-workspace --help` · `cmux new-pane --help`
        `cmux read-screen --help` · `cmux send --help` · `cmux send-key --help`

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.shareLocal", defaultValue: "## Show work and find more methods\n\nUse Markdown and diff views to show results. Use notifications and progress to report task state. Settings and integration docs list their own methods."))

        `cmux markdown --help` · `cmux notify --help` · `cmux set-progress --help`
        `cmux docs settings` · `cmux docs agents` · `cmux docs api`
        """
    }
}
