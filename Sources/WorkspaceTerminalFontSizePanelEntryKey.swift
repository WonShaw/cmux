import Foundation

extension WorkspaceTerminalFontSizePanelDiscovery {
    enum EntryKey: Hashable {
        case workspace(UUID)
        case workspaceDock(UUID)
        case windowDock(UUID)
    }
}
