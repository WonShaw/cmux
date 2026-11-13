import AppKit
import CmuxFoundation
import CmuxSettings
import Bonsplit
import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    static let defaultTerminalRegistrationDidChange = Notification.Name("DefaultTerminalRegistration.didChange")
}

struct DefaultTerminalRegistrationStatus: Equatable {
    let matchedTargetCount: Int
    let targetCount: Int

    var isDefault: Bool {
        matchedTargetCount == targetCount
    }
}

enum DefaultTerminalRegistrationError: Error, LocalizedError {
    case launchServicesRegistrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .launchServicesRegistrationFailed:
            return String(
                localized: "error.defaultTerminal.registrationFailed",
                defaultValue: "cmux could not register as the default terminal app."
            )
        }
    }
}

enum DefaultTerminalRegistration {
    static let contentTypeIdentifiers = [
        "com.apple.terminal.shell-script",
        "public.unix-executable"
    ]

    static func contentType(forIdentifier identifier: String) -> UTType {
        UTType(identifier) ?? UTType(importedAs: identifier)
    }

    static var targetCount: Int {
        contentTypeIdentifiers.count
    }

    static func currentStatus(
        bundleURL: URL = Bundle.main.bundleURL,
        workspace: NSWorkspace = .shared
    ) -> DefaultTerminalRegistrationStatus {
        let normalizedBundleURL = normalizedApplicationURL(bundleURL)
        let matchedContentTypes = contentTypeIdentifiers.filter { identifier in
            let contentType = contentType(forIdentifier: identifier)
            return normalizedApplicationURL(workspace.urlForApplication(toOpen: contentType)) == normalizedBundleURL
        }.count

        return DefaultTerminalRegistrationStatus(
            matchedTargetCount: matchedContentTypes,
            targetCount: targetCount
        )
    }

    static func setAsDefault(bundleURL: URL = Bundle.main.bundleURL) async throws {
        let normalizedBundleURL = normalizedApplicationURL(bundleURL) ?? bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        var didAttemptHandlerUpdate = false
        defer {
            if didAttemptHandlerUpdate {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .defaultTerminalRegistrationDidChange, object: nil)
                }
            }
        }

        let registerStatus = LSRegisterURL(normalizedBundleURL as CFURL, true)
        guard registerStatus == noErr else {
            throw DefaultTerminalRegistrationError.launchServicesRegistrationFailed(registerStatus)
        }
        didAttemptHandlerUpdate = true

        for identifier in contentTypeIdentifiers {
            let contentType = contentType(forIdentifier: identifier)
            try await NSWorkspace.shared.setDefaultApplication(
                at: normalizedBundleURL,
                toOpen: contentType
            )
        }
    }

    private static func normalizedApplicationURL(_ url: URL?) -> URL? {
        url?.standardizedFileURL.resolvingSymlinksInPath()
    }
}

@MainActor
enum DefaultTerminalUserAction {
    private struct RegistrationOperation {
        let id: UUID
        let task: Task<Void, Error>
    }

    private static var inFlightRegistration: RegistrationOperation?

    @discardableResult
    static func registerAsDefault() async throws -> Bool {
        if let operation = inFlightRegistration {
            do {
                try await operation.task.value
            } catch {
                return false
            }
            return false
        }

        let operation = RegistrationOperation(
            id: UUID(),
            task: Task {
                try await DefaultTerminalRegistration.setAsDefault()
            }
        )
        inFlightRegistration = operation

        do {
            try await operation.task.value
            if inFlightRegistration?.id == operation.id {
                inFlightRegistration = nil
            }
            return true
        } catch {
            if inFlightRegistration?.id == operation.id {
                inFlightRegistration = nil
            }
            throw error
        }
    }

    static func setAsDefault(debugSource: String) {
#if DEBUG
        cmuxDebugLog("defaultTerminal.setAsDefault source=\(debugSource)")
#endif
        Task {
            do {
                try await registerAsDefault()
            } catch {
#if DEBUG
                cmuxDebugLog("defaultTerminal.setAsDefault.failed source=\(debugSource) error=\(error)")
#endif
                presentSetAsDefaultError(error)
            }
        }
    }

