import Foundation

/// Resolves a live surface to the stable workspace panel that owns its layout.
///
/// Ordinary surfaces use the same identity for both fields.
@MainActor
struct WorkspaceSurfaceOwnershipTarget {
    let surfaceID: UUID
    let containerPanelID: UUID
    let panel: any Panel
}
