public import Foundation

/// The outcome of `surface.create`, preserving the legacy body's distinct failures
/// and the created identity.
///
/// The coordinator signals `unavailable`; the app maps the type token, validates
/// the agent-session provider/renderer (when the type is `agent-session`),
/// resolves the workspace and pane, creates the surface, and returns this
/// resolution.
public enum ControlSurfaceCreateResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// The agent-session `provider` token was invalid (legacy `invalid_params` /
    /// "Invalid provider (codex|claude|opencode)", `data: {"provider": …}`).
    case invalidProvider(rawValue: String)
    /// The agent-session `renderer` token was invalid (legacy `invalid_params` /
    /// "Invalid renderer (react|solid)", `data: {"renderer": …}`).
    case invalidRenderer(rawValue: String)
    /// The `placement` was present but not one of `workspace|dock`
    /// (`invalid_params`, `data: {"placement": rawValue}`). Carries the raw value.
    case invalidPlacement(rawValue: String)
    /// The request targeted the Dock with a surface type the Dock cannot host
    /// (`invalid_params`, app-bundle-resolved message, `data: {"type": rawValue}`).
    case dockUnsupportedType(typeRawValue: String, message: String)
    /// Dock placement was requested while the Dock sidebar mode is unavailable
    /// (`invalid_params`, app-bundle-resolved message, `data: {"placement": "dock"}`).
    case dockUnavailable(message: String)
    /// Dock placement was requested with selectors that name different window
    /// Docks (`invalid_params`, app-bundle-resolved message).
    case dockConflictingRoutingSelectors(message: String)
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// The requested/focused pane did not resolve (legacy `not_found` / "Pane not
    /// found").
    case paneNotFound
    /// The surface creation failed (legacy `internal_error` / "Failed to create
    /// surface").
    case createFailed
    /// The create was routed to the terminal's remote owner; the tab arrives
    /// asynchronously.
    case routedToRemote(windowID: UUID?, workspaceID: UUID, typeRawValue: String)
    /// The surface was created in the right-sidebar Dock. Dock handles are scoped
    /// to the Dock container and are not ordinary workspace surface/pane ids.
    case createdDock(
        windowID: UUID?,
        workspaceID: UUID,
        dockPaneID: UUID,
        dockSurfaceID: UUID,
        typeRawValue: String
    )
    /// The surface was created. Carries the echoed identity and the panel type.
    case created(
        windowID: UUID?,
        workspaceID: UUID,
        paneID: UUID,
        surfaceID: UUID,
        typeRawValue: String
    )
}
