import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension GlobalSearchShortcutBehaviorTests {
    @MainActor @Suite final class GlobalSearchShortcutPriorityTests {
    private let originalSettingsFileStore: KeyboardShortcutSettingsFileStore

    init() {
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-priority-\(UUID().uuidString).json")
                .path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()
    }

    deinit {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    @Test func rightSidebarModeOwnsOverlappingGlobalSearchShortcut() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        let window = try #require(findWindow(withId: windowId))
        let fileExplorerState = try #require(appDelegate.fileExplorerState)
        defer {
            GlobalSearchCoordinator.shared.dismissPalette()
            appDelegate.debugResetShortcutRoutingStateForTesting()
            closeWindow(window, appDelegate: appDelegate)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        fileExplorerState.mode = .sessions
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: window)
        _ = window.makeFirstResponder(nil)

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "1",
                command: false,
                shift: false,
                option: false,
                control: true
            ),
            for: .globalSearch
        )
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        let event = try makeKeyEvent(
            type: .keyDown,
            key: "1",
            modifiers: [.control],
            keyCode: 18,
            windowNumber: window.windowNumber
        )

        #expect(appDelegate.debugHandleCustomShortcut(event: event))
        #expect(
            fileExplorerState.mode == .files,
            "A focused right-sidebar mode shortcut must run before overlapping app shortcuts"
        )
        #expect(
            !GlobalSearchCoordinator.shared.isPaletteVisible(),
            "Global Search must not steal a stroke owned by the focused right sidebar"
        )
#else
        Issue.record("Global Search shortcut-priority routing requires a DEBUG build")
#endif
    }

    @Test func commandPaletteEditingOwnsOverlappingGlobalSearchShortcut() throws {
        try assertCommandPaletteEditingOwnsUnarmedGlobalSearchBinding(
            StoredShortcut(
                key: "c",
                command: true,
                shift: false,
                option: false,
                control: false
            )
        )
    }

    @Test func commandPaletteEditingOwnsOverlappingGlobalSearchChordPrefix() throws {
        try assertCommandPaletteEditingOwnsUnarmedGlobalSearchBinding(
            StoredShortcut(
                key: "c",
                command: true,
                shift: false,
                option: false,
                control: false,
                chordKey: "g",
                chordCommand: true
            )
        )
    }

    private func assertCommandPaletteEditingOwnsUnarmedGlobalSearchBinding(
        _ shortcut: StoredShortcut
    ) throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        let window = try #require(findWindow(withId: windowId))
        defer {
            GlobalSearchCoordinator.shared.dismissPalette()
            appDelegate.setCommandPaletteVisible(false, for: window)
            appDelegate.debugResetShortcutRoutingStateForTesting()
            closeWindow(window, appDelegate: appDelegate)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        appDelegate.setCommandPaletteVisible(true, for: window)
        #expect(appDelegate.isCommandPaletteEffectivelyVisible(for: window))

        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)
        appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)

        let prefixEvent = try makeKeyEvent(
            type: .keyDown,
            key: "c",
            modifiers: [.command],
            keyCode: 8,
            windowNumber: window.windowNumber
        )
        #expect(
            !appDelegate.debugHandleCustomShortcut(event: prefixEvent),
            "Command-palette editing must own Cmd-C before an unarmed Global Search binding"
        )

        if shortcut.hasChord {
            let suffixEvent = try makeKeyEvent(
                type: .keyDown,
                key: "g",
                modifiers: [.command],
                keyCode: 5,
                windowNumber: window.windowNumber
            )
            _ = appDelegate.debugHandleCustomShortcut(event: suffixEvent)
        }
        #expect(
            !GlobalSearchCoordinator.shared.isPaletteVisible(),
            "A command-palette editing command must not toggle or arm Global Search"
        )
#else
        Issue.record("Global Search shortcut-priority routing requires a DEBUG build")
#endif
    }

    private func makeKeyEvent(
        type: NSEvent.EventType,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw TestHarnessError.eventUnavailable
        }
        return event
    }

    private func findWindow(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(_ window: NSWindow, appDelegate: AppDelegate) {
#if DEBUG
        let originalConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
#endif
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
    }

    private enum TestHarnessError: Error {
        case browserHarnessUnavailable
        case omnibarFocusUnavailable
        case eventUnavailable
    }
    }
}
