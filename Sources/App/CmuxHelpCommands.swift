import AppKit
import SwiftUI

extension cmuxApp {
    @CommandsBuilder
    var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            primaryDocsHelpMenuItems
            secondaryDocsHelpMenuItems

            Divider()

            Divider()

            helpResourceButton(.githubIssues)
            helpResourceButton(.discord)
            #if DEBUG
            Button(String(localized: "menu.help.featureFlags", defaultValue: "Feature Flags…")) {
                InternalFlagsPresenter.present()
            }
            Button(
                String(
                    localized: "debug.menu.sidebarFooterIconBalance",
                    defaultValue: "Footer Icon Balance Lab…"
                )
            ) {
                AppDelegate.shared?.debugWindowsCoordinator.showSidebarFooterIconBalanceWindow()
            }
            #endif

            Divider()

            Button(String(localized: "menu.help.keyboardShortcutsSettings", defaultValue: "Keyboard Shortcuts Settings…")) {
                openKeyboardShortcutsFromHelpMenu()
            }
        }
    }

    @ViewBuilder
    private var primaryDocsHelpMenuItems: some View {
        helpResourceButton(.gettingStarted)
        helpResourceButton(.concepts)
        helpResourceButton(.configuration)
        helpResourceButton(.customCommands)
        helpResourceButton(.dock)
        helpResourceButton(.keyboardShortcuts)
        helpResourceButton(.apiReference)
    }

    @ViewBuilder
    private var secondaryDocsHelpMenuItems: some View {
        helpResourceButton(.notifications)
        helpResourceButton(.skills)
        agentIntegrationsHelpMenu
        helpResourceButton(.changelog)
    }

    private var agentIntegrationsHelpMenu: some View {
        Menu(String(localized: "menu.help.agentIntegrations", defaultValue: "Agent Integrations")) {
            helpResourceButton(.claudeCodeTeams)
            helpResourceButton(.ohMyOpenCode)
            helpResourceButton(.ohMyCodex)
            helpResourceButton(.ohMyClaudeCode)
        }
    }

    private func helpResourceButton(_ resource: CmuxHelpResource) -> some View {
        Button(resource.title) {
            NSWorkspace.shared.open(resource.url)
        }
    }

    private func openKeyboardShortcutsFromHelpMenu() {
        if let appDelegate = AppDelegate.shared {
            appDelegate.openPreferencesWindow(
                debugSource: "helpMenu.keyboardShortcuts",
                navigationTarget: .keyboardShortcuts
            )
        } else {
            AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
        }
    }
}