    private static func presentSetAsDefaultError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.defaultTerminal.setFailed.title",
            defaultValue: "Could Not Set Default Terminal"
        )
        alert.informativeText = (error as? DefaultTerminalRegistrationError)?.errorDescription ?? String(
            localized: "defaultTerminal.updateFailed.message",
            defaultValue: "macOS could not update every default terminal handler."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.window.identifier = NSUserInterfaceItemIdentifier("cmux.defaultTerminalRegistrationError")
        alert.runModal()
    }
}

struct TerminalDefaultFileOpenRequest: Equatable {
    let fileURL: URL
    let workingDirectory: String
    let initialInput: String

    init?(fileURL: URL, contentType: UTType? = nil, isExecutable: Bool? = nil) {
        guard fileURL.isFileURL else { return nil }
        let standardizedURL = fileURL.standardizedFileURL
        let directoryCheckURL = standardizedURL.resolvingSymlinksInPath()
        guard !SessionPersistencePolicy.isCmuxCrashStorageURL(standardizedURL) else { return nil }
        guard !SessionPersistencePolicy.isCmuxCrashStorageURL(directoryCheckURL) else { return nil }
        let resourceValues = try? directoryCheckURL.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues?.isDirectory != true else { return nil }
        let resolvedContentType = contentType ?? Self.contentType(for: standardizedURL)
        let resolvedIsExecutable = isExecutable ?? Self.isExecutableFile(directoryCheckURL)
        guard Self.shouldRunInTerminal(
            fileURL: standardizedURL,
            contentType: resolvedContentType,
            isExecutable: resolvedIsExecutable
        ) else {
            return nil
        }

        self.fileURL = standardizedURL
        // `path(percentEncoded:)` keeps a directory URL's trailing slash, so the parent of
        // "/tmp/scripts/run.command" came back as "/tmp/scripts/". That string becomes the
        // workspace's working directory, which the window title renders via {activeDirectory}
        // and which directory comparisons match on, so the stray slash is user visible. `path`
        // reports the same decoded path without it and still reports "/" for a file at the root.
        self.workingDirectory = standardizedURL.deletingLastPathComponent().path
        self.initialInput = "\(Self.shellSingleQuoted(standardizedURL.path(percentEncoded: false)))\n"
    }

    static func requests(from urls: [URL]) -> [TerminalDefaultFileOpenRequest] {
        var seen: Set<String> = []
        var requests: [TerminalDefaultFileOpenRequest] = []
        for url in urls {
            guard let request = TerminalDefaultFileOpenRequest(fileURL: url) else { continue }
            let path = request.fileURL.path(percentEncoded: false)
            guard seen.insert(path).inserted else { continue }
            requests.append(request)
        }
        return requests
    }

    private static func contentType(for fileURL: URL) -> UTType? {
        try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType
    }

