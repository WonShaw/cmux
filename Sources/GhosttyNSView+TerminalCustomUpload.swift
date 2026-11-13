import AppKit

extension GhosttyNSView {
    @discardableResult
    func deliverUploadResultText(
        _ text: String,
        onCompleted: @escaping () -> Void = {}
    ) -> Bool {
        guard let surface = terminalSurface else {
            onCompleted()
            return false
        }
        let surfaceID = surface.id
        if deferRuntimeInputDuringClipboardRead(
            estimatedBytes: text.utf8.count,
            replay: { [weak self] in
                guard let self,
                      self.terminalSurface?.id == surfaceID else {
                    onCompleted()
                    return
                }
                _ = self.deliverUploadResultText(
                    text,
                    onCompleted: onCompleted
                )
            }
        ) {
            return true
        }

        let accepted = surface.sendText(text)
        onCompleted()
        return accepted
    }
}
