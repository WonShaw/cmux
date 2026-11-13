import AppKit
import CmuxFoundation
import Foundation

extension AppDelegate {
    #if DEBUG
    /// Auth URL debug formatter extracted because `AppDelegate.swift` sits at
    /// its file-length budget.
    static func authURLDebugSummary(_ url: URL) -> String {
        let scheme = url.scheme ?? "nil"
        let target = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name).joined(separator: ",") ?? ""
        return "\(scheme):\(target.isEmpty ? "nil" : target):\(queryItems.isEmpty ? "none" : queryItems)"
    }
    #endif

    nonisolated static func shouldSaveSessionSnapshotOnRestoreCompletion(
        isManualReopen: Bool
    ) -> Bool {
        !isManualReopen
    }

    nonisolated static func shouldSkipSessionSaveDuringRestore(
        isApplyingSessionRestore: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isApplyingSessionRestore && !includeScrollback
    }

    /// Protects the previous launch snapshot until startup restoration has
    /// either completed or been explicitly cancelled.
    ///
    /// A pending signing-secret load can outlive autosave, window-close, and
    /// termination events. No persistence path may replace the authoritative
    /// startup snapshot during that interval.
    nonisolated static func shouldSkipSessionSaveDuringStartupTransition(
        isStartupSessionRestorePending: Bool,
        isApplyingSessionRestore: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isStartupSessionRestorePending
            || shouldSkipSessionSaveDuringRestore(
                isApplyingSessionRestore: isApplyingSessionRestore,
                includeScrollback: includeScrollback
            )
    }

    @discardableResult
    func handleCmuxNavigationURLRequest(_ request: CmuxNavigationURLRequest) -> Bool {
        let lookup = cmuxNavigationWorkspaceLookup()
        let resolver = CmuxNavigationTargetResolver(workspaces: lookup.descriptors)
        guard let resolution = resolver.resolve(request) else {
            if shouldDeferNavigationURLRequestsForStartupRestore {
                pendingStartupNavigationURLRequests.append(request)
#if DEBUG
                cmuxDebugLog(
                    "navigationURL.deferred reason=startupRestorePending " +
                    "url=\(request.originalURL.absoluteString.prefix(120))"
                )
#endif
                return true
            }
#if DEBUG
            switch request.target {
            case .workspace(let workspaceId):
                cmuxDebugLog("navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8))")
            case .pane(let workspaceId, let paneId):
                cmuxDebugLog(
                    "navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8)) " +
                    "pane=\(paneId.uuidString.prefix(8))"
                )
            case .surface(let workspaceId, let surfaceId):
                cmuxDebugLog(
                    "navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8)) " +
                    "surface=\(surfaceId.uuidString.prefix(8))"
                )
            }
#endif
            return false
        }

        let workspaceId = resolution.workspaceId
        guard let context = lookup.contextByWorkspaceId[workspaceId],
              let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceId }),
              let window = context.window ?? windowForMainWindowId(context.windowId) else {
            if shouldDeferNavigationURLRequestsForStartupRestore {
                pendingStartupNavigationURLRequests.append(request)
#if DEBUG
                cmuxDebugLog(
                    "navigationURL.deferred reason=windowPendingStartupRestore " +
                    "workspace=\(workspaceId.uuidString.prefix(8))"
                )
#endif
                return true
            }
#if DEBUG
            cmuxDebugLog("navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8))")
#endif
            return false
        }

        let targetPanelId: UUID?
        switch resolution {
        case .workspace:
            targetPanelId = nil
        case .pane(_, let paneId):
            guard let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
#if DEBUG
                cmuxDebugLog(
                    "navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8)) " +
                    "pane=\(paneId.uuidString.prefix(8))"
                )
#endif
                return false
            }
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: pane)
                ?? workspace.bonsplitController.tabs(inPane: pane).first
            targetPanelId = selectedTab.flatMap { workspace.panelIdFromSurfaceId($0.id) }
            if targetPanelId == nil {
                workspace.bonsplitController.focusPane(pane)
            }
        case .surface(_, let panelId):
            targetPanelId = panelId
        }

        prepareForExplicitOpenIntentAtStartup()
        setActiveMainWindow(window)
        _ = focusMainWindow(windowId: context.windowId)
        context.tabManager.focusTab(
            workspaceId,
            surfaceId: targetPanelId,
            suppressFlash: true
        )

#if DEBUG
        let surface = targetPanelId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        cmuxDebugLog(
            "navigationURL.focus workspace=\(workspaceId.uuidString.prefix(8)) " +
            "surface=\(surface) window=\(context.windowId.uuidString.prefix(8))"
        )
