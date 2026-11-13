import CmuxSettings
import CmuxSidebar
import CmuxSidebarGit
import Foundation

typealias RightSidebarWidthSettings = CmuxSettings.RightSidebarWidthSettings

enum SidebarWorkspaceDetailDefaults {
    private static let sidebar = SidebarCatalogSection()

    static let showBranchDirectoryKey = sidebar.showBranchDirectory.userDefaultsKey
    static let watchGitStatusKey = sidebar.watchGitStatus.userDefaultsKey
    static let showPortsKey = sidebar.showPorts.userDefaultsKey
    static let showLogKey = sidebar.showLog.userDefaultsKey
    static let showProgressKey = sidebar.showProgress.userDefaultsKey
    static let showAgentActivityKey = sidebar.showAgentActivity.userDefaultsKey
    static let showCustomMetadataKey = sidebar.showCustomMetadata.userDefaultsKey

    static let showBranchDirectory = sidebar.showBranchDirectory.defaultValue
    static let watchGitStatus = sidebar.watchGitStatus.defaultValue
    static let showPorts = sidebar.showPorts.defaultValue
    static let showLog = sidebar.showLog.defaultValue
    static let showProgress = sidebar.showProgress.defaultValue
    static let showAgentActivity = sidebar.showAgentActivity.defaultValue
    static let showCustomMetadata = sidebar.showCustomMetadata.defaultValue
}

enum SidebarWorkspaceTitleWrapSettings {
    private static let setting = SidebarCatalogSection().wrapWorkspaceTitles
    static let key = setting.userDefaultsKey
    static let defaultWrap = setting.defaultValue

    static func wraps(defaults: UserDefaults = .standard) -> Bool {
        UserDefaultsSettingsClient(defaults: defaults).value(for: setting)
    }
}

extension SidebarWorkspaceDetailDefaults {
    static func boolValue(defaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    static func showBranchDirectoryValue(defaults: UserDefaults) -> Bool {
        UserDefaultsSettingsClient(defaults: defaults).value(for: SidebarCatalogSection().showBranchDirectory)
    }

    static func watchGitStatusValue(defaults: UserDefaults) -> Bool {
        UserDefaultsSettingsClient(defaults: defaults).value(for: SidebarCatalogSection().watchGitStatus)
    }

    static func auxiliaryDetailVisibility(defaults: UserDefaults) -> SidebarWorkspaceAuxiliaryDetailVisibility {
        let sidebar = SidebarCatalogSection()
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let details = SidebarWorkspaceDetailSettings(defaults: defaults)
        return SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
            showMetadata: details.showCustomMetadata,
            showLog: details.showLog,
            showProgress: details.showProgress,
            showBranchDirectory: details.showBranchDirectory,
            showPorts: details.showPorts,
            hideAllDetails: settings.value(for: sidebar.hideAllDetails)
        )
    }

    static func gitMetadataPollingEnabled(defaults: UserDefaults) -> Bool {
        gitMetadataActivity(defaults: defaults).performsActivePolling
    }

    static func gitMetadataActivity(defaults: UserDefaults) -> SidebarGitMetadataActivity {
        guard watchGitStatusValue(defaults: defaults) else {
            return .disabled
        }
        return auxiliaryDetailVisibility(defaults: defaults).requiresGitMetadata
            ? .activePolling
            : .passiveReportsOnly
    }
}

enum AutomationSettings {
    static let portBaseKey = "cmuxPortBase"
    static let portRangeKey = "cmuxPortRange"
    static let defaultPortBase = 9100
    static let defaultPortRange = 10
}

struct SettingsFileBooleanMapping {
    let jsonKey: String
    let defaultsKey: String
    let invalidPath: String?

    init(jsonKey: String, defaultsKey: String, invalidPath: String? = nil) {
        self.jsonKey = jsonKey
        self.defaultsKey = defaultsKey
        self.invalidPath = invalidPath
    }
}

struct SettingsFileStringMapping {
    let jsonKey: String
    let defaultsKey: String
}

enum AppSettingsFileMapping {
    private static let app = AppCatalogSection()

