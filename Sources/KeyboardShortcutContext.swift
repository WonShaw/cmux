import AppKit
import CmuxSettings
import CmuxSimulatorUI

struct ShortcutEventFocusContext {
    let markdownPanel: MarkdownPanel?
    let filePreviewTextEditorFocused: Bool
    let simulatorFocused: Bool
    let simulatorPanel: SimulatorPanel?
    let simulatorTextEditorFocused: Bool
    let rightSidebarFocused: Bool
    /// The full context snapshot a ``ShortcutWhenClause`` evaluates against.
    let shortcutContext: ShortcutContext

    init(
        markdownPanel: MarkdownPanel?,
        filePreviewTextEditorFocused: Bool,
        simulatorFocused: Bool,
        simulatorPanel: SimulatorPanel? = nil,
        simulatorTextEditorFocused: Bool = false,
        rightSidebarFocused: Bool,
        shortcutContext: ShortcutContext
    ) {
        self.markdownPanel = markdownPanel
        self.filePreviewTextEditorFocused = filePreviewTextEditorFocused
        self.simulatorFocused = simulatorFocused
        self.simulatorPanel = simulatorPanel
        self.simulatorTextEditorFocused = simulatorTextEditorFocused
        self.rightSidebarFocused = rightSidebarFocused
        self.shortcutContext = shortcutContext
    }

    var allowsSimulatorShortcutRouting: Bool {
        simulatorFocused && !simulatorTextEditorFocused
    }

    /// Projects the runtime focus snapshot onto the atoms a
    /// ``ShortcutWhenClause`` evaluates against.
    var focusState: ShortcutFocusState {
        ShortcutFocusState(
            markdown: markdownPanel != nil,
            sidebar: rightSidebarFocused,
            filePreviewTextEditor: filePreviewTextEditorFocused,
            simulator: simulatorFocused
        )
    }
}

func shortcutResponderAcceptsTextEditing(_ responder: NSResponder) -> Bool {
    if let textView = responder as? NSTextView {
        return textView.isEditable || textView.isSelectable || textView.isFieldEditor
    }
    if let textField = responder as? NSTextField {
        return textField.isEditable || textField.isSelectable
    }
    return false
}

struct ShortcutEventFocusContextCache {
    let event: NSEvent
    let context: ShortcutEventFocusContext
}

extension AppDelegate {
    func shortcutEventMarkdownPanel(_ event: NSEvent) -> MarkdownPanel? {
        shortcutEventFocusContext(event).markdownPanel
    }

    func shortcutEventFocusContext(_ event: NSEvent) -> ShortcutEventFocusContext {
        if let cache = shortcutEventFocusContextCache, cache.event === event {
            return cache.context
        }

        let shortcutWindow = shortcutResolvedEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        let simulatorPanel = shortcutFocusedSimulatorPanel(in: shortcutWindow)
        let simulatorFocused = simulatorPanel != nil
        let simulatorTextEditorFocused = simulatorFocused
            && shortcutWindow?.firstResponder.map(shortcutResponderAcceptsTextEditing) == true
        let markdownPanel = shortcutFocusedMarkdownPanel(in: shortcutWindow)
        let filePreviewTextEditorFocused = markdownPanel == nil
            ? shortcutFocusedFilePreviewTextEditor(in: shortcutWindow)
            : false
        let rightSidebarFocused = !simulatorFocused
            && (shortcutWindow.map { shouldRouteRightSidebarModeShortcut(in: $0) } ?? false)
        let focusState = ShortcutFocusState(
            markdown: markdownPanel != nil,
            sidebar: rightSidebarFocused,
            filePreviewTextEditor: filePreviewTextEditorFocused,
            simulator: simulatorFocused
        )
        let context = ShortcutEventFocusContext(
            markdownPanel: markdownPanel,
            filePreviewTextEditorFocused: filePreviewTextEditorFocused,
            simulatorFocused: simulatorFocused,
            simulatorPanel: simulatorPanel,
            simulatorTextEditorFocused: simulatorTextEditorFocused,
            rightSidebarFocused: rightSidebarFocused,
            shortcutContext: buildShortcutContext(focusState: focusState, window: shortcutWindow)
        )
        shortcutEventFocusContextCache = ShortcutEventFocusContextCache(event: event, context: context)
        return context
    }