#endif
        return true
    }

    private func cmuxNavigationWorkspaceLookup() -> (
        descriptors: [CmuxNavigationTargetResolver.WorkspaceDescriptor],
        contextByWorkspaceId: [UUID: MainWindowContext]
    ) {
        var descriptors: [CmuxNavigationTargetResolver.WorkspaceDescriptor] = []
        var contextByWorkspaceId: [UUID: MainWindowContext] = [:]
        for context in mainWindowContexts.values.sorted(by: { $0.windowId.uuidString < $1.windowId.uuidString }) {
            for workspace in context.tabManager.tabs {
                descriptors.append(workspace.cmuxNavigationDescriptor)
                contextByWorkspaceId[workspace.id] = context
            }
        }
        return (descriptors, contextByWorkspaceId)
    }

    func cmuxNavigationWorkspaceDescriptors() -> [CmuxNavigationTargetResolver.WorkspaceDescriptor] {
        cmuxNavigationWorkspaceLookup().descriptors
    }

    var shouldDeferNavigationURLRequestsForStartupRestore: Bool {
        !didAttemptStartupSessionRestore || isApplyingSessionRestore
    }

    func liveWorkspaceIdentityTabManagers(preferredTabManager: TabManager? = nil) -> [TabManager] {
        var managers: [TabManager] = []
        var seen: Set<ObjectIdentifier> = []

        func append(_ manager: TabManager?) {
            guard let manager else { return }
            guard seen.insert(ObjectIdentifier(manager)).inserted else { return }
            managers.append(manager)
        }

        append(preferredTabManager)
        append(tabManager)
        for context in mainWindowContexts.values {
            append(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            append(route.tabManager)
        }
        return managers
    }

    func liveStableIdentitySet(preferredTabManager: TabManager? = nil) -> Set<UUID> {
        var identities: Set<UUID> = []
        for manager in liveWorkspaceIdentityTabManagers(preferredTabManager: preferredTabManager) {
            identities.formUnion(manager.liveStableIdentitySet())
        }
        return identities
    }

    func liveWorkspaceIdSet(preferredTabManager: TabManager? = nil) -> Set<UUID> {
        var identities: Set<UUID> = []
        for manager in liveWorkspaceIdentityTabManagers(preferredTabManager: preferredTabManager) {
            identities.formUnion(manager.liveWorkspaceIdSet())
        }
        return identities
    }

    func flushPendingStartupNavigationURLRequests() {
        guard !pendingStartupNavigationURLRequests.isEmpty else { return }
        let requests = pendingStartupNavigationURLRequests
        pendingStartupNavigationURLRequests.removeAll()
        for request in requests {
            _ = handleCmuxNavigationURLRequest(request)
        }
    }
}

/// The URL scheme this build registers for `cmux://` deep links (navigation,
/// text, and ssh links). Debug and channel builds use distinct schemes so they
/// can coexist with the installed stable app.
enum CmuxAppURLScheme {
    static var current: String {
        #if DEBUG
        return resolve(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            isDebugBuild: true
        )
        #else
        return resolve(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            isDebugBuild: false
        )
        #endif
    }

    static func resolve(
        environment: [String: String],
        bundleIdentifier: String?,
        isDebugBuild: Bool
    ) -> String {
        if let overridden = environment["CMUX_AUTH_CALLBACK_SCHEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return overridden
        }
        if isDebugBuild {
            if let tag = environment["CMUX_TAG"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !tag.isEmpty,
               let schemeTag = sanitizedSchemeTag(tag) {
                return "cmux-dev-\(schemeTag)"
            }
            return "cmux-dev"
        }
        if bundleIdentifier == "com.comux.app.nightly" { return "cmux-nightly" }
        if bundleIdentifier == "com.comux.app.rc" { return "cmux-rc" }
        return "comux"
    }

    static func sanitizedSchemeTag(_ rawTag: String) -> String? {
        let lowercased = rawTag.lowercased()
        var result = ""
        var previousWasHyphen = false
        for scalar in lowercased.unicodeScalars {
            let isAllowed = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if isAllowed {
                result.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                result.append("-")
                previousWasHyphen = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? nil : result
    }
}

/// Collects bounded stdout/stderr from a child process.
final class ProcessOutputCollector: @unchecked Sendable {
    private enum Stream {
        case stdout
        case stderr
    }

    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let lock = NSLock()
    private let byteLimit = 32 * 1024
    private var stdout = Data()
    private var stderr = Data()
    private var isFinished = false

    private let onOutput: ((Data) -> Void)?

    init(stdout: Pipe, stderr: Pipe, onOutput: ((Data) -> Void)? = nil) {
        stdoutHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading
        self.onOutput = onOutput
    }

    func start() {
        stdoutHandle.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.append(data, to: .stdout)
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.append(data, to: .stderr)
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
    }

    @discardableResult
    func finish() -> String {
        lock.lock()
        guard !isFinished else {
            let output = formattedOutputLocked()
            lock.unlock()
            return output
        }
        isFinished = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        append(stdoutHandle.readDataToEndOfFileOrEmpty(), to: .stdout)
        append(stderrHandle.readDataToEndOfFileOrEmpty(), to: .stderr)
        try? stdoutHandle.close()
        try? stderrHandle.close()

        lock.lock()
        let output = formattedOutputLocked()
        lock.unlock()
        return output
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    private func append(_ data: Data, to stream: Stream) {
        guard !data.isEmpty else { return }
        onOutput?(data)
        lock.lock()
        defer { lock.unlock() }

        switch stream {
        case .stdout:
            appendBounded(data, to: &stdout)
        case .stderr:
            appendBounded(data, to: &stderr)
        }
    }

    private func appendBounded(_ data: Data, to buffer: inout Data) {
        guard data.count < byteLimit else {
            buffer = Data(data.suffix(byteLimit))
            return
        }

        let overflow = buffer.count + data.count - byteLimit
        if overflow > 0 {
            buffer.removeSubrange(0..<overflow)
        }
        buffer.append(data)
    }

    private func formattedOutputLocked() -> String {
        let output = String(data: stdout, encoding: .utf8) ?? ""
        let error = String(data: stderr, encoding: .utf8) ?? ""
        return [output, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
