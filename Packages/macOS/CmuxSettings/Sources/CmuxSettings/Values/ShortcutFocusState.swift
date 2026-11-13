import Foundation

/// A snapshot of the focus dimensions a ``ShortcutWhenClause`` evaluates against.
///
/// `terminalFocus` is derived: a terminal owns focus exactly when no
/// markdown, file-preview text editor, Simulator, or sidebar focus is present.
///
/// This is the focus-only projection of the broader ``ShortcutContext``; its
/// ``context`` property lifts the focus atoms into a context so the same
/// clause engine can evaluate both focus-only and richer predicates.
public struct ShortcutFocusState: Equatable, Sendable {
    /// Whether a markdown preview owns focus for the shortcut event.
    public var markdown: Bool
    /// Whether a file-preview text editor owns focus for the shortcut event.
    public var filePreviewTextEditor: Bool
    /// Whether a native Simulator device surface owns focus for the shortcut event.
    public var simulator: Bool
    /// Whether the right sidebar owns focus for the shortcut event.
    public var sidebar: Bool

    /// Creates a focus snapshot from the app target's current shortcut focus dimensions.
    ///
    /// - Parameters:
    ///   - markdown: Whether a markdown preview owns focus for the shortcut event.
    ///   - sidebar: Whether the right sidebar owns focus for the shortcut event.
    ///   - filePreviewTextEditor: Whether a file-preview text editor owns focus for the shortcut event.
    ///   - simulator: Whether a native Simulator device surface owns focus for the shortcut event.
    public init(
        markdown: Bool,
        sidebar: Bool,
        filePreviewTextEditor: Bool = false,
        simulator: Bool = false
    ) {
        self.markdown = markdown
        self.sidebar = sidebar
        self.filePreviewTextEditor = filePreviewTextEditor
        self.simulator = simulator
    }

    /// Whether a terminal owns focus, derived from the absence of every other tracked focus atom.
    public var terminal: Bool { !markdown && !filePreviewTextEditor && !simulator && !sidebar }

    /// Returns the boolean value of a supported focus atom in this snapshot.
    ///
    /// - Parameter atom: The focus atom to read.
    /// - Returns: The atom's value in this focus state.
    public func value(of atom: ShortcutFocusAtom) -> Bool {
        switch atom {
        case .sidebarFocus: return sidebar
        case .markdownFocus: return markdown
        case .filePreviewTextEditorFocus: return filePreviewTextEditor
        case .simulatorFocus: return simulator
        case .terminalFocus: return terminal
        }
    }

    /// The focus atoms lifted into a ``ShortcutContext``.
    ///
    /// Writes the focus keys (`sidebarFocus`, `markdownFocus`,
    /// `filePreviewTextEditorFocus`, `simulatorFocus`, `terminalFocus`) as
    /// boolean values. The app target starts from this and adds the non-focus
    /// keys (e.g. `commandPaletteVisible`, `paneCount`) before evaluating a
    /// clause.
    public var context: ShortcutContext {
        var context = ShortcutContext()
        context.setBool(ShortcutFocusAtom.sidebarFocus.rawValue, sidebar)
        context.setBool(ShortcutFocusAtom.markdownFocus.rawValue, markdown)
        context.setBool(ShortcutFocusAtom.filePreviewTextEditorFocus.rawValue, filePreviewTextEditor)
        context.setBool(ShortcutFocusAtom.simulatorFocus.rawValue, simulator)
        context.setBool(ShortcutFocusAtom.terminalFocus.rawValue, terminal)
        return context
    }

    /// The set of focus states the runtime can actually produce.
    ///
    /// `markdownFocus` and `filePreviewTextEditorFocus` never co-occur,
    /// and Simulator focus is exclusive of every other focus
    /// atom. Those combinations are excluded. Everything else is treated as
    /// realizable, which keeps conflict detection conservative (it would rather
    /// flag a possible collision than miss one).
    public static let realizableStates: [ShortcutFocusState] = {
        var states: [ShortcutFocusState] = []
        for markdown in [false, true] {
            for filePreviewTextEditor in [false, true] {
                for sidebar in [false, true] {
                    for simulator in [false, true] {
                        if markdown && filePreviewTextEditor { continue }
                        if simulator && (markdown || filePreviewTextEditor || sidebar) { continue }
                        states.append(ShortcutFocusState(
                            markdown: markdown,
                            sidebar: sidebar,
                            filePreviewTextEditor: filePreviewTextEditor,
                            simulator: simulator
                        ))
                    }
                }
            }
        }
        return states
    }()
}
