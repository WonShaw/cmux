import Foundation

@MainActor
final class GlobalSearchPanelCaptureManager {
    private let markdownCaptureDebounceMilliseconds = 250
    private let indexProvider: () async -> SearchIndex?
    private let cancelPanelPurge: (UUID) -> Void

    private var markdownCaptureTimers: [UUID: DispatchSourceTimer] = [:]
    private var markdownCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var markdownCaptureTaskIDs: [UUID: UUID] = [:]

    init(
        indexProvider: @escaping () async -> SearchIndex?,
        cancelPanelPurge: @escaping (UUID) -> Void
    ) {
        self.indexProvider = indexProvider
        self.cancelPanelPurge = cancelPanelPurge
    }

    func refreshPanelContent(for context: GlobalSearchPanelContext, index: SearchIndex) async {
        if let markdownPanel = context.panel as? MarkdownPanel {
            if markdownPanel.isFileUnavailable {
                cancelMarkdownCapture(forPanelID: context.panelID)
                await purgeMarkdownDocument(forPanelID: context.panelID, index: index)
            } else if let document = GlobalSearchDocuments.markdownDocument(for: markdownPanel, context: context) {
                do {
                    try await index.upsert(document)
                } catch {
#if DEBUG
                    cmuxDebugLog("globalSearch.markdown.upsert failed panel=\(context.panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
                }
            }
        }
    }

    func captureMarkdownPanel(_ panel: MarkdownPanel) {
        let panelID = panel.id
        guard !panel.isFileUnavailable else {
            cancelMarkdownCapture(forPanelID: panelID)
            let taskID = UUID()
            markdownCaptureTaskIDs[panelID] = taskID
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.markdownCaptureTaskIDs[panelID] == taskID {
                        self.markdownCaptureTasks[panelID] = nil
                        self.markdownCaptureTaskIDs[panelID] = nil
                    }
                }

                guard !Task.isCancelled,
                      self.markdownCaptureTaskIDs[panelID] == taskID,
                      let index = await self.indexProvider() else {
                    return
                }

                await self.purgeMarkdownDocument(forPanelID: panelID, index: index)
            }
            markdownCaptureTasks[panelID] = task
            return
        }

        cancelPanelPurge(panelID)
        let taskID = UUID()
        cancelMarkdownCapture(forPanelID: panelID)
        markdownCaptureTaskIDs[panelID] = taskID

        let timer = makeDebounceTimer(milliseconds: markdownCaptureDebounceMilliseconds) { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self,
                      self.markdownCaptureTaskIDs[panelID] == taskID else {
                    return
                }
                self.markdownCaptureTimers[panelID]?.cancel()
                self.markdownCaptureTimers[panelID] = nil

                let task = Task { @MainActor [weak self, weak panel] in
                    guard let self else { return }
                    defer {
                        if self.markdownCaptureTaskIDs[panelID] == taskID {
                            self.markdownCaptureTasks[panelID] = nil
                            self.markdownCaptureTaskIDs[panelID] = nil
                        }
                    }

                    guard !Task.isCancelled,
                          self.markdownCaptureTaskIDs[panelID] == taskID,
                          let panel,
                          let context = AppDelegate.shared?.globalSearchContext(
                              forPanelID: panel.id,
                              preferredWorkspaceID: panel.workspaceId
                          ),
                          let document = GlobalSearchDocuments.markdownDocument(for: panel, context: context),
                          let index = await self.indexProvider() else {
                        return
                    }

                    do {
                        try await index.upsert(document)
                    } catch {
                        guard !Task.isCancelled else { return }
#if DEBUG
                        cmuxDebugLog("globalSearch.markdown.capture failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
                    }
                }
                self.markdownCaptureTasks[panelID] = task
            }
        }
        markdownCaptureTimers[panelID] = timer
        timer.resume()
    }

    func cancelCaptures(forPanelID panelID: UUID) {
        cancelMarkdownCapture(forPanelID: panelID)
    }

    private func cancelMarkdownCapture(forPanelID panelID: UUID) {
        markdownCaptureTimers[panelID]?.cancel()
        markdownCaptureTimers[panelID] = nil
        markdownCaptureTasks[panelID]?.cancel()
        markdownCaptureTasks[panelID] = nil
        markdownCaptureTaskIDs[panelID] = nil
    }

    private func makeDebounceTimer(
        milliseconds: Int,
        handler: @escaping () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(milliseconds), leeway: .milliseconds(25))
        timer.setEventHandler(handler: handler)
        return timer
    }

    private func purgeMarkdownDocument(forPanelID panelID: UUID, index: SearchIndex) async {
        let documentID = SearchIndexDocument.panelStableID(panelID: panelID, kind: .markdown)
        do {
            try await index.deleteDocument(id: documentID)
        } catch {
#if DEBUG
            cmuxDebugLog("globalSearch.markdown.purge failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
        }
    }
}