    private static func isExecutableFile(_ fileURL: URL) -> Bool {
        if (try? fileURL.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true {
            return true
        }
        return FileManager.default.isExecutableFile(atPath: fileURL.path(percentEncoded: false))
    }

    private static func shouldRunInTerminal(fileURL: URL, contentType: UTType?, isExecutable: Bool) -> Bool {
        if isTerminalShellScript(fileURL: fileURL, contentType: contentType) {
            return true
        }
        return contentType?.conforms(to: .unixExecutable) == true || isExecutable
    }

    private static func isTerminalShellScript(fileURL: URL, contentType: UTType?) -> Bool {
        if contentType?.identifier == "com.apple.terminal.shell-script" {
            return true
        }
        switch fileURL.pathExtension.lowercased() {
        case "command", "tool":
            return true
        default:
            return false
        }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

extension AppDelegate {
    func deferInitialMainWindowBootstrapForExternalConfirmation() {
        guard !didAttemptStartupSessionRestore, !didHandleExplicitOpenIntentAtStartup else { return }
        shouldDeferInitialMainWindowBootstrapForExternalConfirmation = true
    }

    func resumeInitialMainWindowBootstrapAfterExternalConfirmation(debugSource: String) {
        guard shouldDeferInitialMainWindowBootstrapForExternalConfirmation else { return }
        shouldDeferInitialMainWindowBootstrapForExternalConfirmation = false
        scheduleInitialMainWindowBootstrap(debugSource: debugSource)
    }

    func bootstrapInitialMainWindowAfterAcceptedExternalOpen(
        debugSource: String,
        shouldActivate: Bool = true,
        suppressWelcome: Bool = false
    ) {
        shouldDeferInitialMainWindowBootstrapForExternalConfirmation = false
        _ = bootstrapInitialMainWindowIfNeeded(
            debugSource: debugSource,
            shouldActivate: shouldActivate,
            suppressWelcome: suppressWelcome
        )
    }

    func claimAuthCallbackURLSchemes() {
        // Pin the current build's callback scheme so auth, SSH, and navigation deeplinks
        // route back to this app instead of an unrelated LaunchServices entry.
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(
            at: bundleURL,
            toOpenURLsWithScheme: CmuxAppURLScheme.current
        ) { _ in }
    }

    @discardableResult
    func handleCmuxExternalURLs(from urls: [URL]) -> Bool {
        let intentCounts = cmuxExternalURLIntentCounts(in: urls)
        guard intentCounts.total > 0 else { return false }
        guard intentCounts.total == 1 else {
            showCmuxTextURLParseError(.multipleLinks)
            return true
        }

        if handleCmuxNavigationURLs(from: urls) {
            return true
        }
        if handleCmuxTextURLs(from: urls) {
            return true
        }
        return false
    }

    private struct CmuxExternalURLIntentCounts {
        var navigation = 0
        var text = 0

        var total: Int {
            navigation + text
        }
    }

    private func cmuxExternalURLIntentCounts(in urls: [URL]) -> CmuxExternalURLIntentCounts {
        urls.reduce(CmuxExternalURLIntentCounts()) { counts, url in
            var nextCounts = counts
            switch CmuxNavigationURLRequest.parse(url) {
            case .success(.some), .failure:
                nextCounts.navigation += 1
            case .success(nil):
                break
            }
            switch CmuxTextURLRequest.parse(url) {
            case .success(.some), .failure:
                nextCounts.text += 1
            case .success(nil):
                break
            }
            return nextCounts
        }
    }

    @discardableResult
    func handleCmuxNavigationURLs(from urls: [URL]) -> Bool {
        var navigationRequests: [CmuxNavigationURLRequest] = []
        var parseErrors: [(url: URL, error: CmuxNavigationURLParseError)] = []

        for url in urls {
            switch CmuxNavigationURLRequest.parse(url) {
            case .success(.some(let request)):
                navigationRequests.append(request)
            case .success(nil):
                break
            case .failure(let error):
                parseErrors.append((url, error))
            }
        }

        let navigationIntentCount = navigationRequests.count + parseErrors.count
        guard navigationIntentCount > 0 else { return false }

        guard navigationIntentCount == 1 else {
#if DEBUG
            cmuxDebugLog("navigationURL.ignored reason=multipleLinks count=\(urls.count) intents=\(navigationIntentCount)")
#endif
            return true
        }

        if let parseError = parseErrors.first {
#if DEBUG
            cmuxDebugLog("navigationURL.blocked reason=\(parseError.error) url=\(parseError.url.absoluteString.prefix(160))")
#endif
            return true
        }

        if let request = navigationRequests.first {
            _ = handleCmuxNavigationURLRequest(request)
        }
        return true
    }

    @discardableResult
    func handleCmuxTextURLs(from urls: [URL]) -> Bool {
        var textURLRequests: [CmuxTextURLRequest] = []
        var textURLParseErrors: [CmuxTextURLParseError] = []
        for url in urls {
            switch CmuxTextURLRequest.parse(url) {
            case .success(.some(let request)):
                textURLRequests.append(request)
            case .success(nil):
                break
            case .failure(let error):
                textURLParseErrors.append(error)
            }
        }
        let textURLIntentCount = textURLRequests.count + textURLParseErrors.count
        guard textURLIntentCount > 0 else { return false }

        if textURLIntentCount > 1 {
            showCmuxTextURLParseError(.multipleLinks)
        } else {
            for error in textURLParseErrors {
                showCmuxTextURLParseError(error)
            }
            if let request = textURLRequests.first {
                handleCmuxTextURLRequest(request)
            }
        }
        return true
    }

    private func handleCmuxTextURLRequest(_ request: CmuxTextURLRequest) {
#if DEBUG
        let target = request.originalURL.host ?? request.originalURL.path
        cmuxDebugLog("textURL.prompt target=\(target) kind=\(request.kind.rawValue) textLength=\(request.text.count)")
#endif

        deferInitialMainWindowBootstrapForExternalConfirmation()
        guard confirmCmuxTextURLRequest(request) else {
            resumeInitialMainWindowBootstrapAfterExternalConfirmation(debugSource: "textURL.cancelled")
#if DEBUG
            cmuxDebugLog("textURL.cancelled")
#endif
            return
        }

        prepareForExplicitOpenIntentAtStartup()
        bootstrapInitialMainWindowAfterAcceptedExternalOpen(
            debugSource: "textURL.confirmed",
            shouldActivate: !request.noFocus,
            suppressWelcome: true
        )
        if !request.noFocus {
            NSApp.activate(ignoringOtherApps: true)
        }
        let didPaste = pasteTextInPreferredMainWindowFromExternalLink(
            request.pasteText,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            shouldBringToFront: !request.noFocus,
            debugSource: "textURL.\(request.kind.rawValue)",
            onSendFailure: { [weak self] in
                self?.showCmuxTextURLPasteFailure(request)
            }
        )
        if !didPaste {
            showCmuxTextURLPasteFailure(request)
        }
    }

    private func confirmCmuxTextURLRequest(_ request: CmuxTextURLRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.kind == .prompt
            ? String(localized: "dialog.textURL.prompt.title", defaultValue: "Paste a Prompt From an External Link?")
            : String(localized: "dialog.textURL.rules.title", defaultValue: "Paste Rules From an External Link?")

        let scheme = request.originalURL.scheme ?? CmuxAppURLScheme.current
        let messageFormat = request.kind == .prompt
            ? String(
                localized: "dialog.textURL.prompt.message",
                defaultValue: "A %@:// link is asking cmux to paste a prompt into the current workspace. cmux cannot verify which website or app opened this link.\n\ncmux will paste the text into the terminal and will not press Return. Only continue if you trust this prompt."
            )
            : String(
                localized: "dialog.textURL.rules.message",
                defaultValue: "A %@:// link is asking cmux to paste rules into the current workspace. cmux cannot verify which website or app opened this link.\n\ncmux will paste the rules into the terminal and will not write files or press Return. Only continue if you trust these rules."
            )
        alert.informativeText = String(
            format: messageFormat,
            scheme
        )

        alert.addButton(withTitle: String(localized: "dialog.textURL.cancel", defaultValue: "Cancel"))
        alert.addButton(withTitle: String(localized: "dialog.textURL.paste", defaultValue: "Paste"))

        let cancelButton = alert.buttons[0]
        cancelButton.keyEquivalent = "\r"
        if alert.buttons.count > 1 {
            alert.buttons[1].keyEquivalent = ""
        }

        alert.accessoryView = cmuxTextURLAccessoryView(request: request)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func cmuxTextURLAccessoryView(request: CmuxTextURLRequest) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let localizedKind = request.kind == .prompt
            ? String(localized: "dialog.textURL.kind.prompt", defaultValue: "Prompt")
            : String(localized: "dialog.textURL.kind.rules", defaultValue: "Rules")
        let displayTitle = request.name ?? request.title
        let kindLabel = NSTextField(labelWithString: String(
            format: String(localized: "dialog.textURL.kindLabel", defaultValue: "Link type: %@"),
            localizedKind
        ))
        kindLabel.lineBreakMode = .byTruncatingTail
        kindLabel.maximumNumberOfLines = 1

        let titleLabel = displayTitle.map { displayTitle in
            let label = NSTextField(labelWithString: String(
                format: String(localized: "dialog.textURL.titleLabel", defaultValue: "Title: %@"),
                displayTitle
            ))
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            return label
        }

        let previewLabel = NSTextField(labelWithString: String(
            localized: "dialog.textURL.previewLabel",
            defaultValue: "Text preview:"
        ))
        previewLabel.font = GlobalFontMagnification.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

        let preview = cmuxSSHURLTextPreview(request.pasteText, height: 180)

        stack.addArrangedSubview(kindLabel)
        if let titleLabel {
            stack.addArrangedSubview(titleLabel)
        }
        stack.addArrangedSubview(previewLabel)
        stack.addArrangedSubview(preview)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 238))
        container.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            kindLabel.widthAnchor.constraint(equalTo: container.widthAnchor),
            preview.widthAnchor.constraint(equalTo: container.widthAnchor)
        ]
        if let titleLabel {
            constraints.append(titleLabel.widthAnchor.constraint(equalTo: container.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func cmuxSSHURLTextPreview(_ text: String, height: CGFloat) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.font = GlobalFontMagnification.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: height))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.heightAnchor.constraint(equalToConstant: height)
        ])
        return scrollView
    }

    private func showCmuxTextURLPasteFailure(_ request: CmuxTextURLRequest) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.kind == .prompt
            ? String(localized: "dialog.textURL.prompt.pasteFailed.title", defaultValue: "Couldn't Paste Prompt Link")
            : String(localized: "dialog.textURL.rules.pasteFailed.title", defaultValue: "Couldn't Paste Rules Link")
        alert.informativeText = String(
            localized: "dialog.textURL.pasteFailed.message",
            defaultValue: "cmux could not send the link text to a terminal."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private func showCmuxTextURLParseError(_ error: CmuxTextURLParseError) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "dialog.textURL.blocked.title",
            defaultValue: "cmux Link Blocked"
        )
        alert.informativeText = cmuxTextURLParseErrorMessage(error)
        alert.addButton(withTitle: String(localized: "dialog.textURL.blocked.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private func cmuxTextURLParseErrorMessage(_ error: CmuxTextURLParseError) -> String {
        switch error {
        case .missingText:
            return String(
                localized: "dialog.textURL.error.missingText",
                defaultValue: "The link did not include text."
            )
        case .textTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.textURL.error.textTooLong", defaultValue: "The link text is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .textContainsUnsafeCharacters:
            return String(
                localized: "dialog.textURL.error.textContainsUnsafeCharacters",
                defaultValue: "The link text contains unsupported or hidden characters, so cmux refused to use it."
            )
        case .nameTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.textURL.error.nameTooLong", defaultValue: "The link name is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .nameContainsUnsafeCharacters:
            return String(
                localized: "dialog.textURL.error.nameContainsUnsafeCharacters",
                defaultValue: "The link name contains hidden control or formatting characters, so cmux refused to use it."
            )
        case .titleTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.textURL.error.titleTooLong", defaultValue: "The link title is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .titleContainsUnsafeCharacters:
            return String(
                localized: "dialog.textURL.error.titleContainsUnsafeCharacters",
                defaultValue: "The link title contains hidden control or formatting characters, so cmux refused to use it."
            )
        case .invalidBooleanParameter(let parameter):
            return String(
                format: String(localized: "dialog.textURL.error.invalidBooleanParameter", defaultValue: "The link included an invalid boolean value for parameter: %@"),
                parameter
            )
        case .duplicateParameter(let parameter):
            return String(
                format: String(localized: "dialog.textURL.error.duplicateParameter", defaultValue: "The link repeated a parameter: %@"),
                parameter
            )
        case .unsupportedParameter(let parameter):
            return String(
                format: String(localized: "dialog.textURL.error.unsupportedParameter", defaultValue: "The link included an unsupported parameter: %@"),
                parameter
            )
        case .multipleLinks:
            return String(
                localized: "dialog.textURL.error.multipleLinks",
                defaultValue: "Only one cmux external link can be opened at a time."
            )
        }
    }
}
