import Foundation

/// A provider owns the resources of one machine and knows how to put one on screen.
/// Providers push resource changes into the catalog (`catalog.replaceResources`) and the
/// catalog asks them to materialize a projection. They never track projections themselves.
@MainActor
protocol SurfaceProvider: AnyObject {
    var machine: SurfaceMachineID { get }
    var info: SurfaceMachineInfo { get }
    /// Re-sync from the source of truth (local panels).
    func refresh() async
    /// Re-sync this provider, optionally bypassing provider-side caches.
    func refresh(force: Bool) async
    /// Create the pane that shows `resource` at `destination` and return the panel it created
    /// (or reused). The catalog records the projection.
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection
    /// Create a new terminal on this machine (the local provider spawns a shell) and
    /// return its resource.
    func createTerminal(command: [String]?, cwd: String?, name: String?) async throws -> SurfaceResource
    /// Called when a pane projecting one of this provider's resources goes away. The
    /// local provider drops the resource.
    func projectionDidEnd(_ projection: SurfaceProjection)
    /// Close a projection's pane: a materialization that lost a race with an existing
    /// projection. The default implementation handles providers that use the shared pane
    /// factory; providers may also clear provider-specific bookkeeping. Return true when
    /// the provider preserved the projection, as the local provider does for a moved pane.
    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool
}

extension SurfaceProvider {
    func refresh(force: Bool) async {
        await refresh()
    }

    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        return false
    }
}
