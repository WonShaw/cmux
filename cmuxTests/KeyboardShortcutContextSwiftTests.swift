import AppKit
import CmuxCommandPalette
import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias SimulatorStoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias SimulatorStoredShortcut = cmux.StoredShortcut
#endif

@Suite("Keyboard shortcut context")
struct KeyboardShortcutContextSwiftTests {
    @Test("Bulk notification shortcuts are shared, visible, and unbound by default")
    func bulkNotificationShortcutsAreSharedVisibleAndUnbound() throws {
        let actions: [KeyboardShortcutSettings.Action] = [
            .markAllNotificationsRead,
            .clearAllNotifications,
        ]

        for action in actions {
            #expect(action.defaultShortcut.isUnbound)
            #expect(action.shortcutContext == .application)
            #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(action))

            let sharedAction = try #require(ShortcutAction(rawValue: action.rawValue))
            #expect(sharedAction.defaultShortcut == nil)
            #expect(sharedAction.defaultFocusWhenClause == .always)
            #expect(ShortcutAction.settingsVisibleActions.contains(sharedAction))
        }
    }

    @Test("Simulator shortcuts are configurable, scoped, and priority routed")
    func simulatorShortcutPolicy() throws {
        let actions = KeyboardShortcutSettings.Action.simulatorActions
        #expect(actions.map(\.rawValue) == [
            "simulatorHome",
            "simulatorRotateLeft",
            "simulatorRotateRight",
            "simulatorToggleAppearance",
            "simulatorToggleSoftwareKeyboard",
        ])
        #expect(actions.allSatisfy { $0.shortcutContext == .simulatorPanel })
        #expect(actions.allSatisfy { $0.hasPriorityShortcutRouting })

        let expected: [KeyboardShortcutSettings.Action: SimulatorStoredShortcut] = [
            .simulatorHome: SimulatorStoredShortcut(key: "h", command: true, shift: true, option: false, control: false),
            .simulatorRotateLeft: SimulatorStoredShortcut(key: "←", command: true, shift: false, option: false, control: false),
            .simulatorRotateRight: SimulatorStoredShortcut(key: "→", command: true, shift: false, option: false, control: false),
            .simulatorToggleAppearance: SimulatorStoredShortcut(key: "a", command: true, shift: true, option: false, control: false),
            .simulatorToggleSoftwareKeyboard: SimulatorStoredShortcut(key: "k", command: true, shift: false, option: false, control: false),
        ]
        for action in actions {
            #expect(action.defaultShortcut == expected[action])
            let shared = try #require(ShortcutAction(rawValue: action.rawValue))
            #expect(shared.defaultFocusWhenClause == action.shortcutContext.defaultWhenClause)
            #expect(shared.hasPriorityShortcutRouting == action.hasPriorityShortcutRouting)
            #expect(ShortcutAction.settingsVisibleActions.contains(shared))
        }
    }

    @Test("Simulator context is available only for Simulator focus")
    func simulatorContextAvailability() {
        let context = KeyboardShortcutSettings.Action.simulatorHome.shortcutContext
        #expect(context.isAvailable(
            focusedMarkdownPanel: false,
            focusedSimulatorPanel: true,
            rightSidebarFocused: false
        ))
        #expect(!context.isAvailable(
            focusedMarkdownPanel: false,
            focusedSimulatorPanel: false,
            rightSidebarFocused: false
        ))

        var palette = CommandPaletteContextSnapshot()
        palette.setBool(CommandPaletteContextKeys.panelIsSimulator, true)
        #expect(context.isAvailable(commandPaletteContext: palette))
    }

    @Test("reopen last closed default yields to an explicit workspace binding")
    func reopenLastClosedDefaultYieldsToExplicitWorkspaceBinding() {
        let workspaceAction = KeyboardShortcutSettings.Action.reopenClosedWorkspace
        let reopenLastClosedAction = KeyboardShortcutSettings.Action.reopenClosedBrowserPanel
        let commandShiftT = reopenLastClosedAction.defaultShortcut

        let resolved = KeyboardShortcutSettings.defaultShortcutResolvingLegacyConflicts(
            for: reopenLastClosedAction,
            explicitlyConfiguredShortcut: { action in
                action == workspaceAction ? commandShiftT : nil
            }
        )

        #expect(resolved == nil)
        #expect(KeyboardShortcutSettings.defaultShortcutResolvingLegacyConflicts(
            for: reopenLastClosedAction,
            explicitlyConfiguredShortcut: { _ in nil }
        ) == commandShiftT)
        #expect(KeyboardShortcutSettings.defaultShortcutResolvingLegacyConflicts(
            for: reopenLastClosedAction,
            explicitlyConfiguredShortcut: { action in
                action == workspaceAction ? .unbound : nil
            }
        ) == nil)
    }

    @MainActor
    @Test("mark-all-read shortcut preserves rows and marks every notification read")
    func markAllNotificationsReadShortcutUsesNotificationStorePrimitive() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try Self.withIsolatedShortcutSettings {
                let shortcut = SimulatorStoredShortcut(
                    key: "r",
                    command: true,
                    shift: true,
                    option: true,
                    control: true
                )
                let notifications = [
                    TerminalNotification(
                        id: UUID(),
                        tabId: UUID(),
                        surfaceId: UUID(),
                        title: "Unread one",
                        subtitle: "",
                        body: "",
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        isRead: false
                    ),
                    TerminalNotification(
                        id: UUID(),
                        tabId: UUID(),
                        surfaceId: nil,
                        title: "Already read",
                        subtitle: "",
                        body: "",
                        createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                        isRead: true
                    ),
                ]
                let updated = try Self.exerciseBulkShortcut(
                    action: .markAllNotificationsRead,
                    shortcut: shortcut,
                    keyCode: 15,
                    notifications: notifications
                )
                #expect(updated.count == notifications.count)
                #expect(updated.allSatisfy { notification in notification.isRead })
            }
        }
    }

    @MainActor
    @Test("clear-all shortcut removes every notification")
    func clearAllNotificationsShortcutUsesNotificationStorePrimitive() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try Self.withIsolatedShortcutSettings {
                let shortcut = SimulatorStoredShortcut(
                    key: "z",
                    command: true,
                    shift: true,
                    option: true,
                    control: true
                )
                let updated = try Self.exerciseBulkShortcut(
                    action: .clearAllNotifications,
                    shortcut: shortcut,
                    keyCode: 6,
                    notifications: [
                        TerminalNotification(
                            id: UUID(),
                            tabId: UUID(),
                            surfaceId: UUID(),
                            title: "Dismiss me",
                            subtitle: "",
                            body: "",
                            createdAt: Date(timeIntervalSince1970: 1_700_000_002),
                            isRead: false
                        ),
                    ]
                )
                #expect(updated.isEmpty)
            }
        }
    }

    @MainActor
    private static func exerciseBulkShortcut(
        action: KeyboardShortcutSettings.Action,
        shortcut: SimulatorStoredShortcut,
        keyCode: UInt16,
        notifications: [TerminalNotification]
    ) throws -> [TerminalNotification] {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let window = try #require(mainWindow(for: windowId))
        let store = TerminalNotificationStore.shared
        let originalNotificationStore = appDelegate.notificationStore
        store.replaceNotificationsForTesting(notifications)
        appDelegate.notificationStore = store
        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
#if DEBUG
        appDelegate.debugResetShortcutRoutingStateForTesting(
            clearFocusedWindowOverride: false
        )
#endif
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shortcut.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: shortcut.key,
            charactersIgnoringModifiers: shortcut.key,
            isARepeat: false,
            keyCode: keyCode
        ))