    /// Builds the full ``ShortcutContext`` for a shortcut event: the focus atoms
    /// (via ``ShortcutFocusState/context``) plus the non-focus context keys read
    /// synchronously from the shortcut window's state. Called once per event (the
    /// result is cached in ``shortcutEventFocusContextCache``).
    private func buildShortcutContext(focusState: ShortcutFocusState, window: NSWindow?) -> ShortcutContext {
        var context = focusState.context
        context.setBool(
            ShortcutContextKnownKey.commandPaletteVisible.rawValue,
            window.map { isCommandPaletteEffectivelyVisible(for: $0) } ?? false
        )
        if let tabManager = shortcutContextTabManager(in: window) {
            context.setInt(ShortcutContextKnownKey.workspaceCount.rawValue, tabManager.tabs.count)
            if let workspace = tabManager.selectedWorkspace {
                context.setInt(ShortcutContextKnownKey.paneCount.rawValue, workspace.panels.count)
                context.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, workspace.layoutMode == .canvas)
                context.setBool(
                    ShortcutContextKnownKey.terminalFindVisible.rawValue,
                    workspace.focusedTerminalInputTarget()?.panel.searchState != nil
                )
            }
        }
        if let mode = window.flatMap({ keyboardFocusCoordinator(for: $0)?.activeRightSidebarMode }) {
            context.setString(ShortcutContextKnownKey.sidebarMode.rawValue, mode.rawValue)
        }
        return context
    }

    /// The ``TabManager`` driving the shortcut window, falling back to the app's
    /// current tab manager when the window is unknown.
    private func shortcutContextTabManager(in window: NSWindow?) -> TabManager? {
        if let context = shortcutMainWindowContext(in: window) {
            return context.tabManager
        }
        return tabManager
    }

    private func shortcutMainWindowContext(in window: NSWindow?) -> MainWindowContext? {
        guard let window else { return nil }
        return mainWindowContexts[ObjectIdentifier(window)] ??
            mainWindowContexts.values.first(where: { $0.window === window })
    }

    private func shortcutFocusedMarkdownPanel(in window: NSWindow?) -> MarkdownPanel? {
        // `focusedMarkdownPanel` is already gated to preview mode, where the
        // rendered viewer responds to zoom (the raw text editor does not).
        if let window {
            guard let context = shortcutMainWindowContext(in: window) else {
                return nil
            }
            return context.tabManager.focusedMarkdownPanel
        }

        return tabManager?.focusedMarkdownPanel
    }

    private func shortcutFocusedFilePreviewTextEditor(in window: NSWindow?) -> Bool {
        guard let focusedFilePreviewPanel = shortcutContextTabManager(in: window)?.focusedTextFilePreviewPanel,
              let textView = shortcutFocusedSavingTextView(in: window),
              let owningFilePreviewPanel = textView.panel as? FilePreviewPanel,
              owningFilePreviewPanel === focusedFilePreviewPanel else {
            return false
        }

        return true
    }

    private func shortcutFocusedSavingTextView(in window: NSWindow?) -> SavingTextView? {
        guard let responder = window?.firstResponder ?? NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder else {
            return nil
        }
        if let textView = responder as? SavingTextView {
            return textView
        }

        var current = responder.nextResponder
        while let next = current {
            if let textView = next as? SavingTextView {
                return textView
            }
            current = next.nextResponder
        }
        return nil
    }

    @discardableResult
    func handleFocusedFileExplorerOpenSelectionShortcut(_ event: NSEvent, preferredWindow: NSWindow? = nil) -> Bool {
        let window = preferredWindow ?? shortcutResolvedEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let window,
              let responder = window.firstResponder,
              let focusView = shortcutFileExplorerFocusView(for: responder),
              focusView.window === window || focusView.window?.windowNumber == window.windowNumber else {
            return false
        }

        if let outlineView = focusView as? FileExplorerNSOutlineView {
            return outlineView.handleOpenSelectionShortcut(event)
        }
        if let resultsView = focusView as? FileExplorerSearchResultsTableView {
            return resultsView.handleOpenSelectionShortcut(event)
        }
        if let searchField = focusView as? FileExplorerSearchField {
            return searchField.handleOpenSelectionShortcut(event)
        }
        return false
    }

    private func shortcutFileExplorerFocusView(for responder: NSResponder) -> NSView? {
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           let ownerView = cmuxFieldEditorOwnerView(textView) {
            return fileExplorerShortcutFocusRoot(containing: ownerView)
        }

        if let view = responder as? NSView {
            return fileExplorerShortcutFocusRoot(containing: view)
        }

        return nil
    }

    private func fileExplorerShortcutFocusRoot(containing view: NSView) -> NSView? {
        var current: NSView? = view
        while let candidate = current {
            if isFileExplorerShortcutFocusRoot(candidate) {
                return candidate
            }
            current = candidate.superview
        }
        return nil
    }

    private func isFileExplorerShortcutFocusRoot(_ view: NSView) -> Bool {
        view is FileExplorerNSOutlineView ||
            view is FileExplorerSearchResultsTableView ||
            view is FileExplorerSearchField
    }

    func clearShortcutEventFocusContextCache(for event: NSEvent) {
        if shortcutEventFocusContextCache?.event === event {
            shortcutEventFocusContextCache = nil
        }
    }

    private func shortcutFocusedSimulatorPanel(in window: NSWindow?) -> SimulatorPanel? {
        guard let window, let responder = window.firstResponder else { return nil }
        if let context = shortcutMainWindowContext(in: window),
           let dock = existingWindowDock(forWindowId: context.windowId) {
            if let panelId = dock.focusedPanelId,
               let panel = dock.panels[panelId] as? SimulatorPanel,
               panel.ownedFocusIntent(for: responder, in: window) != nil {
                return panel
            }
        }
        guard let workspace = shortcutContextTabManager(in: window)?.selectedWorkspace else {
            return nil
        }
        if let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId] as? SimulatorPanel,
           panel.ownedFocusIntent(for: responder, in: window) != nil {
            return panel
        }
        return nil
    }

    private func shortcutResolvedEventWindow(_ event: NSEvent) -> NSWindow? {
        if event.windowNumber > 0,
           let window = NSApp.window(withWindowNumber: event.windowNumber) {
            return window
        }
        return event.window
    }
}
