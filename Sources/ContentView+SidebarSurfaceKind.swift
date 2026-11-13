import CmuxExtensionKit

extension VerticalTabsSidebar {
    func cmuxSidebarSurfaceKind(for panelType: PanelType) -> CmuxSidebarSurfaceKind {
        switch panelType {
        case .terminal:
            return .terminal
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .customSidebar, .simulator, .workspaceTodo, .notifications:
            return .unknown
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        }
    }
}
