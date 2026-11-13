import CmuxTerminal
import Foundation

extension WorkspaceTerminalFontSizePanelDiscovery {
    @MainActor
    struct IteratorState {
        private var phase: Phase
        private var workspacePanels:
            Dictionary<UUID, any Panel>.Iterator?
        private var workspaceDockPanels:
            Dictionary<UUID, any Panel>.Iterator?
        private var windowDockPanels:
            Dictionary<UUID, any Panel>.Iterator?

        init(workspace: Workspace) {
            phase = .workspace
            workspacePanels = workspace.panels.makeIterator()
            workspaceDockPanels =
                workspace._dockSplit?.panels.makeIterator()
            windowDockPanels = nil
        }

        init(windowDock: DockSplitStore?) {
            phase = .windowDock
            workspacePanels = nil
            workspaceDockPanels = nil
            windowDockPanels = windowDock?.panels.makeIterator()
        }

        mutating func nextEntry()
            -> (key: EntryKey, visit: Visit)? {
            while true {
                switch phase {
                case .workspace:
                    if let (panelId, panel) =
                            workspacePanels?.next() {
                        let visit: Visit =
                            panel is TerminalPanel
                            ? .candidate(
                                Candidate(
                                    panelId: panelId,
                                    origin: .workspace
                                )
                            )
                            : .nonTerminal
                        return (.workspace(panelId), visit)
                    }
                    workspacePanels = nil
                    phase = .workspaceDock

                case .workspaceDock:
                    if let (panelId, panel) =
                            workspaceDockPanels?.next() {
                        let visit: Visit =
                            panel is TerminalPanel
                            ? .candidate(
                                Candidate(
                                    panelId: panelId,
                                    origin: .workspaceDock
                                )
                            )
                            : .nonTerminal
                        return (.workspaceDock(panelId), visit)
                    }
                    workspaceDockPanels = nil
                    phase = .windowDock

                case .windowDock:
                    if let (panelId, panel) =
                            windowDockPanels?.next() {
                        let visit: Visit =
                            panel is TerminalPanel
                            ? .candidate(
                                Candidate(
                                    panelId: panelId,
                                    origin: .windowDock
                                )
                            )
                            : .nonTerminal
                        return (.windowDock(panelId), visit)
                    }
                    windowDockPanels = nil
                    phase = .finished

                case .finished:
                    return nil
                }
            }
        }
    }
}
