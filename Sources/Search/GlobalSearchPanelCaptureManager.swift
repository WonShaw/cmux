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

    /// Markdown panels were the only captured panel kind; the viewer was
    /// removed, so there is nothing to capture.
    func refreshPanelContent(for context: GlobalSearchPanelContext, index: SearchIndex) async {}

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
