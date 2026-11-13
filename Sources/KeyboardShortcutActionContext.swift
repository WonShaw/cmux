import CmuxCommandPalette
import CmuxSettings

extension KeyboardShortcutSettings.Action {
    var allowsBareFirstStroke: Bool {
        switch self {
        case .diffViewerScrollDown,
             .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown,
             .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs,
             .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop,
             .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias:
            return true
        default:
            return false
        }
    }

    var isBrowserContentShortcut: Bool {
        switch self {
        case .diffViewerScrollDown,
             .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown,
             .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs,
             .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop:
            return true
        default:
            return false
        }
    }

    enum ShortcutContext: Equatable {
        case application
        case commandPaletteVisible
        case outsideRightSidebar
        case viewerPanel
        case filePreviewTextEditor
        case markdownPanel
        case simulatorPanel
        case rightSidebarFocus
        case canvasLayout
        case canvasLayoutOutsideFocusedContent

        var isAlwaysAvailable: Bool { self == .application }

        var forwardsMenuEquivalentToFocusedTerminal: Bool {
            switch self {
            case .filePreviewTextEditor:
                return true
            default:
                return false
            }
        }

        func isAvailable(
            focusedMarkdownPanel: Bool,
            focusedSimulatorPanel: Bool = false,
            focusedFilePreviewTextEditor: Bool = false,
            rightSidebarFocused: Bool,
            workspaceCanvasLayout: Bool = false
        ) -> Bool {
            switch self {
            case .application: return true
            case .commandPaletteVisible: return false
            case .outsideRightSidebar: return !rightSidebarFocused
            case .viewerPanel: return focusedMarkdownPanel
            case .filePreviewTextEditor: return focusedFilePreviewTextEditor
            case .markdownPanel: return focusedMarkdownPanel
            case .simulatorPanel: return focusedSimulatorPanel
            case .rightSidebarFocus: return rightSidebarFocused
            case .canvasLayout: return workspaceCanvasLayout
            case .canvasLayoutOutsideFocusedContent:
                return workspaceCanvasLayout
                    && !focusedMarkdownPanel
                    && !focusedSimulatorPanel
                    && !focusedFilePreviewTextEditor
            }
        }

        func isAvailable(_ context: ShortcutEventFocusContext) -> Bool {
            return isAvailable(
                focusedMarkdownPanel: context.markdownPanel != nil,
                focusedSimulatorPanel: context.shortcutContext.bool(ShortcutContextKnownKey.simulatorFocus.rawValue),
                focusedFilePreviewTextEditor: context.filePreviewTextEditorFocused,
                rightSidebarFocused: context.rightSidebarFocused,
                workspaceCanvasLayout: context.shortcutContext.bool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue)
            )
        }

        func isAvailable(commandPaletteContext context: CommandPaletteContextSnapshot) -> Bool {
            if self == .commandPaletteVisible {
                return true
            }
            return isAvailable(
                focusedMarkdownPanel: context.bool(CommandPaletteContextKeys.panelIsMarkdown),
                focusedSimulatorPanel: context.bool(CommandPaletteContextKeys.panelIsSimulator),
                focusedFilePreviewTextEditor: context.bool(CommandPaletteContextKeys.panelIsFilePreviewTextEditor),
                rightSidebarFocused: false,
                workspaceCanvasLayout: context.bool(CommandPaletteContextKeys.workspaceCanvasLayout)
            )
        }

        var defaultWhenClause: ShortcutWhenClause {
            switch self {
            case .application: return .always
            case .commandPaletteVisible: return .key(ShortcutContextKnownKey.commandPaletteVisible.rawValue)
            case .outsideRightSidebar: return .not(.atom(.sidebarFocus))
            case .viewerPanel: return .atom(.markdownFocus)
            case .filePreviewTextEditor: return .atom(.filePreviewTextEditorFocus)
            case .markdownPanel: return .atom(.markdownFocus)
            case .simulatorPanel: return .atom(.simulatorFocus)
            case .rightSidebarFocus: return .atom(.sidebarFocus)
            case .canvasLayout: return .key(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue)
            case .canvasLayoutOutsideFocusedContent:
                return .and(
                    .key(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue),
                    .and(
                        .not(.atom(.markdownFocus)),
                        .and(
                            .not(.atom(.filePreviewTextEditorFocus)),
                            .not(.atom(.simulatorFocus))
                        )
                    )
                )
            }
        }

