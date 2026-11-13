import AppKit
import Bonsplit
import CmuxControlSocket
import CmuxTerminal
import Foundation
import CmuxWorkspaces

/// The surface-domain reporting (`report_tty` / `report_pwd` /
/// `report_shell_state` / `ports_kick`) witnesses, plus the token parsers.
/// Split out of `TerminalController+ControlSurfaceContext` to keep the
/// conformance readable; see that file's doc comment for the overview.
extension TerminalController {
    // MARK: - token parsers

    nonisolated func controlSurfaceParseShellActivityState(_ rawState: String) -> String? {
        Self.parseReportedShellActivityState(rawState)?.rawValue
    }

    nonisolated func controlSurfaceParsePortScanKickReason(_ rawReason: String) -> String? {
        Self.parsePortScanKickReason(rawReason)
    }

    // MARK: - report_tty

    func controlSurfaceReportTTY(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        ttyName: String
    ) -> ControlSurfaceReportTTYResolution {
        guard let tab = controlTabForSidebarMutation(id: workspaceID) else {
            return .workspaceNotFound
        }
        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
        let surfaceId = controlResolveReportedSurfaceId(
            in: tab,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIds
        )
        guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
            return .surfaceNotFound
        }

        tab.registerReportedSurfaceTTYName(ttyName, panelId: surfaceId)
        PortScanner.shared.registerTTY(workspaceId: workspaceID, panelId: surfaceId, ttyName: ttyName)
        return .recorded(surfaceID: surfaceId)
    }

    // MARK: - report_pwd

    func controlSurfaceReportPWD(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        path: String
    ) -> ControlSurfaceReportPWDResolution {
        guard let tab = controlTabForSidebarMutation(id: workspaceID) else {
            return .workspaceNotFound
        }
        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

        let surfaceId = controlResolveReportedSurfaceId(
            in: tab,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIds
        )
        guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
            return .surfaceNotFound
        }

        if let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) ?? tabManager {
            tabManager.updateReportedSurfaceDirectory(tabId: workspaceID, surfaceId: surfaceId, directory: path)
        } else {
            _ = tab.updatePanelDirectory(panelId: surfaceId, directory: path)
        }
        return .recorded(surfaceID: surfaceId)
    }

    // MARK: - report_shell_state

    func controlSurfaceReportShellState(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        terminalLifecycleID: UUID?,
        stateRawValue: String
    ) -> ControlSurfaceReportShellStateResolution {
        guard let state = PanelShellActivityState(rawValue: stateRawValue) else {
            // Unreachable: the coordinator only forwards a value the app produced.
            return .pending
        }
        if let requestedSurfaceID {
            let shouldPublish = controlScheduleScopedShellActivityState(
                scope: ControlSidebarPanelScope(
                    workspaceID: workspaceID,
                    panelID: requestedSurfaceID,
                    terminalLifecycleID: terminalLifecycleID
                ),
                stateRawValue: state.rawValue
            )
            return .explicit(surfaceID: requestedSurfaceID, published: shouldPublish)
        }

        let resolvedWorkspaceID: UUID
        if let terminalLifecycleID {
            guard let reportingSurface = GhosttyApp.terminalSurfaceRegistry
                      .surface(
                          terminalLifecycleID: terminalLifecycleID
                      ) as? TerminalSurface else {
                return .pending
            }
            // The reporting surface's live binding is the owner authority;
            // its lifecycle token must not be compared with the inferred
            // target's lifecycle.
            resolvedWorkspaceID = reportingSurface.tabId
        } else {
            resolvedWorkspaceID = workspaceID
        }

        guard let tab = controlTabForSidebarMutation(
                  id: resolvedWorkspaceID
              ) else {
            return .pending
        }
        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
        let surfaceId = controlResolveReportedSurfaceId(
            in: tab,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIds
        )
        guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
            return .pending
        }
        controlApplyScopedShellActivityState(
            workspaceID: tab.id,
            surfaceID: surfaceId,
            terminalLifecycleID: nil,
            state: state
        )
        return .pending
    }

    func controlSurfaceInvalidTerminalLifecycleIDError() -> String {
        String(
            localized: "controlSocket.surface.reportShellState.invalidTerminalLifecycleID",
            defaultValue: "Terminal session is out of date; restart the shell and try again"
        )
    }

    // MARK: - ports_kick

    func controlSurfacePortsKick(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        reasonRawValue: String
    ) -> ControlSurfacePortsKickResolution {
        guard let tab = controlTabForSidebarMutation(id: workspaceID) else {
            return .workspaceNotFound
        }
        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

        let surfaceId = controlResolveReportedSurfaceId(
            in: tab,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIds
        )
        guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
            return .surfaceNotFound
        }

        PortScanner.shared.kick(workspaceId: workspaceID, panelId: surfaceId)
        return .kicked(surfaceID: surfaceId)
    }

    // MARK: - shared report helpers (twins of file-private members)

    /// The byte-faithful twin of the file-private `tabForSidebarMutation(id:)`:
    /// the controller's own TabManager first, then any window's TabManager.
    func controlTabForSidebarMutation(id: UUID) -> Workspace? {
        if let tab = tabManager?.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let otherManager = AppDelegate.shared?.tabManagerFor(tabId: id) {
            return otherManager.tabs.first(where: { $0.id == id })
        }
        return nil
    }

    /// The byte-faithful twin of the file-private `resolveReportedSurfaceId`.
    func controlResolveReportedSurfaceId(
        in workspace: Workspace,
        requestedSurfaceId: UUID?,
        validSurfaceIds: Set<UUID>
    ) -> UUID? {
        if let requestedSurfaceId {
            guard validSurfaceIds.contains(requestedSurfaceId) else { return nil }
            return requestedSurfaceId
        }
        if let focusedSurfaceId = workspace.focusedPanelId,
           validSurfaceIds.contains(focusedSurfaceId) {
            return focusedSurfaceId
        }
        return nil
    }
}
