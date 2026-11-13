import Foundation

extension TabManager {
    /// A snapshot written by an older build for an ssh/remote workspace. This
    /// build has no remote workspaces, so such a snapshot is never restored.
    static func isLegacyRemoteSessionRestoreWorkspace(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        snapshot.remote != nil
    }

    /// Reconciles task-create provenance only when the caller owns a cache.
    /// A nil cache intentionally leaves unrelated snapshot restores isolated.
    static func recordRestoredTaskCreateProvenance(
        for workspace: Workspace,
        in cache: TerminalController.WorkspaceCreateIdempotencyCache?
    ) {
        guard let operationID = workspace.taskCreateOperationID, let cache else { return }
        cache.record(operationID: operationID, workspaceID: workspace.id)
    }
}
