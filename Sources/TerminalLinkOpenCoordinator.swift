import AppKit
import CmuxTerminalCore
import CmuxTestSupport
import CmuxWorkspaces
import Foundation

/// Owns terminal-link policy and routes the resulting action through whichever
/// panel container currently owns the source terminal.
///
/// Local files that leave cmux go through the shared ``FileOpening`` seam
/// (`PreferredEditorService`), the single decision point for "open this file
/// for the user": the preferred editor when configured, otherwise the system
/// default for plain documents only (anything that could execute is shown in
/// Finder). Web and mail URLs go through `externalOpen`; any other scheme is
/// confirmed first.
@MainActor
struct TerminalLinkOpenCoordinator {
    private let defaults: UserDefaults
    private let containerResolver: @MainActor (UUID?, UUID?) -> (any TerminalLinkOpenContainer)?
    private let externalOpen: @MainActor @Sendable (URL) -> Bool
    private let fileOpen: any FileOpening

    /// Creates a coordinator using the supplied routing collaborators.
    ///
    /// The production preferred-editor service is created at the point of
    /// opening so it always reads the current editor setting.
    init(
        defaults: UserDefaults = .standard,
        containerResolver: (@MainActor (UUID?, UUID?) -> (any TerminalLinkOpenContainer)?)? = nil,
        externalOpen: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) },
        fileOpen: (any FileOpening)? = nil
    ) {
        self.defaults = defaults
        self.containerResolver = containerResolver ?? Self.resolveContainer
        self.externalOpen = externalOpen
        self.fileOpen = fileOpen ?? PreferredEditorService(defaults: defaults)
    }

    /// Opens a terminal link according to the source terminal and URL policy.
    @discardableResult
    func open(_ request: TerminalLinkOpenRequest) -> Bool {
        log("link.openURL raw=\(request.rawValue)")

        let trimmed = request.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let container = containerResolver(request.sourceWorkspaceId, request.sourcePanelId)
        var normalizedOpenURLString = request.rawValue
        let isExplicitLocalFileURL = isExplicitFileURL(trimmed)

        let canResolveLocalFilePath: Bool
        if let sourcePanelId = request.sourcePanelId, let container {
            canResolveLocalFilePath = !container.terminalLinkIsRemoteTerminal(sourcePanelId)
        } else {
            canResolveLocalFilePath = false
        }
        if !trimmed.isEmpty,
           canResolveLocalFilePath,
           let reference = TerminalPathResolver().resolveOpenURLFileReference(
               trimmed,
               cwd: resolvedWorkingDirectory(request: request, container: container)
           ) {
            if let line = reference.line, !isExplicitLocalFileURL {
                log(
                    "link.openURL resolvedAsFileLocation=\(reference.path):\(line)" +
                    (reference.column.map { ":\($0)" } ?? "")
                )
                PreferredEditorService(defaults: defaults).open(
                    URL(fileURLWithPath: reference.path),
                    line: reference.line,
                    column: reference.column
                )
                return true
            }

            if !isExplicitLocalFileURL,
               CommandClickFileOpenRouter.shouldRouteInCmux(
                   path: reference.path,
                   defaults: defaults
               ) {
                let fileURL = URL(fileURLWithPath: reference.path)
                log("link.openURL resolvedAsFilePath=\(reference.path)")
                return routeLocalFile(
                    fileURL,
                    request: request,
                    container: container,
                    unavailableReason: "file route unavailable"
                )
            }
            if !isExplicitLocalFileURL {
                normalizedOpenURLString = reference.path
            }
        }

        guard let target = resolveTerminalOpenURLTarget(normalizedOpenURLString) else {
            log("link.openURL resolve failed")
            return false
        }

        #if DEBUG
        if UITestCaptureSink().appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH",
            line: target.url.absoluteString
        ) {
            return true
        }
        #endif

        if TerminalOpenURLFileRoutingPolicy().shouldAttemptCmuxFileRouting(
            rawOpenURLValue: trimmed,
            target: target
        ), CommandClickFileOpenRouter.shouldRouteInCmux(
            path: target.url.path,
            defaults: defaults
        ) {
            return routeLocalFile(
                target.url,
                request: request,
                container: container,
                unavailableReason: "file container unavailable"
            )
        }

        let destinationURL = target.url
        return openExternally(destinationURL, reason: "external target")
    }

    private func routeLocalFile(
        _ fileURL: URL,
        request: TerminalLinkOpenRequest,
        container: (any TerminalLinkOpenContainer)?,
        unavailableReason: String
    ) -> Bool {
        guard let sourcePanelId = request.sourcePanelId,
              let container,
              !container.terminalLinkIsRemoteTerminal(sourcePanelId) else {
            return openExternally(fileURL, reason: unavailableReason)
        }

        guard container.deferTerminalFileLinkOpen(
            sourcePanelId: sourcePanelId,
            filePath: fileURL.path,
            fallback: { [self] in _ = openExternally(fileURL, reason: "cmux file route fallback") }
        ) else {
            return openExternally(fileURL, reason: unavailableReason)
        }
        return true
    }

    private func resolvedWorkingDirectory(
        request: TerminalLinkOpenRequest,
        container: (any TerminalLinkOpenContainer)?
    ) -> String? {
        if let reported = request.workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !reported.isEmpty {
            return reported
        }
        guard let sourcePanelId = request.sourcePanelId else { return nil }
        return container?.terminalLinkWorkingDirectory(for: sourcePanelId)
    }

    private func openExternally(_ url: URL, reason: String) -> Bool {
        if url.isFileURL {
            log("link.openURL opening file via preferred-editor seam reason=\(reason) url=\(url)")
            fileOpen.open(url)
            return true
        }
        guard SystemOpenSafetyPolicy.isDirectlyOpenable(url) || confirmOpening(url) else {
            log("link.openURL declined scheme=\(url.scheme ?? "") url=\(url)")
            return false
        }
        log("link.openURL opening externally reason=\(reason) url=\(url)")
        return externalOpen(url)
    }

    /// Asks before handing a non-web URL (custom app schemes, `ssh:`, `smb:`,
    /// `x-apple...`) to Launch Services. Terminal output controls both the
    /// visible link text and its real target, so the real target is shown and
    /// Cancel is the default.
    private func confirmOpening(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "terminal.link.confirmExternal.title",
            defaultValue: "Open this link in another app?"
        )
        alert.informativeText = String(
            localized: "terminal.link.confirmExternal.message",
            defaultValue: "The link was printed in the terminal and will be handed to the app registered for it:"
        ) + "\n\n" + String(url.absoluteString.prefix(2000))
        let cancel = alert.addButton(withTitle: String(
            localized: "terminal.link.confirmExternal.cancel",
            defaultValue: "Cancel"
        ))
        cancel.keyEquivalent = "\r"
        let open = alert.addButton(withTitle: String(
            localized: "terminal.link.confirmExternal.open",
            defaultValue: "Open"
        ))
        open.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Returns whether a raw link is an explicit local `file` URL.
    private func isExplicitFileURL(_ rawValue: String) -> Bool {
        URL(string: rawValue)?.scheme?.caseInsensitiveCompare("file") == .orderedSame
    }

    private static func resolveContainer(
        sourceWorkspaceId: UUID?,
        sourcePanelId: UUID?
    ) -> (any TerminalLinkOpenContainer)? {
        guard let sourcePanelId else { return nil }
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(sourcePanelId) }) {
            return dock
        }
        guard let app = AppDelegate.shared else { return nil }
        return app.workspaceContainingPanel(
            panelId: sourcePanelId,
            preferredWorkspaceId: sourceWorkspaceId
        )?.workspace
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        cmuxDebugLog(message())
        #endif
    }
}
