import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class ShortcutContextMenuActionProbe: NSObject {
    var callCount = 0

    @objc func perform(_ sender: Any?) {
        callCount += 1
    }
}

private final class ShortcutContextGhosttyCommandEquivalentProbeView: GhosttyNSView {
    var afterMenuMissCallCount = 0
    var keyDownCallCount = 0
    var lastAfterMenuMissCharactersIgnoringModifiers: String?
    var lastKeyDownCharactersIgnoringModifiers: String?
    var performAfterMenuMissResult = true

    override func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
        afterMenuMissCallCount += 1
        lastAfterMenuMissCharactersIgnoringModifiers = event.charactersIgnoringModifiers
        return performAfterMenuMissResult
    }

    override func keyDown(with event: NSEvent) {
        keyDownCallCount += 1
        lastKeyDownCharactersIgnoringModifiers = event.charactersIgnoringModifiers
    }
}

private final class ShortcutNotificationFlag {
    var wasPosted = false

    func markPosted() {
        wasPosted = true
    }
}

@MainActor
@Suite(.serialized)
struct AppDelegateRenameShortcutContextTests {
    @Test func defaultCmdRRequestsRenameTabOnlyWhenBrowserNotFocused() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(withId: windowId))
            let renameTabPosted = ShortcutNotificationFlag()
            let renameTabToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameTabRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameTabPosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameTabToken) }

            let renameWorkspacePosted = ShortcutNotificationFlag()
            let renameWorkspaceToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameWorkspaceRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameWorkspacePosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

            let cmdR = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command],
                keyCode: 15,
                windowNumber: window.windowNumber
            ))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: cmdR))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(renameTabPosted.wasPosted)
            #expect(!renameWorkspacePosted.wasPosted)
        }
    }

    @Test func defaultCmdShiftRRequestsRenameWorkspaceOnlyWhenBrowserNotFocused() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(withId: windowId))
            let renameWorkspacePosted = ShortcutNotificationFlag()
            let renameWorkspaceToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameWorkspaceRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameWorkspacePosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameWorkspaceToken) }

            let renameTabPosted = ShortcutNotificationFlag()
            let renameTabToken = NotificationCenter.default.addObserver(
                forName: .commandPaletteRenameTabRequested,
                object: nil,
                queue: nil
            ) { _ in
                renameTabPosted.markPosted()
            }
            defer { NotificationCenter.default.removeObserver(renameTabToken) }

            let cmdShiftR = try #require(makeKeyDownEvent(
                key: "r",
                modifiers: [.command, .shift],
                keyCode: 15,
                windowNumber: window.windowNumber
            ))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: cmdShiftR))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(renameWorkspacePosted.wasPosted)
            #expect(!renameTabPosted.wasPosted)
        }
    }

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
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
            prefix: "cmux-rename-shortcut-context"
        )
        KeyboardShortcutSettings.resetAll()
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
        }
        try body()
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func mainWindow(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = mainWindow(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