#if DEBUG
        #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
        Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
        return store.notifications
    }

    @MainActor
    private static func withIsolatedShortcutSettings(
        _ body: () throws -> Void
    ) rethrows {
        let actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        let savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-bulk-notification-shortcuts"
        )
        KeyboardShortcutSettings.resetAll()
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(
            clearFocusedWindowOverride: false
        )
#endif
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            for action in KeyboardShortcutSettings.Action.allCases {
                if actionsWithPersistedShortcut.contains(action),
                   let savedShortcut = savedShortcutsByAction[action] {
                    KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: action)
                }
            }
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(
                clearFocusedWindowOverride: false
            )
#endif
        }
        try body()
    }

    @MainActor
    private static func mainWindow(for windowId: UUID) -> NSWindow? {
        AppDelegate.shared?.windowForMainWindowId(windowId)
    }

    @MainActor
    private static func closeWindow(withId windowId: UUID) {
        guard let window = mainWindow(for: windowId) else { return }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
    }
}

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testGeneralHelpListsSimulatorNamespace() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--help"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.contains("simulator <subcommand>"), result.stdout)
    }
}

@Suite("Stored shortcut physical-key matching")
struct StoredShortcutPhysicalKeyMatchingTests {
    @Test("recorded Option shortcut matches its physical key across layouts")
    func recordedOptionShortcutMatchesPhysicalKeyAcrossLayouts() {
        let shortcut = StoredShortcut(
            key: "1",
            command: false,
            shift: false,
            option: true,
            control: false,
            keyCode: 18
        )

        #expect(shortcut.matches(
            keyCode: 18,
            modifierFlags: [.option],
            eventCharacter: "&",
            layoutCharacterProvider: { _, _ in "&" }
        ))
        #expect(!shortcut.matches(
            keyCode: 19,
            modifierFlags: [.option],
            eventCharacter: "1",
            layoutCharacterProvider: { _, _ in "1" }
        ))
    }
}

private final class ZoomRouteRecordingTabManager: TabManager {
    private let browserResult: Bool?
    private let textPreviewResult: Bool?
    var calls: [String] = []

    init(browserResult: Bool?, textPreviewResult: Bool?) {
        self.browserResult = browserResult
        self.textPreviewResult = textPreviewResult
        super.init(autoWelcomeIfNeeded: false)
    }

    override func performFocusedTextFilePreviewZoom(_ action: (FilePreviewPanel) -> Bool) -> Bool? {
        guard let textPreviewResult else { return nil }
        calls.append("text")
        return textPreviewResult
    }
}
