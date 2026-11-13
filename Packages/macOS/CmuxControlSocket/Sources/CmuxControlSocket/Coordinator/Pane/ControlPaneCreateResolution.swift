public import Foundation

/// The outcome of `pane.create`, preserving every distinct branch of the legacy
/// `v2PaneCreate` body and the created-pane identity it echoes back.
///
/// The coordinator parses the primitive inputs (direction string, type string,
/// url, working directory, commands, environment, initial divider) and shapes
/// the final `JSONValue`; the seam runs all the app-coupled work (panel-type
/// resolution, the split creation) and returns this.
public enum ControlPaneCreateResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The `direction` was missing or not one of `left|right|up|down` (legacy
    /// `invalid_params` / "Missing or invalid direction (left|right|up|down)",
    /// `data: nil`).
    case invalidDirection
    /// The `initial_divider_position` was present but non-numeric (legacy
    /// `invalid_params` / "initial_divider_position must be numeric", `data:
    /// nil`).
    case invalidDividerPosition
    /// The `placement` was present but not one of `workspace|dock`
    /// (`invalid_params`, `data: {"placement": rawValue}`). Carries the raw value.
    case invalidPlacement(rawValue: String)
    /// The `type` resolved to `agent-session`, which `pane.create` rejects
    /// (legacy `invalid_params` / "agent-session is only supported by
    /// surface.create", `data: {"type": rawValue}`). Carries the raw type value.
    case agentSessionRejected(typeRawValue: String)
    /// Dock placement only supports terminal panes. Carries the raw
    /// type and the localized message produced by the app seam.
    case dockUnsupportedType(typeRawValue: String, message: String)
    /// Dock placement was requested while the Dock sidebar mode is unavailable.
    /// Carries the localized message produced by the app seam.
    case dockUnavailable(message: String)
    /// Dock placement was requested with selectors that name different window
    /// Docks. Carries the localized message produced by the app seam.
    case dockConflictingRoutingSelectors(message: String)
    /// A TabManager resolved but no workspace did (legacy `not_found` /
    /// "Workspace not found", `data: nil`).
    case workspaceNotFound
    /// No source surface to split from (legacy `not_found` / "No source surface
    /// to split", `data: nil`).
    case noSourceSurface
    /// The split creation failed (legacy `internal_error` / "Failed to create
    /// pane", `data: nil`).
    case createFailed
    /// The split was routed to the terminal's remote owner; the pane arrives
    /// asynchronously.
    case routedToRemote(windowID: UUID?, workspaceID: UUID, typeRawValue: String)
    /// The pane was created in the right-sidebar Dock. Dock handles are scoped to
    /// the Dock container and are not ordinary workspace surface/pane ids.
    case createdDock(
        windowID: UUID?,
        workspaceID: UUID,
        dockPaneID: UUID?,
        dockSurfaceID: UUID,
        typeRawValue: String
    )
    /// The pane was created. Carries the echoed identity (window and pane may be
    /// absent; workspace and the new surface are present) and the resolved panel
    /// type's raw value.
    case created(
        windowID: UUID?,
        workspaceID: UUID,
        paneID: UUID?,
        surfaceID: UUID,
        typeRawValue: String
    )
}
