import Foundation
import CmuxGit
import CmuxSidebarGit
import CmuxSidebar

// MARK: - SidebarGitHosting conformance
//
// TabManager is the window-side host of the extracted CmuxSidebarGit
// services: snapshot reads of workspace/panel state, synchronous projection
// writes of branch state onto Workspace, and the environment
// toggles (settings + mobile-host activity) the schedulers honor. Every
// method forwards to the same Workspace/defaults accessors the legacy
// in-class subsystem used, so state transitions stay byte-identical.

extension TabManager: SidebarGitHosting {
    // MARK: Workspace/panel reads

    func orderedWorkspaceIds() -> [UUID] {
        tabs.map(\.id)
    }

    func workspaceExists(_ workspaceId: UUID) -> Bool {
        tabs.contains(where: { $0.id == workspaceId })
    }

    func isRemoteWorkspace(_ workspaceId: UUID) -> Bool? {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return nil }
        return workspace.usesRemoteDirectoryProvenance
    }

    func panelIds(in workspaceId: UUID) -> [UUID] {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return [] }
        return Array(workspace.panels.keys)
    }

    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool {
        tabs.first(where: { $0.id == workspaceId })?.panels[panelId] != nil
    }

    func hasTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        tabs.first(where: { $0.id == workspaceId })?.terminalPanel(for: panelId) != nil
    }

    func isRemoteTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        // This build has no remote (ssh or cloud) terminal surfaces.
        false
    }

    func gitProbeDirectory(workspaceId: UUID, panelId: UUID) -> String? {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return nil }
        return gitProbeDirectory(for: workspace, panelId: panelId)
    }

    func hasTrustedRemotePanelDirectory(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return !workspace.allowsLocalDirectoryFallback(panelId: panelId) &&
            workspace.reportedPanelDirectory(panelId: panelId) != nil
    }

    func panelGitBranch(workspaceId: UUID, panelId: UUID) -> SidebarPanelGitBranch? {
        guard let state = tabs.first(where: { $0.id == workspaceId })?.panelGitBranches[panelId] else {
            return nil
        }
        return SidebarPanelGitBranch(branch: state.branch, isDirty: state.isDirty)
    }

    func panelGitBranchPanelIds(in workspaceId: UUID) -> Set<UUID> {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return [] }
        return Set(workspace.panelGitBranches.keys)
    }

    func focusedPanelId(in workspaceId: UUID) -> UUID? {
        tabs.first(where: { $0.id == workspaceId })?.focusedPanelId
    }

    func hasWorkspaceLevelGitSignal(_ workspaceId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.gitBranch != nil
    }

    // MARK: Projection writes

    @discardableResult
    func updatePanelDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.updatePanelDirectory(panelId: panelId, directory: directory, displayLabel: displayLabel)
    }

    func updateRemoteSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String, displayLabel: String? = nil) {
        sidebarGitMetadataService.updateRemoteSurfaceDirectory(
            workspaceId: tabId,
            panelId: surfaceId,
            directory: directory,
            displayLabel: displayLabel
        )
    }

    func updateReportedSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String, displayLabel: String? = nil) {
        if let workspace = tabs.first(where: { $0.id == tabId }),
           !workspace.allowsLocalDirectoryFallback(panelId: surfaceId) {
            updateRemoteSurfaceDirectory(tabId: tabId, surfaceId: surfaceId, directory: directory, displayLabel: displayLabel)
        } else {
            updateSurfaceDirectory(tabId: tabId, surfaceId: surfaceId, directory: directory, displayLabel: displayLabel)
        }
    }

    @discardableResult
    func updateRemotePanelDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.updateRemotePanelDirectory(panelId: panelId, directory: directory, displayLabel: displayLabel)
    }

    func updatePanelGitBranch(workspaceId: UUID, panelId: UUID, branch: String, isDirty: Bool) {
        tabs.first(where: { $0.id == workspaceId })?
            .updatePanelGitBranch(panelId: panelId, branch: branch, isDirty: isDirty)
    }

    func clearPanelGitBranch(workspaceId: UUID, panelId: UUID) {
        tabs.first(where: { $0.id == workspaceId })?.clearPanelGitBranch(panelId: panelId)
    }

    func clearAllSidebarGitMetadata() {
        for workspace in tabs {
            workspace.clearSidebarGitMetadata()
        }
    }

    // MARK: Environment

    var gitMetadataActivity: SidebarGitMetadataActivity {
        SidebarWorkspaceDetailDefaults.gitMetadataActivity(defaults: .standard)
    }

    func mobileHostHasRecentActivity(within interval: TimeInterval) -> Bool {
        false
    }

    func mobileHostQuietDelay(for interval: TimeInterval) -> TimeInterval {
        0
    }
}