    static let booleanSettings: [SettingsFileBooleanMapping] = [
        .init(
            jsonKey: "workspaceInheritWorkingDirectory",
            defaultsKey: app.workspaceInheritWorkingDirectory.userDefaultsKey,
            invalidPath: "app.workspaceInheritWorkingDirectory"
        ),
        .init(jsonKey: "focusPaneOnFirstClick", defaultsKey: PaneFirstClickFocusSettings.enabledKey),
        .init(
            jsonKey: "focusHistoryIncludesPanesAndTabs",
            defaultsKey: app.focusHistoryIncludesPanesAndTabs.userDefaultsKey
        ),
        .init(
            jsonKey: "openSupportedFilesInCmux",
            defaultsKey: app.openSupportedFilesInCmux.userDefaultsKey
        ),
        .init(
            jsonKey: "openMarkdownInCmuxViewer",
            defaultsKey: app.openMarkdownInCmuxViewer.userDefaultsKey
        ),
        .init(jsonKey: "reorderOnNotification", defaultsKey: app.reorderOnNotification.userDefaultsKey),
        .init(jsonKey: "iMessageMode", defaultsKey: IMessageModeSettings.key),
        .init(
            jsonKey: "warnBeforeClosingTab",
            defaultsKey: app.warnBeforeClosingTab.userDefaultsKey
        ),
        .init(
            jsonKey: "warnBeforeClosingTabXButton",
            defaultsKey: app.warnBeforeClosingTabXButton.userDefaultsKey
        ),
        .init(
            jsonKey: "hideTabCloseButton",
            defaultsKey: app.hideTabCloseButton.userDefaultsKey
        ),
        .init(
            jsonKey: "renameSelectsExistingName",
            defaultsKey: app.renameSelectsExistingName.userDefaultsKey
        ),
        .init(
            jsonKey: "commandPaletteSearchesAllSurfaces",
            defaultsKey: app.commandPaletteSearchesAllSurfaces.userDefaultsKey
        ),
    ]

    static let stringSettings: [SettingsFileStringMapping] = [
        .init(jsonKey: "preferredEditor", defaultsKey: app.preferredEditor.userDefaultsKey),
    ]
}

enum NotificationSettingsFileMapping {
    private static let notifications = NotificationsCatalogSection()

    static let booleanSettings: [SettingsFileBooleanMapping] = [
        .init(jsonKey: "dockBadge", defaultsKey: NotificationBadgeSettings.dockBadgeEnabledKey),
        .init(jsonKey: "showInMenuBar", defaultsKey: MenuBarExtraSettings.showInMenuBarKey),
        .init(jsonKey: "unreadPaneRing", defaultsKey: NotificationPaneRingSettings.enabledKey),
        .init(jsonKey: "paneFlash", defaultsKey: NotificationPaneFlashSettings.enabledKey),
        .init(
            jsonKey: "suppressOnlyFocusedSurface",
            defaultsKey: notifications.suppressOnlyFocusedSurface.userDefaultsKey
        ),
        .init(
            jsonKey: "agentPermissionPrompt",
            defaultsKey: notifications.agentPermissionPrompt.userDefaultsKey
        ),
        .init(
            jsonKey: "agentIdleReminder",
            defaultsKey: notifications.agentIdleReminder.userDefaultsKey
        ),
    ]

    static let stringSettings: [SettingsFileStringMapping] = [
        .init(jsonKey: "customSoundFilePath", defaultsKey: NotificationSoundSettings.customFilePathKey),
        .init(jsonKey: "command", defaultsKey: NotificationSoundSettings.customCommandKey),
        // agentTurnComplete is enum-valued and validated explicitly in
        // parseNotificationsSection, like notifications.sound.
    ]
}

enum TerminalSettingsFileMapping {
    private static let terminal = TerminalCatalogSection()

    static let booleanSettings: [SettingsFileBooleanMapping] = [
        .init(
            jsonKey: "adaptiveDefaultTheme",
            defaultsKey: terminal.adaptiveDefaultTheme.userDefaultsKey,
            invalidPath: terminal.adaptiveDefaultTheme.id
        ),
        .init(
            jsonKey: "showScrollBar",
            defaultsKey: TerminalScrollBarSettings.showScrollBarKey,
            invalidPath: "terminal.showScrollBar"
        ),
        .init(
            jsonKey: "copyOnSelect",
            defaultsKey: TerminalCopyOnSelectSettings.copyOnSelectKey,
            invalidPath: "terminal.copyOnSelect"
        ),
        .init(
            jsonKey: "autoResumeAgentSessions",
            defaultsKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey,
            invalidPath: "terminal.autoResumeAgentSessions"
        ),
    ]
}

