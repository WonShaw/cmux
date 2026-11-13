import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("SettingsSearchIndex")
struct SettingsSearchIndexTests {
    @Test func exactAndSubstringMatchesRankAheadOfFuzzyFallbacks() {
        #expect(
            SettingsSearchIndex.entries(matching: "Terminal Config").first?.id
                == SettingsSearchIndex.settingID(for: .app, idSuffix: "terminal-config")
        )
        #expect(
            SettingsSearchIndex.entries(matching: "copy on select").first?.id
                == SettingsSearchIndex.settingID(for: .terminal, idSuffix: "copy-on-select")
        )
    }

    @Test func settingsPathAnchorIncludesAgentAutoResume() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "terminal.autoResumeAgentSessions")
                == SettingsSearchIndex.settingID(for: .terminal, idSuffix: "agent-auto-resume")
        )
    }

    @Test func conditionalAutoNamingAgentDoesNotReuseWorkspaceAutoNamingAnchor() {
        #expect(SettingsSearchIndex.anchorID(forSettingsPath: "automation.autoNamingAgent") == nil)
    }

    @Test func settingsPathAnchorIncludesTextBoxMaxLines() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "terminal.textBoxMaxLines")
                == SettingsSearchIndex.settingID(for: .textBox, idSuffix: "textbox-max-lines")
        )
    }

    @Test func settingsPathAnchorIncludesShowTextBoxOnNewTerminals() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "terminal.showTextBoxOnNewTerminals")
                == SettingsSearchIndex.settingID(for: .textBox, idSuffix: "show-textbox-new-terminals")
        )
    }

    @Test func settingsPathAnchorIncludesFocusTextBoxOnNewTerminals() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "terminal.focusTextBoxOnNewTerminals")
                == SettingsSearchIndex.settingID(for: .textBox, idSuffix: "focus-textbox-new-terminals")
        )
    }

    @Test func settingsPathAnchorIncludesWorkspaceWorkingDirectoryInheritance() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "app.workspaceInheritWorkingDirectory")
                == SettingsSearchIndex.settingID(for: .app, idSuffix: "workspace-inherit-working-directory")
        )
    }

    @Test func settingsPathAnchorIncludesIMessageMode() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "app.iMessageMode")
                == SettingsSearchIndex.settingID(for: .app, idSuffix: "imessage-mode")
        )
    }

    @Test func settingsPathAnchorIncludesShortcutBindings() {
        #expect(
            SettingsSearchIndex.anchorID(forSettingsPath: "shortcuts.bindings")
                == SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "shortcuts")
        )
    }

    private func assertSearch(_ query: String, contains expectedID: String) {
        let resultIDs = Set(SettingsSearchIndex.entries(matching: query).map(\.id))
        #expect(
            resultIDs.contains(expectedID),
            "Expected settings search for '\(query)' to include \(expectedID), got \(resultIDs.sorted())"
        )
    }
}
