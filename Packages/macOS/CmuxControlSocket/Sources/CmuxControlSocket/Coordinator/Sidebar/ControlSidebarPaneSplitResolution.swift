public import Foundation

/// The outcome of the v1 `new_pane` split.
public enum ControlSidebarPaneSplitResolution: Sendable, Equatable {
    /// The pane was created.
    case created(UUID)
    /// The split was routed to the remote tmux mirror backing the workspace;
    /// the pane arrives asynchronously via `%layout-change` (no local id yet).
    case routedToRemote
    /// Creation failed.
    case failed
}
