import AppKit
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit

extension GhosttySurfaceCallbackContext {
    func registerRuntimeClipboardRead(
        id: UInt,
        stateAddress: UInt,
        operation: TerminalImageTransferOperation,
        surfaceView: GhosttyNSView?
    ) -> UInt? {
        guard let surfaceAddress = runtimeClipboardSurfaceAddress else {
            return nil
        }
        let inputSequencer = surfaceView?.terminalClipboardInputSequencer
        let overflowHandler = makeRuntimeClipboardInvalidationHandler(
            for: id,
            completingNativeRequest: true,
            deferredInputDisposition: .replay
        )
        guard registerRuntimeClipboardRequest(
            id: id,
            reservePasteInput: { epoch in
                guard let inputSequencer else { return false }
                return inputSequencer.reserveRequestAdmission(
                    id: id,
                    epoch: epoch,
                    onOverflow: overflowHandler
                )
            },
            onInvalidation: {
                @MainActor [weak surfaceView]
                wasAdmitted,
                completesNativeRequest,
                inputAdmission,
                deferredInputDisposition in
                _ = operation.cancel()
                surfaceView?.terminalSurface?.hostedView
                    .endImageTransferIndicator(for: operation)
                if completesNativeRequest,
                   let surface = ghostty_surface_t(
                    bitPattern: surfaceAddress
                   ) {
                    // Teardown cannot present a confirmation prompt; approving
                    // empty text guarantees libghostty destroys its request.
                    "".withCString { pointer in
                        ghostty_surface_complete_clipboard_request(
                            surface,
                            pointer,
                            UnsafeMutableRawPointer(
                                bitPattern: stateAddress
                            ),
                            true
                        )
                    }
                }

                let currentEpoch = surfaceView?.terminalSurface?
                    .runtimeSurfaceGeneration ?? .max
                if wasAdmitted {
                    surfaceView?.cancelClipboardRead(
                        id,
                        currentEpoch: currentEpoch,
                        deferredInputDisposition: deferredInputDisposition
                    )
                } else if case .reserved(let requestEpoch) = inputAdmission {
                    surfaceView?.cancelReservedClipboardRead(
                        id,
                        requestEpoch: requestEpoch,
                        currentEpoch: currentEpoch,
                        deferredInputDisposition: deferredInputDisposition
                    )
                }
            }
        ) else {
            return nil
        }
        return surfaceAddress
    }

    @MainActor
    func completeRuntimeClipboardRead(
        _ text: String,
        requestID: UInt,
        stateAddress: UInt,
        surfaceAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity
    ) {
        guard let surfaceView else {
            finishRuntimeClipboardRead(
                text,
                requestID: requestID,
                stateAddress: stateAddress,
                surfaceAddress: surfaceAddress,
                surfaceIdentity: surfaceIdentity
            )
            return
        }
        surfaceView.performClipboardReadCompletionWhenReady(requestID) {
            self.finishRuntimeClipboardRead(
                text,
                requestID: requestID,
                stateAddress: stateAddress,
                surfaceAddress: surfaceAddress,
                surfaceIdentity: surfaceIdentity
            )
        }
    }

    @MainActor
    private func finishRuntimeClipboardRead(
        _ text: String,
        requestID: UInt,
        stateAddress: UInt,
        surfaceAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity
    ) {
        guard let terminalSurface,
              surfaceIdentity.matches(terminalSurface),
              surfaceIdentity.surfaceAddress == surfaceAddress,
              let surface = ghostty_surface_t(
                bitPattern: surfaceAddress
              ) else {
            invalidateRuntimeClipboardRequest(
                requestID,
                completingNativeRequest: true,
                deferredInputDisposition: .discard
            )
            return
        }
        guard completeRuntimeClipboardRequest(requestID) else { return }

        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(
                surface,
                pointer,
                UnsafeMutableRawPointer(bitPattern: stateAddress),
                false
            )
        }
        if let surfaceView {
            surfaceView.completeClipboardRead(requestID, confirmed: false) {
                terminalSurface.noteClipboardReadCompleted()
            }
        } else {
            terminalSurface.noteClipboardReadCompleted()
        }
    }

    /// Ghostty asks for confirmation when a paste looks unsafe (it contains a
    /// newline outside bracketed paste) or when a program requests the
    /// clipboard through OSC 52. Unsafe pastes are shown to the user first;
    /// OSC 52 reads are always answered with nothing.
    @MainActor
    func confirmClipboardRead(
        _ text: String,
        stateAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity,
        isPaste: Bool
    ) {
        surfaceView?.clipboardReadRequiresConfirmation(stateAddress)
        guard isPaste else {
            finishConfirmedClipboardRead("", stateAddress: stateAddress, surfaceIdentity: surfaceIdentity)
            return
        }
        // Present after Ghostty's synchronous callback returns; typed input is
        // buffered by the sequencer until the request completes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let approved = Self.userApprovesUnsafePaste(text)
            self.finishConfirmedClipboardRead(
                approved ? text : "",
                stateAddress: stateAddress,
                surfaceIdentity: surfaceIdentity
            )
        }
    }

    @MainActor
    private static func userApprovesUnsafePaste(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "terminal.paste.confirmUnsafe.title",
            defaultValue: "Paste text that may run commands?"
        )
        let preview = text.count > 1200 ? String(text.prefix(1200)) + "\n…" : text
        alert.informativeText = String(
            localized: "terminal.paste.confirmUnsafe.message",
            defaultValue: "The text contains line breaks, so the shell may run it as soon as it is pasted:"
        ) + "\n\n" + preview
        let cancel = alert.addButton(withTitle: String(
            localized: "terminal.paste.confirmUnsafe.cancel",
            defaultValue: "Cancel"
        ))
        cancel.keyEquivalent = "\r"
        let paste = alert.addButton(withTitle: String(
            localized: "terminal.paste.confirmUnsafe.paste",
            defaultValue: "Paste"
        ))
        paste.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }

    @MainActor
    private func finishConfirmedClipboardRead(
        _ text: String,
        stateAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity
    ) {
        guard let state = UnsafeMutableRawPointer(bitPattern: stateAddress),
              let terminalSurface,
              surfaceIdentity.matches(terminalSurface),
              let surface = terminalSurface.surface,
              UInt(bitPattern: surface) == surfaceIdentity.surfaceAddress else {
            surfaceView?.cancelClipboardRead(
                stateAddress,
                currentEpoch: surfaceView?.terminalSurface?
                    .runtimeSurfaceGeneration ?? .max,
                deferredInputDisposition: .discard
            )
            return
        }
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(
                surface,
                pointer,
                state,
                true
            )
        }
        surfaceView?.completeClipboardRead(stateAddress, confirmed: true) {
            terminalSurface.noteClipboardReadCompleted()
        }
    }
}
