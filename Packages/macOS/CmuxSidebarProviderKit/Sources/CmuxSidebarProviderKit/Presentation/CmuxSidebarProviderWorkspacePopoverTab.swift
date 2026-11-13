import Foundation

/// Tabs available when CMUX opens a workspace popover for a provider row.
public enum CmuxSidebarProviderWorkspacePopoverTab: String, Codable, CaseIterable, Equatable, Sendable {
    /// Notes tab.
    case notes
    /// Pull request details tab.
    case pullRequest

    /// Creates a tab, falling back to `.notes` for raw values this version no
    /// longer knows (for example the removed browser tab).
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CmuxSidebarProviderWorkspacePopoverTab(rawValue: rawValue) ?? .notes
    }
}
