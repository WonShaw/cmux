import AppKit
import CmuxCanvas
import CmuxPanes
import CmuxSettings

extension AppDelegate {
    func performToggleSplitZoomShortcut(tabManager routedManager: TabManager?) {
        if let workspace = routedManager?.selectedWorkspace, workspace.layoutMode == .canvas {
            _ = CanvasActionExecutor(workspace: workspace).perform(.toggleOverview)
        } else {
            _ = routedManager?.toggleFocusedSplitZoom()
        }
    }

    func performBrowserOrTextPreviewZoomShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        let focusContext = shortcutEventFocusContext(event)
        if focusContext.filePreviewTextEditorFocused {
            let targetTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            switch action {
            case .browserZoomIn:
                return targetTabs?.zoomInFocusedTextFilePreview() ?? false
            case .browserZoomOut:
                return targetTabs?.zoomOutFocusedTextFilePreview() ?? false
            case .browserZoomReset:
                return targetTabs?.resetZoomFocusedTextFilePreview() ?? false
            default:
                return false
            }
        }

        return false
    }
}

extension SplitDirection {
    var canvasDirection: CanvasDirection {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }
}
