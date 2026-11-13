import Bonsplit
import CmuxWorkspaces
import Foundation

@MainActor
extension Workspace {
    typealias ControlSurfaceProjection = (
        surfaceID: UUID,
        paneID: UUID?,
        panel: any Panel
    )

    /// Resolves a control-plane surface identity to its tab mutation owner and
    /// exposed pane.
    func controlTabTarget(for surfaceID: UUID) -> (panelID: UUID, paneID: UUID?)? {
        guard panels[surfaceID] != nil else { return nil }
        return (surfaceID, paneId(forPanelId: surfaceID)?.id)
    }

    /// Every terminal in this build runs on this Mac, so word-path fallback
    /// may always resolve against the local filesystem.
    func canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: UUID) -> Bool {
        true
    }

    /// Canonicalizes an explicit control-plane terminal target.
    func controlSurfaceTarget(for surfaceID: UUID) -> ControlSurfaceProjection? {
        if let panel = panels[surfaceID] {
            return (surfaceID, paneId(forPanelId: surfaceID)?.id, panel)
        }
        guard let dock = _dockSplit,
              let panel = dock.panels[surfaceID] else {
            return nil
        }
        return (surfaceID, dock.paneId(forPanelId: surfaceID)?.id, panel)
    }

    func controlTerminalTarget(for surfaceID: UUID) -> (surfaceID: UUID, panel: TerminalPanel)? {
        guard let target = controlSurfaceTarget(for: surfaceID),
              let panel = target.panel as? TerminalPanel else { return nil }
        return (target.surfaceID, panel)
    }

    func controlTerminalPanel(for surfaceID: UUID) -> TerminalPanel? {
        controlTerminalTarget(for: surfaceID)?.panel
    }

    /// Expands one workspace-owned panel into the live terminals it represents.
    func terminalPanels(projectedFromPanelID panelID: UUID) -> [TerminalPanel] {
        (panels[panelID] as? TerminalPanel).map { [$0] } ?? []
    }

    /// Resolves a user input destination from a workspace-owned panel or an
    /// explicit surface identity.
    func terminalInputTarget(
        forPanelID panelID: UUID
    ) -> (surfaceID: UUID, panel: TerminalPanel)? {
        let projection: ControlSurfaceProjection?
        if panels[panelID] != nil {
            projection = controlSurfaceProjection(forContainerPanelID: panelID)
        } else {
            projection = controlSurfaceTarget(for: panelID)
        }
        guard let projection,
              let panel = projection.panel as? TerminalPanel else {
            return nil
        }
        return (projection.surfaceID, panel)
    }

    /// Resolves a live surface to the stable workspace panel that owns it.
    func surfaceOwnershipTarget(
        for surfaceOrPanelID: UUID
    ) -> WorkspaceSurfaceOwnershipTarget? {
        if let panel = panels[surfaceOrPanelID] {
            guard surfaceIdFromPanelId(surfaceOrPanelID) != nil else { return nil }
            return WorkspaceSurfaceOwnershipTarget(
                surfaceID: surfaceOrPanelID,
                containerPanelID: surfaceOrPanelID,
                panel: panel
            )
        }
        guard let panelID = panelIdFromSurfaceId(TabID(uuid: surfaceOrPanelID)),
              let panel = panels[panelID] else { return nil }
        return WorkspaceSurfaceOwnershipTarget(
            surfaceID: panelID,
            containerPanelID: panelID,
            panel: panel
        )
    }

    /// Projects a workspace-owned panel into the identity exposed by the
    /// control plane.
    func controlSurfaceProjection(
        forContainerPanelID containerPanelID: UUID
    ) -> ControlSurfaceProjection? {
        guard let panel = panels[containerPanelID] else { return nil }
        return (containerPanelID, paneId(forPanelId: containerPanelID)?.id, panel)
    }

    /// The terminal that currently owns keyboard input for this workspace.
    func focusedTerminalInputTarget() -> (surfaceID: UUID, panel: TerminalPanel)? {
        guard let focusedPanelId else { return nil }
        return terminalInputTarget(forPanelID: focusedPanelId)
    }

    /// Whether `surfaceID` is the workspace's canonical keyboard-input target.
    func isFocusedTerminalInputSurface(_ surfaceID: UUID) -> Bool {
        focusedTerminalInputTarget()?.surfaceID == surfaceID
    }

    /// Resolves the selected terminal target. A requested pane projects that
    /// pane's selected surface.
    func controlDefaultTerminalTarget(
        paneID requestedPaneID: UUID?
    ) -> (surfaceID: UUID, panel: TerminalPanel)? {
        if let requestedPaneID {
            if let paneID = bonsplitController.allPaneIds.first(where: { $0.id == requestedPaneID }),
               let tab = bonsplitController.selectedTab(inPane: paneID),
               let panelID = panelIdFromSurfaceId(tab.id),
               let panel = terminalPanel(for: panelID) {
                return (panelID, panel)
            }
            return nil
        }

        return focusedTerminalInputTarget()
    }

    /// Resolves explicit-or-default control-plane surface targeting.
    /// Returns nil when an explicit pane cannot resolve or nothing is focused.
    func controlRequestedSurfaceTarget(
        explicitSurfaceID: UUID?,
        routedPaneID: UUID?
    ) -> (requestedSurfaceID: UUID, target: ControlSurfaceProjection?)? {
        if let explicitSurfaceID {
            return (explicitSurfaceID, controlSurfaceTarget(for: explicitSurfaceID))
        }
        if let routedPaneID {
            guard let paneID = bonsplitController.allPaneIds.first(where: {
                $0.id == routedPaneID
            }),
            let selectedTab = bonsplitController.selectedTab(inPane: paneID),
            let panelID = panelIdFromSurfaceId(selectedTab.id) else {
                return nil
            }
            return (panelID, controlSurfaceTarget(for: panelID))
        }
        guard let focusedPanelId else { return nil }
        return (focusedPanelId, controlSurfaceProjection(forContainerPanelID: focusedPanelId))
    }
}
