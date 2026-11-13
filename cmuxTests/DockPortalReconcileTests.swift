import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock portal reconcile", .serialized)
struct DockPortalReconcileTests {
    @Test("Delayed workspace host cannot reclaim a terminal after Dock handoff")
    @MainActor
    func delayedWorkspaceHostCannotReclaimTerminalAfterDockHandoff() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }
        let sourceHost = NSView()
        let dockHost = NSView()
        let sourcePane = PaneID()
        let dockPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(sourceHost),
            paneId: sourcePane,
            instanceSerial: 1,
            inWindow: true,
            bounds: bounds,
            reason: "test.workspace.initial"
        ))
        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(dockHost),
            paneId: dockPane,
            instanceSerial: 2,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.handoff"
        ))

        #expect(!panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(sourceHost),
            paneId: sourcePane,
            instanceSerial: 1,
            inWindow: true,
            bounds: bounds,
            reason: "test.workspace.delayedCallback"
        ))
        #expect(panel.surface.debugPortalHostLease().paneId == dockPane.id)
    }

    @Test("Detached replacement cannot displace a rearmed Dock portal host")
    @MainActor
    func detachedReplacementCannotDisplaceRearmedDockPortalHost() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }
        let liveHost = NSView()
        let detachedReplacement = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(liveHost),
            paneId: pane,
            instanceSerial: 1,
            ownershipGeneration: 1,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.liveHost"
        ))
        #expect(panel.surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(liveHost),
            instanceSerial: 1,
            reason: "test.dock.liveHostDismantled"
        ))

        #expect(!panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(detachedReplacement),
            paneId: pane,
            instanceSerial: 2,
            ownershipGeneration: 2,
            inWindow: false,
            bounds: .zero,
            reason: "test.dock.detachedReplacement"
        ))
        #expect(
            panel.surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(liveHost))
        )

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(detachedReplacement),
            paneId: pane,
            instanceSerial: 2,
            ownershipGeneration: 2,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.attachedReplacement"
        ))
    }

    @Test("Newer stale workspace host is rejected by live Dock ownership")
    @MainActor
    func newerStaleWorkspaceHostIsRejectedByLiveDockOwnership() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }
        let dockHost = NSView()
        let staleWorkspaceHost = NSView()
        let dockPane = PaneID()
        let staleWorkspacePane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(dockHost),
            paneId: dockPane,
            instanceSerial: 2,
            ownershipGeneration: 2,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.liveOwner"
        ))
        #expect(!panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(staleWorkspaceHost),
            paneId: staleWorkspacePane,
            instanceSerial: 3,
            ownershipGeneration: 2,
            inWindow: true,
            bounds: bounds,
            allowsAuthorityAcquisition: false,
            reason: "test.workspace.modelIneligible"
        ))
        #expect(panel.surface.debugPortalHostLease().paneId == dockPane.id)
    }

    @Test("New model ownership permits rollback to an earlier host")
    @MainActor
    func newModelOwnershipPermitsRollbackToEarlierHost() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }
        let workspaceHost = NSView()
        let dockHost = NSView()
        let workspacePane = PaneID()
        let dockPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(workspaceHost),
            paneId: workspacePane,
            instanceSerial: 10,
            ownershipGeneration: 1,
            inWindow: true,
            bounds: bounds,
            reason: "test.workspace.beforeMove"
        ))
        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(dockHost),
            paneId: dockPane,
            instanceSerial: 20,
            ownershipGeneration: 2,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.move"
        ))
        panel.surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(dockHost),
            instanceSerial: 20,
            reason: "test.dock.rollback"
        )

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(workspaceHost),
            paneId: workspacePane,
            instanceSerial: 10,
            ownershipGeneration: 3,
            inWindow: true,
            bounds: bounds,
            reason: "test.workspace.rollback"
        ))
        #expect(panel.surface.debugPortalHostLease().paneId == workspacePane.id)
    }

    @Test("Terminal stale portal bind reconciles without focus")
    @MainActor
    func dockTerminalStalePortalBindReconcilesWithoutFocus() throws {
        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        store.setVisibleInUI(true)
        let panelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        let terminal = try #require(store.panel(for: tabId) as? TerminalPanel)

        let window = Self.portalWindow()
        defer { Self.closePortalWindow(window) }
        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 240, height: 160))
        window.contentView?.addSubview(anchor)
        TerminalWindowPortalRegistry.bind(
            hostedView: terminal.hostedView,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: terminal.surface.id,
            expectedGeneration: terminal.surface.portalBindingGeneration()
        )
        anchor.removeFromSuperview()
        let reattachTokenBefore = terminal.viewReattachToken

        store.reconcileDockPortalPass(reason: "test.dockPortalReconcile")

        #expect(terminal.viewReattachToken > reattachTokenBefore)
    }

    @Test("Move into Dock schedules portal reconcile")
    @MainActor
    func moveIntoDockSchedulesPortalReconcile() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            let sourcePanel = try #require(workspace.panels.values.first)
            let sourceTabId = try #require(workspace.surfaceIdFromPanelId(sourcePanel.id))
            let dock = workspace.requiredDockSplitForTesting
            let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
            dock.setVisibleInUI(true)
            dock.clearDockPortalReconcile()
            dock.dockPortalReconcileState.scheduledRequestCount = 0

            let moved = appDelegate.moveSurfaceIntoDock(
                sourceTabId: sourceTabId.uuid,
                destinationDock: dock,
                destination: .insert(targetPane: rootPane, targetIndex: nil)
            )

            #expect(moved)
            #expect(dock.dockPortalReconcileState.scheduledRequestCount > 0)
        }
    }

    @Test("Simulator surface stays with workspace owner")
    @MainActor
    func simulatorSurfaceCannotMoveIntoDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            let pane = try #require(workspace.bonsplitController.allPaneIds.first)
            let simulator = try #require(workspace.newSimulatorSurface(inPane: pane, focus: false))
            let sourceTabId = try #require(workspace.surfaceIdFromPanelId(simulator.id))
            let dock = workspace.requiredDockSplitForTesting
            let rootPane = try #require(dock.bonsplitController.allPaneIds.first)

            #expect(!appDelegate.canMoveSurfaceIntoDock(
                sourceTabId: sourceTabId.uuid,
                destinationDock: dock
            ))
            #expect(!appDelegate.moveSurfaceIntoDock(
                sourceTabId: sourceTabId.uuid,
                destinationDock: dock,
                destination: .insert(targetPane: rootPane, targetIndex: nil)
            ))
            #expect(workspace.panels[simulator.id] === simulator)
            #expect(dock.panel(for: sourceTabId) == nil)
        }
    }

    @Test("Move Dock surface to workspace reconciles destination")
    @MainActor
    func moveDockSurfaceToWorkspaceReconcilesDestination() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let sourceWorkspace = try #require(manager.tabs.first)
            let destinationWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let dock = sourceWorkspace.requiredDockSplitForTesting
            let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
            dock.setVisibleInUI(true)
            let dockPanelId = try #require(dock.newSurface(kind: .terminal, inPane: rootPane, focus: true))
            dock.clearDockPortalReconcile()
            dock.dockPortalReconcileState.scheduledRequestCount = 0

            let moved = appDelegate.moveDockSurfaceToWorkspace(
                sourceDock: dock,
                panelId: dockPanelId,
                toWorkspace: destinationWorkspace.id,
                targetPane: nil,
                targetIndex: nil,
                splitTarget: nil,
                focus: true,
                focusWindow: false
            )

            #expect(moved)
            #expect(destinationWorkspace.panels[dockPanelId] != nil)
            #expect(dock.dockPortalReconcileState.scheduledRequestCount > 0)
        }
    }

    @MainActor
    private static func portalWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private static func closePortalWindow(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        window.orderOut(nil)
    }

}
