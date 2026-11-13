import CmuxTerminal

extension TerminalSurface {
    @MainActor
    func resolvedImageTransferTarget(
        mode: TerminalImageTransferMode = .paste,
        in workspace: Workspace? = nil
    ) -> TerminalImageTransferTarget {
        let workspace = workspace ?? owningWorkspace()
        return .local
    }
}
