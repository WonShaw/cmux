import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cross-window Dock routing over the socket API: Dock-scoped commands anchor
/// to the Dock's owning window, explicitly contradictory selectors fail
/// closed, the legacy Global Dock alias keeps routing to the caller's window,
/// and the focused-close shortcut acts on its own window's Dock only.
/// See https://github.com/manaflow-ai/cmux/issues/7142.
@Suite("Window Dock socket routing", .serialized)
struct WindowDockRoutingSocketTests {
    @MainActor
    private func v2Envelope(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    @MainActor
    private func v2Result(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let envelope = try v2Envelope(method: method, params: params)
        if envelope["ok"] as? Bool != true {
            Issue.record("Expected \(method) to succeed: \(envelope)")
        }
        return try #require(envelope["result"] as? [String: Any])
    }

    @MainActor
    private func withDockEnabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let key = RightSidebarBetaFeatureSettings.dockEnabledKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try body()
    }

    @MainActor
    private func withDockEnabled(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let key = RightSidebarBetaFeatureSettings.dockEnabledKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try await body()
    }

    @MainActor
    private func withSocketAppContext(
        fileExplorerState: FileExplorerState? = nil,
        _ body: (TabManager, Workspace, UUID) throws -> Void
    ) throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        if let fileExplorerState {
            appDelegate.fileExplorerState = fileExplorerState
        }
        TerminalController.shared.setActiveTabManager(manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager,
            fileExplorerState: fileExplorerState
        )
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.tabs.first)
        try body(manager, workspace, windowId)
    }

    @Test("Dock focus commands fail when the owning Dock cannot be revealed")
    @MainActor
    func dockFocusCommandsFailWhenRevealIsUnavailable() throws {
        try withDockEnabled {
            try withSocketAppContext(fileExplorerState: nil) { _, _, windowId in
                let appDelegate = try #require(AppDelegate.shared)
                let dock = appDelegate.windowDock(forWindowId: windowId)
                let firstPane = try #require(dock.bonsplitController.allPaneIds.first)
                let firstSurfaceID = try #require(dock.newSurface(
                    kind: .terminal,
                    inPane: firstPane,
                    focus: true
                ))
                let secondSurfaceID = try #require(dock.newSplit(
                    kind: .terminal,
                    orientation: .vertical,
                    insertFirst: false,
                    sourcePanelId: firstSurfaceID,
                    focus: false
                ))
                let secondPane = try #require(dock.paneId(forPanelId: secondSurfaceID))

                dock.focusPanel(firstSurfaceID)
                dock.bonsplitController.focusPane(firstPane)
                #expect(dock.focusedPanelId == firstSurfaceID)
                #expect(dock.bonsplitController.focusedPaneId == firstPane)

                let surfaceEnvelope = try v2Envelope(method: "surface.focus", params: [
                    "workspace_id": windowId.uuidString,
                    "surface_id": secondSurfaceID.uuidString,
                ])
                #expect(surfaceEnvelope["ok"] as? Bool == false)
                let surfaceError = try #require(surfaceEnvelope["error"] as? [String: Any])
                #expect(surfaceError["code"] as? String == "unavailable")
                #expect(surfaceError["message"] as? String == "Dock could not be revealed")
                #expect(dock.focusedPanelId == firstSurfaceID)

                let paneEnvelope = try v2Envelope(method: "pane.focus", params: [
                    "workspace_id": windowId.uuidString,
                    "pane_id": secondPane.id.uuidString,
                ])
                #expect(paneEnvelope["ok"] as? Bool == false)
                let paneError = try #require(paneEnvelope["error"] as? [String: Any])
                #expect(paneError["code"] as? String == "unavailable")
                #expect(paneError["message"] as? String == "Dock could not be revealed")
                #expect(dock.bonsplitController.focusedPaneId == firstPane)
            }
        }
    }

    @Test("Hidden workspace Dock surfaces cannot focus through the visible window Dock")
    @MainActor
    func hiddenWorkspaceDockSurfaceFocusFailsClosed() throws {
        try withDockEnabled {
            let fileExplorerState = FileExplorerState()
            try withSocketAppContext(fileExplorerState: fileExplorerState) { _, workspace, _ in
                let mainPanelID = try #require(workspace.focusedPanelId)
                let workspaceDock = try #require(workspace.dockSplit)
                let pane = try #require(workspaceDock.bonsplitController.allPaneIds.first)
                let originalDockSurfaceID = try #require(workspaceDock.newSurface(
                    kind: .terminal,
                    inPane: pane,
                    focus: true
                ))
                let requestedDockSurfaceID = try #require(workspaceDock.newSurface(
                    kind: .terminal,
                    inPane: pane,
                    focus: false
                ))
                workspaceDock.focusPanel(originalDockSurfaceID)

                let envelope = try v2Envelope(method: "surface.focus", params: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": requestedDockSurfaceID.uuidString,
                ])

                #expect(envelope["ok"] as? Bool == false)
                let error = try #require(envelope["error"] as? [String: Any])
                #expect(error["code"] as? String == "unavailable")
                #expect(workspaceDock.focusedPanelId == originalDockSurfaceID)
                #expect(workspace.focusedPanelId == mainPanelID)
                #expect(!fileExplorerState.isVisible)
            }
        }
    }

}