enum SidebarSettingsFileMapping {
    private static let sidebar = SidebarCatalogSection()

    struct BooleanSetting {
        let jsonKey: String
        let defaultsKey: String
    }

    static let booleanSettings: [BooleanSetting] = [
        .init(
            jsonKey: "hideAllDetails",
            defaultsKey: sidebar.hideAllDetails.userDefaultsKey
        ),
        .init(
            jsonKey: "wrapWorkspaceTitles",
            defaultsKey: SidebarWorkspaceTitleWrapSettings.key
        ),
        .init(
            jsonKey: "showWorkspaceDescription",
            defaultsKey: sidebar.showWorkspaceDescription.userDefaultsKey
        ),
        .init(
            jsonKey: "stackBranchDirectory",
            defaultsKey: sidebar.stackBranchDirectory.userDefaultsKey
        ),
        .init(
            jsonKey: "pathLastSegmentOnly",
            defaultsKey: sidebar.pathLastSegmentOnly.userDefaultsKey
        ),
        .init(
            jsonKey: "showNotificationMessage",
            defaultsKey: sidebar.showNotificationMessage.userDefaultsKey
        ),
        .init(
            jsonKey: "showBranchDirectory",
            defaultsKey: SidebarWorkspaceDetailDefaults.showBranchDirectoryKey
        ),
        .init(
            jsonKey: "watchGitStatus",
            defaultsKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey
        ),
        .init(jsonKey: "showPorts", defaultsKey: SidebarWorkspaceDetailDefaults.showPortsKey),
        .init(jsonKey: "showLog", defaultsKey: SidebarWorkspaceDetailDefaults.showLogKey),
        .init(
            jsonKey: "showProgress",
            defaultsKey: SidebarWorkspaceDetailDefaults.showProgressKey
        ),
        .init(
            jsonKey: "showAgentActivity",
            defaultsKey: SidebarWorkspaceDetailDefaults.showAgentActivityKey
        ),
        .init(
            jsonKey: "showCustomMetadata",
            defaultsKey: SidebarWorkspaceDetailDefaults.showCustomMetadataKey
        ),
    ]

    static func branchLayoutStoredValue(_ rawValue: String) -> Bool? {
        switch rawValue {
        case "vertical":
            return true
        case "inline":
            return false
        default:
            return nil
        }
    }
}

enum AutomationSettingsFileMapping {
    private static let automation = AutomationCatalogSection()

    static let booleanSettings: [SettingsFileBooleanMapping] = [
        .init(jsonKey: "claudeCodeIntegration", defaultsKey: automation.claudeCodeIntegration.userDefaultsKey),
        .init(
            jsonKey: "suppressSubagentNotifications",
            defaultsKey: automation.suppressSubagentNotifications.userDefaultsKey
        ),
        .init(jsonKey: "ampIntegration", defaultsKey: automation.ampIntegration.userDefaultsKey),
        .init(jsonKey: "cursorIntegration", defaultsKey: automation.cursorIntegration.userDefaultsKey),
        .init(jsonKey: "geminiIntegration", defaultsKey: automation.geminiIntegration.userDefaultsKey),
        .init(jsonKey: "kiroIntegration", defaultsKey: automation.kiroIntegration.userDefaultsKey),
        .init(jsonKey: "workspaceAutoNaming", defaultsKey: automation.workspaceAutoNaming.userDefaultsKey),
    ]

    static let stringSettings: [SettingsFileStringMapping] = [
        .init(jsonKey: "claudeBinaryPath", defaultsKey: automation.claudeBinaryPath.userDefaultsKey),
        .init(jsonKey: "ripgrepBinaryPath", defaultsKey: automation.ripgrepBinaryPath.userDefaultsKey),
        .init(jsonKey: "autoNamingAgent", defaultsKey: automation.autoNamingAgent.userDefaultsKey),
    ]
}
