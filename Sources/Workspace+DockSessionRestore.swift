import AppKit
import Bonsplit
import Foundation

extension Workspace {
    /// Rebuilds a transferred Dock panel through its original workspace, then detaches the
    /// live panel so the Dock can adopt the same remote transport and agent lifecycle state.
    func detachedSurfaceForDockSessionRestore(
        _ snapshot: SessionPanelSnapshot,
        snapshotWorkspaceId: UUID,
        excludingStableIdentities: Set<UUID>,
        restorableAgentIndex: RestorableAgentSessionIndex?
    ) -> DetachedSurfaceTransfer? {
        guard let paneId = bonsplitController.allPaneIds.first else { return nil }
        sessionRestoreIdentityExclusions.beginRestore(excluding: excludingStableIdentities)
        defer { sessionRestoreIdentityExclusions.endRestore() }
        guard let panelId = createPanel(
            from: snapshot,
            inPane: paneId,
            snapshotWorkspaceId: snapshotWorkspaceId,
            restorableAgentIndex: restorableAgentIndex
        ) else {
            return nil
        }
        guard let detached = detachSurface(panelId: panelId) else {
            terminalStartupRestoreCoordinator.cancelPendingRestore(panelID: panelId)
            _ = closePanel(panelId, force: true)
            return nil
        }
        return detached
    }
}

// MARK: - Dock panel lookup / close
// (moved here from the removed Workspace+DockBrowserLookup.swift; these helpers
// are not browser-specific)

extension Workspace {
    func containsDockPane(_ paneId: UUID) -> Bool {
        _dockSplit?.containsPane(paneId) ?? false
    }

    func containsDockPanel(_ panelId: UUID) -> Bool {
        _dockSplit?.containsPanel(panelId) ?? false
    }

    var focusedDockPanelId: UUID? {
        _dockSplit?.focusedPanelId
    }

    @discardableResult
    func closeDockPanel(
        _ panelId: UUID,
        force: Bool = false,
        recordsHistory: Bool = true
    ) -> Bool {
        _dockSplit?.closePanel(
            panelId,
            force: force,
            recordsHistory: recordsHistory
        ) ?? false
    }

    @discardableResult
    func closeDockPanelAndClearNotifications(
        _ panelId: UUID,
        force: Bool = false,
        recordsHistory: Bool = true
    ) -> Bool {
        guard closeDockPanel(
            panelId,
            force: force,
            recordsHistory: recordsHistory
        ) else {
            return false
        }
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        return true
    }
}

extension AppDelegate {
    @discardableResult
    func closeFocusedDockPanelForCommand(preferredWindow: NSWindow?) -> Bool {
        guard let dock = focusedDockStoreForShortcut(
            action: .closeTab,
            preferredWindow: preferredWindow
        ) else {
            return false
        }
        guard let panelId = dock.focusedPanelId else { return true }
        if dock.closePanel(panelId, force: false) {
            notificationStore?.clearNotifications(
                forTabId: dock.workspaceId,
                surfaceId: panelId
            )
        }
        return true
    }
}

extension DockSplitStore {
    @discardableResult
    func closePanel(
        _ panelId: UUID,
        force: Bool = false,
        recordsHistory: Bool = true
    ) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId) else { return false }
        if recordsHistory, !force {
            markDockCloseHistoryEligible(panelId: panelId)
        }
        if force { forceCloseDockTabIds.insert(tabId) }
        let closed = bonsplitController.closeTab(tabId)
        if force && !closed { forceCloseDockTabIds.remove(tabId) }
        if !closed,
           !pendingCloseConfirmDockTabIds.contains(tabId) {
            discardDockClosedPanelHistory(tabId: tabId)
        }
        return closed
    }
}
