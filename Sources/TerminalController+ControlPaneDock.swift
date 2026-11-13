import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Creates a pane in the routed window's right-sidebar Dock instead of the
    /// main area, splitting the Dock's own Bonsplit tree.
    func dockPaneCreate(
        routing: ControlRoutingSelectors,
        tabManager: TabManager,
        panelType: PanelType,
        orientation: SplitOrientation,
        insertFirst: Bool,
        initialDividerPosition: CGFloat?,
        inputs: ControlPaneCreateInputs
    ) -> ControlPaneCreateResolution {
        if let invalid = validateDockPaneCreateRouting(routing: routing, tabManager: tabManager, panelType: panelType) {
            return invalid
        }
        guard let dockOwnerId = windowDockOwnerIdForCreateRouting(routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard let dock = AppDelegate.shared?.windowDockForRegisteredOwner(dockOwnerId) else {
            return .workspaceNotFound
        }
        // An explicit source surface must live in the Dock tree; do not silently
        // fall back to another Dock pane (mirrors the workspace `.noSourceSurface`).
        if let requestedSource = inputs.requestedSourceSurfaceID, !dock.containsPanel(requestedSource) {
            return .noSourceSurface
        }
        let focus = v2FocusAllowed(requested: inputs.requestedFocus)
        let kind: DockSurfaceKind = .terminal
        if focus {
            // Creation is authoritative; revealing its secondary focus request
            // is best-effort when the Dock host is still mounting.
            _ = focusAndRevealWindowDock(for: dock, fallback: tabManager)
        }
        let newPanelId = dock.newSplit(
            kind: kind,
            orientation: orientation,
            insertFirst: insertFirst,
            sourcePanelId: inputs.requestedSourceSurfaceID,
            command: inputs.initialCommand,
            workingDirectory: inputs.workingDirectory,
            environment: inputs.startupEnvironment,
            tmuxStartCommand: inputs.tmuxStartCommand,
            initialInput: inputs.initialInput,
            initialDividerPosition: initialDividerPosition,
            focus: false
        )
        guard let newPanelId else {
            return .createFailed
        }
        if focus {
            dock.focusPanelFromDockInteraction(newPanelId, window: nil)
        }
        let paneUUID = dock.paneId(forPanelId: newPanelId)?.id
        return .createdDock(
            windowID: dock.workspaceId,
            workspaceID: dock.workspaceId,
            dockPaneID: paneUUID,
            dockSurfaceID: newPanelId,
            typeRawValue: panelType.rawValue
        )
    }
}