        func overlaps(_ other: ShortcutContext) -> Bool {
            if self == .application || other == .application || self == other {
                return true
            }
            if (self == .markdownPanel && other == .outsideRightSidebar)
                || (self == .outsideRightSidebar && other == .markdownPanel) {
                return true
            }
            if self == .viewerPanel || other == .viewerPanel {
                let paired = self == .viewerPanel ? other : self
                switch paired {
                case .markdownPanel, .outsideRightSidebar, .canvasLayout:
                    return true
                default:
                    return false
                }
            }
            if self == .filePreviewTextEditor || other == .filePreviewTextEditor {
                let paired = self == .filePreviewTextEditor ? other : self
                switch paired {
                case .outsideRightSidebar, .canvasLayout:
                    return true
                default:
                    return false
                }
            }
            if self == .canvasLayout || other == .canvasLayout {
                return true
            }
            if self == .canvasLayoutOutsideFocusedContent || other == .canvasLayoutOutsideFocusedContent {
                return self != .filePreviewTextEditor
                    && other != .filePreviewTextEditor
                    && self != .markdownPanel
                    && other != .markdownPanel
                    && self != .viewerPanel
                    && other != .viewerPanel
            }
            if self == .simulatorPanel || other == .simulatorPanel {
                let paired = self == .simulatorPanel ? other : self
                return paired == .outsideRightSidebar || paired == .canvasLayout
            }
            return false
        }
    }

    var hasPriorityShortcutRouting: Bool {
        switch self {
        case .switchRightSidebarToFiles, .switchRightSidebarToFind,
             .switchRightSidebarToSessions, .switchRightSidebarToFeed, .switchRightSidebarToDock,
             .simulatorHome, .simulatorRotateLeft, .simulatorRotateRight,
             .simulatorToggleAppearance, .simulatorToggleSoftwareKeyboard,
             .commandPaletteNext, .commandPalettePrevious:
            return true
        default:
            return false
        }
    }

    var shortcutContext: ShortcutContext {
        switch self {
        case .diffViewerScrollDown, .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown, .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs, .diffViewerScrollUpEmacs, .diffViewerScrollToBottom,
             .diffViewerScrollToTop:
            return .viewerPanel
        case .commandPaletteNext, .commandPalettePrevious:
            return .commandPaletteVisible
        case .switchRightSidebarToFiles, .switchRightSidebarToFind, .switchRightSidebarToSessions,
             .switchRightSidebarToFeed, .switchRightSidebarToDock, .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias:
            return .rightSidebarFocus
        case .renameTab, .renameWorkspace, .sendCtrlFToTerminal, .clearScreenKeepScrollback:
            return .outsideRightSidebar
        case .browserZoomIn, .browserZoomOut, .browserZoomReset:
            return .filePreviewTextEditor
        case .markdownZoomIn, .markdownZoomOut, .markdownZoomReset:
            return .markdownPanel
        case .simulatorHome, .simulatorRotateLeft, .simulatorRotateRight,
             .simulatorToggleAppearance, .simulatorToggleSoftwareKeyboard:
            return .simulatorPanel
        case .canvasZoomIn, .canvasZoomOut, .canvasZoomReset:
            return .canvasLayoutOutsideFocusedContent
        case .canvasRevealFocusedPane, .canvasOverview,
             .canvasTidy, .canvasAlignLeft, .canvasAlignRight,
             .canvasAlignTop, .canvasAlignBottom, .canvasEqualizeWidths,
             .canvasEqualizeHeights, .canvasDistributeHorizontally, .canvasDistributeVertically:
            return .canvasLayout
        case .saveLayoutTemplate:
            return .application
        default:
            return .application
        }
    }
}
