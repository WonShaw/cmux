import CmuxAppKitSupportUI
import CmuxFoundation
import Foundation
import CmuxCore
import CmuxWorkspaces
import CmuxTerminal
import CmuxTerminalCore
import SwiftUI
import AppKit
import CmuxFoundation
import Bonsplit
import CMUXAgentLaunch
import CmuxAgentChat
import CmuxSettings
import CmuxCanvasUI
import CmuxPanes
import CmuxSidebar
import CmuxNotifications
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

#if DEBUG
func debugWorkspaceDescriptionPreview(_ text: String?, limit: Int = 120) -> String {
    guard let text else { return "nil" }
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    if escaped.count <= limit {
        return escaped
    }
    return "\(escaped.prefix(limit))..."
}
#endif

private final class WorkspacePendingTerminalInputObserver: @unchecked Sendable {
    var observer: NSObjectProtocol?
}

private struct SessionPaneRestoreEntry {
    let paneId: PaneID
    let snapshot: SessionPaneLayoutSnapshot
}

extension Workspace {
    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil,
        downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable: Bool = false,
        currentAgentProcessIdentity: (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        },
        agentProcessPresence: (Int) -> PIDPresence = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return .absent }
            return PIDPresence.current(pid: pid_t($0))
        }
    ) -> SessionWorkspaceSnapshot {
        let layoutCodec = SessionSplitContainerLayoutCodec(controller: bonsplitController)
        let rawLayout = layoutCodec.snapshot(panelIdForTabId: { [self] in surfaceIdToPanelId[$0] })
        if let surfaceResumeBindingIndex {
            reconcileSurfaceResumeBindings(
                using: surfaceResumeBindingIndex,
                restorableAgentIndex: restorableAgentIndex
            )
        }
        let orderedPanelIds = sidebarOrderedPanelIds()
        var seen: Set<UUID> = []
        var allPanelIds: [UUID] = []
        for panelId in orderedPanelIds where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }
        let terminalFontSizeSnapshotProjection =
            terminalFontSizeChangeArbiter?.snapshotProjection(
                for: self,
                panelIds: Set(allPanelIds)
            )
        let panelSnapshots = allPanelIds
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { panelId in
                sessionPanelSnapshot(
                    panelId: panelId,
                    includeScrollback: includeScrollback,
                    restorableAgentObservation: restorableAgentIndex?.entryForStablePanel(
                        workspaceId: id,
                        panelId: panelId,
                        processIdentityProvider: currentAgentProcessIdentity,
                        processPresenceProvider: agentProcessPresence,
                        // Snapshot projection already consumes one index result;
                        // avoid synchronous sysctl/kill probes on the main actor
                        // while autosaving or closing a workspace.
                        revalidateProcessEvidence: false
                    ),
                    resumeBinding: effectiveSurfaceResumeBinding(
                        panelId: panelId,
                        surfaceResumeBindingIndex: surfaceResumeBindingIndex,
                        downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable:
                            downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable
                    ),
                    terminalFontSizeSnapshotProjection:
                        terminalFontSizeSnapshotProjection,
                    currentAgentProcessIdentity: currentAgentProcessIdentity,
                    agentProcessPresence: agentProcessPresence
                )
            }
        let persistedPanelIds = Set(panelSnapshots.map(\.id))
        let layout = layoutCodec.pruned(rawLayout, keeping: persistedPanelIds) ?? .pane(
            SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
        )
        let statusSnapshots = statusEntries.values
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { entry in
                SessionStatusEntrySnapshot(
                    key: entry.key,
                    value: entry.value,
                    icon: entry.icon,
                    color: entry.color,
                    timestamp: entry.timestamp.timeIntervalSince1970
                )
            }
        let logSnapshots = logEntries.map { entry in
            SessionLogEntrySnapshot(
                message: entry.message,
                level: entry.level.rawValue,
                source: entry.source,
                timestamp: entry.timestamp.timeIntervalSince1970
            )
        }
        let progressSnapshot = progress.map { progress in
            SessionProgressSnapshot(value: progress.value, label: progress.label)
        }
        let gitBranchSnapshot = gitBranch.map { branch in
            SessionGitBranchSnapshot(branch: branch.branch, isDirty: branch.isDirty)
        }
        let notificationStore = AppDelegate.shared?.notificationStore
        let isWorkspaceManuallyUnread = notificationStore?.hasManualUnread(forTabId: id) ?? false
        let hasWorkspaceUnreadIndicator =
            (notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: nil) ?? false) ||
            (notificationStore?.hasRestoredUnreadIndicator(forTabId: id) ?? false)
        let workspaceNotificationSnapshots = notificationSnapshots(surfaceId: nil)
        var snapshot = SessionWorkspaceSnapshot(
            workspaceId: id,
            stableId: stableId,
            taskCreateOperationID: taskCreateOperationID,
            processTitle: processTitle,
            customTitle: customTitle,
            customTitleSource: effectiveCustomTitleSource == .remote ? .user : effectiveCustomTitleSource,
            customTitleWasRemote: effectiveCustomTitleSource == .remote ? true : nil,
            customDescription: customDescription,
            customColor: customColor,
            isPinned: isPinned,
            isMuted: isMuted,
            groupId: groupId,
            isManuallyUnread: isWorkspaceManuallyUnread,
            hasUnreadIndicator: hasWorkspaceUnreadIndicator,
            notifications: workspaceNotificationSnapshots.isEmpty ? nil : workspaceNotificationSnapshots,
            currentDirectory: currentDirectory,
            focusedPanelId: focusedPanelId,
            layout: layout,
            layoutMode: layoutMode.rawValue,
            canvasPanes: canvasSessionPaneSnapshots(),
            panels: panelSnapshots,
            statusEntries: statusSnapshots,
            logEntries: logSnapshots,
            progress: progressSnapshot,
            gitBranch: gitBranchSnapshot,
            surfaceProjections: surfaceProjectionRecordsForSession,
            environment: workspaceEnvironment.isEmpty ? nil : workspaceEnvironment
        )
        snapshot.captureTodoState(from: self)
        snapshot.dock = _dockSplit?.sessionSnapshot(
            includeScrollback: includeScrollback,
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex,
            downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable:
                downgradeStoredProcessDetectedResumeBindingsWhenDetectionUnavailable
        )
        return snapshot
    }

    /// Rebuilds workspace state while keeping structured terminal restores
    /// behind the topology boundary selected by `startupRestoreCommitOwner`.
    @discardableResult
    func restoreSessionSnapshot(
        _ snapshot: SessionWorkspaceSnapshot,
        excludingStableIdentities: Set<UUID> = [],
        startupRestoreCommitOwner: WorkspaceTerminalStartupRestoreCommitOwner = .workspaceTopology
    ) -> [UUID: UUID] {
        sessionRestoreLayoutSuppressionDepth += 1
        defer {
            sessionRestoreLayoutSuppressionDepth = max(sessionRestoreLayoutSuppressionDepth - 1, 0)
            if sessionRestoreLayoutSuppressionDepth == 0,
               sessionRestoreLayoutFollowUpRequested {
                sessionRestoreLayoutFollowUpRequested = false
                scheduleFocusReconcile()
                beginEventDrivenLayoutFollowUp(
                    reason: "workspace.sessionRestore.complete",
                    includeGeometry: true
                )
            }
        }
        let previousSuppressClosedPanelHistory = suppressClosedPanelHistory
        suppressClosedPanelHistory = true
        defer { suppressClosedPanelHistory = previousSuppressClosedPanelHistory }
        sessionRestoreIdentityExclusions.beginRestore(excluding: excludingStableIdentities)
        defer { sessionRestoreIdentityExclusions.endRestore() }

        // Legacy snapshots keep the fresh id; duplicate reopens exclude live ids.
        if let persistedStableId = snapshot.stableId,
           sessionRestoreIdentityExclusions.shouldAdopt(persistedStableId) {
            stableId = persistedStableId
        }
        taskCreateOperationID = snapshot.taskCreateOperationID

        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.removeAll(keepingCapacity: false)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeAll(keepingCapacity: false)
#endif
        terminalStartupRestoreCoordinator.removeAllRestores()
        clearDeferredAgentResumeRestores(startRuntime: false)
        surfaceResumeBindingsByPanelId.removeAll(keepingCapacity: false)
        surfaceResumeRestoreClaimsByPanelId.removeAll(keepingCapacity: false)
        restoredGuardedWorkingDirectoriesByPanelId.removeAll(keepingCapacity: false)
        restoredPanelTitleBoundariesByPanelId.removeAll(keepingCapacity: false)
        panelShellActivityStates.removeAll(keepingCapacity: false)


        let normalizedCurrentDirectory = snapshot.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedCurrentDirectory.isEmpty {
            currentDirectory = normalizedCurrentDirectory
        }

        // Restore the per-workspace environment before any surface is rebuilt so
        // every restored terminal (all of which spawn fresh shells — PTYs do not
        // survive an app restart) inherits it through `newTerminalSurface`.
        workspaceEnvironment = Self.sanitizedWorkspaceEnvironment(snapshot.environment ?? [:])

        let panelSnapshotsById = Dictionary(uniqueKeysWithValues: snapshot.panels.map { ($0.id, $0) })
        let restorableAgentIndex = restoreAgentIndex(for: snapshot.panels)
        let leafEntries: [SessionPaneRestoreEntry] = restoreSessionLayout(snapshot.layout)
        var oldToNewPanelIds: [UUID: UUID] = [:]

        for entry in leafEntries {
            restorePane(
                entry.paneId,
                snapshot: entry.snapshot,
                panelSnapshotsById: panelSnapshotsById,
                snapshotWorkspaceId: snapshot.workspaceId,
                restorableAgentIndex: restorableAgentIndex,
                oldToNewPanelIds: &oldToNewPanelIds
            )
        }

        pruneSurfaceMetadata(validSurfaceIds: Set(panels.keys))
        SessionSplitContainerLayoutCodec(controller: bonsplitController).applyDividerPositions(
            snapshotNode: snapshot.layout,
            liveNode: bonsplitController.treeSnapshot()
        )

        restoreTitleState(from: snapshot, restoredPanelIds: oldToNewPanelIds)
        setCustomDescription(snapshot.customDescription)
        setCustomColor(snapshot.customColor)
        isPinned = snapshot.isPinned
        isMuted = snapshot.isMuted ?? false
        groupId = snapshot.groupId
        restoreTodoState(from: snapshot)

        // Status entries and agent PIDs are ephemeral runtime state tied to running
        // processes (e.g. claude_code "Running"). Don't restore them across app
        // restarts because the processes that set them are gone.
        statusEntries.removeAll()
        clearAllAgentPIDs(refreshPorts: false)
        clearAllAgentLifecycleStates()
        agentListeningPorts.removeAll()
        logEntries = snapshot.logEntries.map { entry in
            SidebarLogEntry(
                message: entry.message,
                level: SidebarLogLevel(rawValue: entry.level) ?? .info,
                source: entry.source,
                timestamp: Date(timeIntervalSince1970: entry.timestamp)
            )
        }
        progress = snapshot.progress.map { SidebarProgressState(value: $0.value, label: $0.label) }
        gitBranch = snapshot.gitBranch.map { SidebarGitBranchState(branch: $0.branch, isDirty: $0.isDirty) }

        recomputeListeningPorts()

        restoreCanvasState(from: snapshot, oldToNewPanelIds: oldToNewPanelIds)

        if let focusedOldPanelId = snapshot.focusedPanelId,
           let focusedNewPanelId = oldToNewPanelIds[focusedOldPanelId],
           panels[focusedNewPanelId] != nil {
            focusPanel(focusedNewPanelId)
        } else if let fallbackFocusedPanelId = focusedPanelId, panels[fallbackFocusedPanelId] != nil {
            focusPanel(fallbackFocusedPanelId)
        } else {
            scheduleFocusReconcile()
        }
        if !normalizedCurrentDirectory.isEmpty {
            currentDirectory = normalizedCurrentDirectory
        }
        if let focusedPanelId,
           remoteDirectoryTrustRequiredPanelIds.contains(focusedPanelId),
           !remoteDirectoryReportPanelIds.contains(focusedPanelId) {
            clearPanelGitBranch(panelId: focusedPanelId)
        }
        let isWorkspaceManuallyUnread = snapshot.isManuallyUnread == true
        restoreWorkspaceManualUnread(isWorkspaceManuallyUnread)
        let restoredNotifications = restoredSessionNotifications(
            from: snapshot,
            oldToNewPanelIds: oldToNewPanelIds
        )
        let hasUnreadWorkspaceNotification = snapshot.notifications?.contains { !$0.isRead } == true
        if snapshot.hasUnreadIndicator == true, !hasUnreadWorkspaceNotification {
            AppDelegate.shared?.notificationStore?.restoreUnreadIndicator(forTabId: id)
        } else {
            AppDelegate.shared?.notificationStore?.clearRestoredUnreadIndicator(forTabId: id)
        }
        AppDelegate.shared?.notificationStore?.restoreSessionNotifications(restoredNotifications, forTabId: id)
        // Record the identity remap for the agent journal: events journaled
        // against the previous run's runtime workspace/panel UUIDs re-attach
        // to the restored panels during replay through these aliases.
        AgentJournalLifecycleCenter.shared.noteRestoredIdentityAliases(
            oldWorkspaceId: snapshot.workspaceId,
            newWorkspaceId: id,
            oldToNewPanelIds: oldToNewPanelIds
        )
        syncUnreadBadgeStateForAllPanels()
        if startupRestoreCommitOwner == .workspaceTopology {
            terminalStartupRestoreCoordinator.commitPendingRestores()
        }
        restoreSurfaceProjections(snapshot.surfaceProjections, oldToNewPanelIds: oldToNewPanelIds)
        return oldToNewPanelIds
    }

    private func sessionPanelSnapshot(
        panelId: UUID,
        includeScrollback: Bool,
        restorableAgentObservation: RestorableAgentSessionIndex.Entry?,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        terminalFontSizeSnapshotProjection:
            WorkspaceTerminalFontSizeSnapshotProjection? = nil,
        currentAgentProcessIdentity: (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        },
        agentProcessPresence: (Int) -> PIDPresence = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return .absent }
            return PIDPresence.current(pid: pid_t($0))
        }
    ) -> SessionPanelSnapshot? {
        guard let panel = panels[panelId] else { return nil }

        let localTmuxStartCommand = (panel as? TerminalPanel).flatMap {
            sessionRestorePolicy.localTmuxStartCommand($0.surface.debugTmuxStartCommand())
        }
        let indexedRestorableAgent = restorableAgentObservation?.snapshot
        let compatibleIndexedRestorableAgent = indexedRestorableAgent.flatMap {
            localTmuxStartCommand == nil
                ? Self.restorableAgentForSessionRestore($0, resumeBinding: resumeBinding)
                : nil
        }
        let reconciledIndexedRestorableAgent = restoredAgentLifecycle
            .reconcileSnapshotWithQueuedRestoreIntent(
                panelId: panelId,
                proposedSnapshot: compatibleIndexedRestorableAgent
            )
        if indexedRestorableAgent != nil, reconciledIndexedRestorableAgent == nil {
            clearRestoredAgentSnapshot(panelId: panelId)
        }
        if let compatibleRestorableAgent = reconciledIndexedRestorableAgent,
           let matchingObservation = restorableAgentObservation?.matchingAgentSession(
               kind: compatibleRestorableAgent.kind.rawValue,
               sessionId: compatibleRestorableAgent.sessionId
           ) {
            reconcileCompletedRestoredAgent(
                panelId: panelId,
                observation: matchingObservation
            )
            if restoredAgentResumeStatesByPanelId[panelId] != .completedAgentExit {
                let fingerprint = TabManager.restorableAgentSnapshotFingerprint(compatibleRestorableAgent)
                if invalidatedRestoredAgentFingerprintsByPanelId[panelId] == fingerprint {
                    clearRestoredAgentSnapshot(panelId: panelId)
                } else {
                    restoredAgentLifecycle.setSnapshot(
                        compatibleRestorableAgent,
                        panelId: panelId
                    )
                    if restoredAgentResumeStatesByPanelId[panelId] == nil {
                        restoredAgentLifecycle.setResumeState(
                            restoredAgentResumeStateForAcceptedSnapshot(panelId: panelId),
                            panelId: panelId
                        )
                    }
                    invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
                }
            }
        }
        let hibernationState = (panel as? TerminalPanel)?.agentHibernationState
        let effectiveHibernationState = localTmuxStartCommand == nil
            ? hibernationState.flatMap { state in
                Self.restorableAgentForSessionRestore(
                    state.agent,
                    resumeBinding: resumeBinding
                ) == nil ? nil : state
            }
            : nil
        let restoredAgentCompleted = restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit
        let effectiveRestorableAgent = localTmuxStartCommand == nil && !restoredAgentCompleted
            ? Self.restorableAgentForSessionRestore(
                restoredAgentLifecycle.reconcileSnapshotWithQueuedRestoreIntent(
                    panelId: panelId,
                    proposedSnapshot: effectiveHibernationState?.agent
                        ?? restoredAgentSnapshotsByPanelId[panelId]
                ),
                resumeBinding: resumeBinding
            )
            : nil

        let panelTitle = panelTitle(panelId: panelId)
        let customTitle = panelCustomTitles[panelId]
        let customTitleSource: CustomTitleSource? = customTitle != nil
            ? (panelCustomTitleSources[panelId] ?? .user)
            : nil
        let directory: String? = {
            if let directory = panelDirectories[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !directory.isEmpty {
                return directory
            }
            if let agentPanel = panel as? AgentSessionPanel,
               let agentDirectory = agentPanel.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !agentDirectory.isEmpty {
                return agentDirectory
            }
            if let restorableDirectory = effectiveRestorableAgent?.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !restorableDirectory.isEmpty {
                return restorableDirectory
            }
            if let terminalPanel = panel as? TerminalPanel,
               let requestedDirectory = terminalPanel.requestedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !requestedDirectory.isEmpty {
                return requestedDirectory
            }
            return nil
        }()
        let isPinned = pinnedPanelIds.contains(panelId)
        let isManuallyUnread = manualUnreadPanelIds.contains(panelId)
        let panelNotificationSnapshots = notificationSnapshots(surfaceId: panelId)
        let panelHasUnreadNotification = hasUnreadNotification(panelId: panelId)
        let hasUnreadIndicator =
            restoredUnreadPanelIds.contains(panelId) ||
            hasVisibleNotificationIndicator(panelId: panelId)
        let restoredUnreadContributesToWorkspace: Bool? = {
            if let restoredIndicator = restoredUnreadPanelIndicators[panelId] {
                return restoredIndicator.contributesToWorkspaceUnread
            }
            if hasUnreadIndicator && !panelHasUnreadNotification {
                return false
            }
            return nil
        }()
        let branchSnapshot = panelGitBranches[panelId].map {
            SessionGitBranchSnapshot(branch: $0.branch, isDirty: $0.isDirty)
        }
        let listeningPorts = (surfaceListeningPorts[panelId] ?? []).sorted()
        let ttyName = surfaceTTYNames[panelId]
        let terminalSnapshot: SessionTerminalPanelSnapshot?
        let markdownSnapshot: SessionMarkdownPanelSnapshot?
        let filePreviewSnapshot: SessionFilePreviewPanelSnapshot?
        let rightSidebarToolSnapshot: SessionRightSidebarToolPanelSnapshot?; var customSidebarSnapshot: SessionCustomSidebarPanelSnapshot? = nil
        var simulatorSnapshot: SessionSimulatorPanelSnapshot? = nil
        let agentSessionSnapshot: SessionAgentSessionPanelSnapshot?
        let projectSnapshot: SessionProjectPanelSnapshot?; var workspaceTodoSnapshot: SessionWorkspaceTodoPanelSnapshot? = nil
        var notificationsPanelSnapshot: SessionNotificationsPanelSnapshot? = nil
        switch panel.panelType {
        case .terminal:
            guard let terminalPanel = panel as? TerminalPanel else { return nil }
            let restorableTmuxStartCommand = localTmuxStartCommand
                ?? (effectiveRestorableAgent == nil
                    ? sessionRestorePolicy.restorableTmuxStartCommand(terminalPanel.surface.debugTmuxStartCommand())
                    : nil)
            let agentWasRunning: Bool? = {
                // A queued cmux-authored selector is durable intent before any
                // process can exist. Once shell activity starts, the ordinary
                // binding and process evidence below becomes authoritative.
                if restoredAgentLifecycle.hasQueuedRestoreIntent(
                    panelId: panelId,
                    matching: effectiveRestorableAgent
                ) {
                    return true
                }
                if let resumeBinding, resumeBinding.isAgentHookBinding {
                    guard let bindingKindValue = Self.normalizedResumeBindingValue(resumeBinding.kind),
                          let bindingKind = RestorableAgentKind(
                              persistedRawValue: bindingKindValue,
                              registration: effectiveRestorableAgent?.registration
                                  ?? restorableAgentObservation?.snapshot.registration
                          ),
                          let bindingSessionId = Self.normalizedResumeBindingValue(resumeBinding.checkpointId) else {
                        return false
                    }
                    if restoredAgentLifecycleConfirmsRunning(resumeBinding, panelId: panelId) {
                        return true
                    }
                    let confirmedRuntimeProcessIdentities = confirmedRuntimeAgentProcessIdentities(
                        kind: bindingKind,
                        sessionId: bindingSessionId,
                        panelId: panelId,
                        currentProcessIdentity: currentAgentProcessIdentity
                    )
                    if !confirmedRuntimeProcessIdentities.isEmpty {
                        return true
                    }
                    let matchingObservation = restorableAgentObservation?.matchingAgentSession(
                        kind: bindingKind.rawValue,
                        sessionId: bindingSessionId
                    )
                    guard let effectiveRestorableAgent,
                          effectiveRestorableAgent.kind.rawValue == bindingKind.rawValue,
                          ManagedAgentSessionIdentity.sessionIDsMatch(
                              kind: bindingKind.rawValue,
                              lhs: effectiveRestorableAgent.sessionId,
                              rhs: bindingSessionId
                          ),
                          let matchingObservation else {
                        return false
                    }
                    return matchingObservation.processLiveness
                        .wasRunning(
                            fallingBackTo: panelShellActivityStates[panelId],
                            recordedProcessIdentities: matchingObservation.agentProcessIdentities,
                            confirmedRuntimeProcessIdentities: confirmedRuntimeProcessIdentities,
                            currentProcessIdentity: currentAgentProcessIdentity,
                            processPresence: agentProcessPresence
                        ) ?? false
                }
                guard let effectiveRestorableAgent else { return nil }
                let confirmedRuntimeProcessIdentities = confirmedRuntimeAgentProcessIdentities(
                    for: effectiveRestorableAgent,
                    panelId: panelId,
                    currentProcessIdentity: currentAgentProcessIdentity
                )
                let matchingObservation = restorableAgentObservation?.matchingAgentSession(
                    kind: effectiveRestorableAgent.kind.rawValue,
                    sessionId: effectiveRestorableAgent.sessionId
                )
                return (matchingObservation?.processLiveness ?? .unknown)
                    .wasRunning(
                        fallingBackTo: panelShellActivityStates[panelId],
                        recordedProcessIdentities: matchingObservation?.agentProcessIdentities ?? [:],
                        confirmedRuntimeProcessIdentities: confirmedRuntimeProcessIdentities,
                        currentProcessIdentity: currentAgentProcessIdentity,
                        processPresence: agentProcessPresence
                    )
            }()
            let resumeStartupInput = localTmuxStartCommand == nil
                ? sessionRestorePolicy.surfaceResumeStartupInput(
                    resumeBinding,
                    autoResumeAgentSessions: AgentSessionAutoResumeSettings.isEnabled(defaults: agentSessionAutoResumeDefaults) && (agentWasRunning ?? true),
                    promptForApproval: false,
                    approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
                )
                : nil
            let closeConfirmationRequired = Self.resolveCloseConfirmation(
                shellActivityState: panelShellActivityStates[panelId],
                fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()
            )
            let shouldPersistScrollback = sessionRestorePolicy.shouldPersistSessionScrollback(
                closeConfirmationRequired: closeConfirmationRequired
            ) && sessionRestorePolicy.shouldReplaySessionScrollback(
                hasRestorableAgent: effectiveRestorableAgent != nil,
                tmuxStartCommand: restorableTmuxStartCommand,
                hasResumeStartupWork: resumeStartupInput != nil
            )
#if DEBUG
            let allowDebugFallbackScrollback = debugSessionSnapshotScrollbackFallbackPanelIds.contains(panelId)
#else
            let allowDebugFallbackScrollback = false
#endif
            let capturedScrollback = includeScrollback && shouldPersistScrollback && effectiveHibernationState == nil
                ? TerminalController.shared.readTerminalTextForSnapshot(
                    terminalPanel: terminalPanel,
                    includeScrollback: true,
                    lineLimit: SessionPersistencePolicy.maxScrollbackLinesPerTerminal
                )
                : nil
            let hasRestoredScrollbackFallback = restoredTerminalScrollbackByPanelId[panelId] != nil
            let resolvedScrollback = terminalSnapshotScrollback(
                panelId: panelId,
                capturedScrollback: capturedScrollback,
                includeScrollback: includeScrollback,
                allowFallbackScrollback: shouldPersistScrollback || allowDebugFallbackScrollback || hasRestoredScrollbackFallback
            )
            let sessionFontSize: Float32?
            let sessionFontSizeChangeTokens: [UUID]?
            if let terminalFontSizeSnapshotProjection {
                let projection =
                    terminalFontSizeSnapshotProjection
                        .sessionProjection(
                            for: terminalPanel
                        )
                sessionFontSize = projection.overrideBasePoints
                sessionFontSizeChangeTokens =
                    projection.persistedRepresentedRequestTokens
            } else {
                sessionFontSize =
                    terminalPanel.surface
                        .sessionFontSizeOverrideBasePoints()
                sessionFontSizeChangeTokens = nil
            }
            terminalSnapshot = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                fontSize: sessionFontSize,
                fontSizeChangeTokens: sessionFontSizeChangeTokens,
                scrollback: resolvedScrollback,
                agent: effectiveRestorableAgent,
                tmuxStartCommand: restorableTmuxStartCommand,
                hibernation: localTmuxStartCommand == nil ? effectiveHibernationState.map {
                    SessionAgentHibernationSnapshot(
                        hibernatedAt: $0.hibernatedAt.timeIntervalSince1970,
                        lastActivityAt: $0.lastActivityAt.timeIntervalSince1970
                    )
                } : nil,
                resumeBinding: localTmuxStartCommand == nil ? resumeBinding : nil,
                textBoxDraft: terminalPanel.sessionTextBoxDraftSnapshot(),
                wasAgentRunning: localTmuxStartCommand == nil ? agentWasRunning : nil
            )
            markdownSnapshot = nil
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil
            agentSessionSnapshot = nil
            projectSnapshot = nil
        case .markdown:
            guard let markdownPanel = panel as? MarkdownPanel else { return nil }
            terminalSnapshot = nil
            markdownSnapshot = SessionMarkdownPanelSnapshot(filePath: markdownPanel.filePath)
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil
            agentSessionSnapshot = nil
            projectSnapshot = nil
        case .filePreview:
            guard let filePreviewPanel = panel as? FilePreviewPanel else { return nil }
            terminalSnapshot = nil
            markdownSnapshot = nil
            filePreviewSnapshot = SessionFilePreviewPanelSnapshot(filePath: filePreviewPanel.filePath)
            rightSidebarToolSnapshot = nil
            agentSessionSnapshot = nil
            projectSnapshot = nil
        case .rightSidebarTool:
            guard let toolPanel = panel as? RightSidebarToolPanel else { return nil }
            terminalSnapshot = nil
            markdownSnapshot = nil
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = SessionRightSidebarToolPanelSnapshot(mode: toolPanel.mode)
            agentSessionSnapshot = nil
            projectSnapshot = nil
        case .customSidebar:
            guard let snapshot = customSidebarSessionSnapshot(for: panel) else { return nil }
            terminalSnapshot = nil; markdownSnapshot = nil; filePreviewSnapshot = nil; rightSidebarToolSnapshot = nil
            customSidebarSnapshot = snapshot; agentSessionSnapshot = nil; projectSnapshot = nil
        case .simulator:
            guard let snapshot = simulatorSessionSnapshot(for: panel) else { return nil }
            terminalSnapshot = nil; markdownSnapshot = nil; filePreviewSnapshot = nil; rightSidebarToolSnapshot = nil
            simulatorSnapshot = snapshot; agentSessionSnapshot = nil; projectSnapshot = nil
        case .agentSession:
            guard let agentPanel = panel as? AgentSessionPanel else { return nil }
            terminalSnapshot = nil
            markdownSnapshot = nil
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil
            agentSessionSnapshot = SessionAgentSessionPanelSnapshot(
                rendererKind: agentPanel.rendererKind,
                providerID: agentPanel.currentProviderID,
                workingDirectory: directory
            )
            projectSnapshot = nil
        case .project:
            guard let projectPanel = panel as? ProjectPanel else { return nil }
            terminalSnapshot = nil
            markdownSnapshot = nil
            filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil
            projectSnapshot = SessionProjectPanelSnapshot(
                projectPath: projectPanel.projectURL.path,
                selectedNodePath: projectPanel.selectedFilePath,
                activeTab: projectPanel.activeTab.rawValue,
                selectedSchemeName: projectPanel.selectedSchemeName,
                selectedConfigurationName: projectPanel.selectedConfigurationName
            )
            agentSessionSnapshot = nil
        case .workspaceTodo:
            terminalSnapshot = nil; markdownSnapshot = nil; filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil; agentSessionSnapshot = nil; projectSnapshot = nil
            workspaceTodoSnapshot = SessionWorkspaceTodoPanelSnapshot()
        case .notifications:
            terminalSnapshot = nil; markdownSnapshot = nil; filePreviewSnapshot = nil
            rightSidebarToolSnapshot = nil; agentSessionSnapshot = nil; projectSnapshot = nil
            notificationsPanelSnapshot = SessionNotificationsPanelSnapshot()
            return nil
        }
        return SessionPanelSnapshot(
            id: panelId,
            stableSurfaceId: panel.stableSurfaceId,
            type: panel.panelType,
            title: panelTitle,
            customTitle: customTitle,
            customTitleSource: customTitleSource == .remote ? .user : customTitleSource,
            customTitleWasRemote: customTitleSource == .remote ? true : nil,
            directory: directory,
            isPinned: isPinned,
            isManuallyUnread: isManuallyUnread,
            hasUnreadIndicator: hasUnreadIndicator,
            restoredUnreadContributesToWorkspace: restoredUnreadContributesToWorkspace,
            notifications: panelNotificationSnapshots.isEmpty ? nil : panelNotificationSnapshots,
            gitBranch: branchSnapshot,
            listeningPorts: listeningPorts,
            ttyName: ttyName,
            terminal: terminalSnapshot,
            markdown: markdownSnapshot,
            filePreview: filePreviewSnapshot,
            rightSidebarTool: rightSidebarToolSnapshot,
            customSidebar: customSidebarSnapshot,
            simulator: simulatorSnapshot,
            agentSession: agentSessionSnapshot,
            project: projectSnapshot,
            workspaceTodo: workspaceTodoSnapshot,
            notificationsPanel: notificationsPanelSnapshot
        )
    }
    private func closedPanelHistoryEntry(panelId: UUID, tabId: TabID, pane: PaneID) -> ClosedPanelHistoryEntry? {
        guard !suppressClosedPanelHistory else { return nil }
        owningTabManager?.flushPendingPanelTitleUpdatesForWorkspaceSnapshot()
        guard let tabIndex = bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == tabId }) else {
            return nil
        }
        let paneTabs = bonsplitController.tabs(inPane: pane)
        let paneAnchorPanelId: UUID? = {
            if tabIndex + 1 < paneTabs.count {
                return panelIdFromSurfaceId(paneTabs[tabIndex + 1].id)
            }
            if tabIndex > 0 {
                return panelIdFromSurfaceId(paneTabs[tabIndex - 1].id)
            }
            return nil
        }()
        let fallbackPlan = browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString,
            in: bonsplitController.treeSnapshot()
        )
        let fallbackAnchorPanelId = fallbackPlan?.anchorPaneId.flatMap { anchorPaneId -> UUID? in
            guard let anchorPane = bonsplitController.allPaneIds.first(where: { $0.id == anchorPaneId }),
                  let anchorTab = bonsplitController.selectedTab(inPane: anchorPane)
                    ?? bonsplitController.tabs(inPane: anchorPane).first else {
                return nil
            }
            return panelIdFromSurfaceId(anchorTab.id)
        }
        let fallbackSplitPlacement = fallbackPlan.map {
            ClosedPanelSplitPlacement(
                orientation: $0.orientation,
                insertFirst: $0.insertFirst,
                anchorPanelId: fallbackAnchorPanelId
            )
        }
        // Prefer the warm cached agent index over a synchronous `RestorableAgentSessionIndex.load()`
        // (sysctl-per-record + disk, ~350ms-1.8s on machines with large agent history) so closing a
        // tab does not freeze the main thread. Fall back to a fresh load only when the cache has not
        // loaded yet (the brief window after launch before the first refresh completes; the cache is
        // prewarmed at launch so this is rare). The snapshot path revalidates cached `.running`
        // evidence against the recorded process generation before it lets the always-fresh in-memory
        // resume binding auto-launch, so an exited generation cannot be revived from this warm cache.
        let agentIndex = SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
            ?? RestorableAgentSessionIndex.load()
        let restorableAgentObservation = agentIndex.entry(workspaceId: id, panelId: panelId)
        let terminalFontSizeSnapshotProjection =
            terminalFontSizeChangeArbiter?.snapshotProjection(
                for: self,
                panelIds: [panelId]
            )
        guard let snapshot = sessionPanelSnapshot(
            panelId: panelId,
            includeScrollback: true,
            restorableAgentObservation: restorableAgentObservation,
            resumeBinding: effectiveSurfaceResumeBinding(
                panelId: panelId,
                surfaceResumeBindingIndex: nil
            ),
            terminalFontSizeSnapshotProjection:
                terminalFontSizeSnapshotProjection
        ) else {
            return nil
        }
        return ClosedPanelHistoryEntry(
            workspaceId: id,
            paneId: pane.id,
            paneAnchorPanelId: paneAnchorPanelId,
            tabIndex: tabIndex,
            snapshot: snapshot,
            fallbackSplitPlacement: fallbackSplitPlacement
        )
    }

    private func consumeCloseHistoryEligibility(tabId: TabID, panelId: UUID?) -> Bool {
        let eligibleByTab = closeHistoryEligibleTabIds.remove(tabId) != nil
        let eligibleByPanel = panelId.map { closeHistoryEligiblePanelIds.remove($0) != nil } ?? false
        return eligibleByTab || eligibleByPanel
    }

    private func clearCloseHistoryEligibility(tabId: TabID, panelId: UUID? = nil) {
        closeHistoryEligibleTabIds.remove(tabId)
        let resolvedPanelId = panelId ?? panelIdFromSurfaceId(tabId)
        if let resolvedPanelId {
            closeHistoryEligiblePanelIds.remove(resolvedPanelId)
        }
    }

    @discardableResult
    private func pushClosedPanelHistoryIfEligible(for tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        guard !suppressClosedPanelHistory else { return false }
        guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
        guard consumeCloseHistoryEligibility(tabId: tab.id, panelId: panelId) else { return false }
        guard let entry = closedPanelHistoryEntry(panelId: panelId, tabId: tab.id, pane: pane) else {
            return false
        }
        ClosedItemHistoryStore.shared.push(.panel(entry))
        return true
    }

    @discardableResult
    func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry) -> UUID? {
        if entry.restoreInOriginalPane,
           let originalPane = bonsplitController.allPaneIds.first(where: { $0.id == entry.paneId }) {
            return restoreClosedPanel(entry, inPane: originalPane)
        }
        if let paneAnchorPanelId = entry.paneAnchorPanelId,
           let pane = paneId(forPanelId: paneAnchorPanelId) {
            return restoreClosedPanel(entry, inPane: pane)
        }
        if let splitPanelId = restoreClosedPanelInFallbackSplit(entry) {
            triggerFocusFlash(panelId: splitPanelId)
            return splitPanelId
        }
        guard let pane = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else {
            return nil
        }
        return restoreClosedPanel(entry, inPane: pane)
    }

    @discardableResult
    private func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry, inPane pane: PaneID) -> UUID? {
        guard let panelId = createPanel(
            from: entry.snapshot,
            inPane: pane,
            snapshotWorkspaceId: nil,
            restorableAgentIndex: restoreAgentIndex(for: [entry.snapshot])
        ) else { return nil }
        let maxIndex = max(0, bonsplitController.tabs(inPane: pane).count - 1)
        _ = reorderSurface(panelId: panelId, toIndex: min(max(entry.tabIndex, 0), maxIndex))
        if let tabId = surfaceIdFromPanelId(panelId) {
            bonsplitController.focusPane(pane)
            bonsplitController.selectTab(tabId)
        }
        focusPanel(panelId)
        triggerFocusFlash(panelId: panelId)
        terminalStartupRestoreCoordinator.commitPendingRestores(panelIDs: [panelId])
        return panelId
    }

    @discardableResult
    private func restoreClosedPanelInFallbackSplit(_ entry: ClosedPanelHistoryEntry) -> UUID? {
        guard let placement = entry.fallbackSplitPlacement,
              let anchorPanelId = placement.anchorPanelId,
              panels[anchorPanelId] != nil else {
            return nil
        }

        guard let placeholderPanel = newTerminalSplit(
            from: anchorPanelId,
            orientation: placement.orientation,
            insertFirst: placement.insertFirst,
            focus: false
        ) else {
            return nil
        }
        guard let pane = paneId(forPanelId: placeholderPanel.id) else {
            _ = closePanel(placeholderPanel.id, force: true)
            return nil
        }

        guard let panelId = createPanel(
            from: entry.snapshot,
            inPane: pane,
            snapshotWorkspaceId: nil,
            restorableAgentIndex: restoreAgentIndex(for: [entry.snapshot])
        ) else {
            _ = closePanel(placeholderPanel.id, force: true)
            return nil
        }

        _ = closePanel(placeholderPanel.id, force: true)
        guard panels[panelId] != nil else {
            return nil
        }
        focusPanel(panelId)
        terminalStartupRestoreCoordinator.commitPendingRestores(panelIDs: [panelId])
        return panelId
    }

    nonisolated static func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        makeSessionRestorePolicyService().resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallbackScrollback,
            allowFallbackScrollback: allowFallbackScrollback
        )
    }

    nonisolated static func shouldReplaySessionScrollback(
        restorableAgent: SessionRestorableAgentSnapshot?,
        tmuxStartCommand: String? = nil,
        hasResumeStartupWork: Bool = false
    ) -> Bool {
        makeSessionRestorePolicyService().shouldReplaySessionScrollback(
            hasRestorableAgent: restorableAgent != nil,
            tmuxStartCommand: tmuxStartCommand,
            hasResumeStartupWork: hasResumeStartupWork
        )
    }

    nonisolated static func surfaceResumeStartupInput(
        _ resumeBinding: SurfaceResumeBindingSnapshot?,
        autoResumeAgentSessions: Bool,
        promptForApproval: Bool = true,
        approvalStoreURL: URL = SurfaceResumeApprovalStore.defaultURL(),
        approvalSigningSecret: Data? = nil
    ) -> String? {
        makeSessionRestorePolicyService().surfaceResumeStartupInput(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret
        )
    }

    nonisolated static func surfaceResumeStartupLaunch(
        _ resumeBinding: SurfaceResumeBindingSnapshot?,
        autoResumeAgentSessions: Bool,
        promptForApproval: Bool = true,
        approvalStoreURL: URL = SurfaceResumeApprovalStore.defaultURL(),
        approvalSigningSecret: Data? = nil
    ) -> SurfaceResumeStartupLaunch? {
        makeSessionRestorePolicyService().surfaceResumeStartupLaunch(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret
        )
    }

    nonisolated static func resumeBindingForSessionRestore(
        _ binding: SurfaceResumeBindingSnapshot?,
        restorableAgent: SessionRestorableAgentSnapshot?
    ) -> SurfaceResumeBindingSnapshot? {
        guard let binding, binding.isAgentHookBinding, let restorableAgent else {
            return binding
        }
        guard let checkpointId = normalizedResumeBindingValue(binding.checkpointId),
              ManagedAgentSessionIdentity.sessionIDsMatch(
                  kind: restorableAgent.kind.rawValue,
                  lhs: checkpointId,
                  rhs: restorableAgent.sessionId
              ) else {
            return binding
        }
        if let bindingKind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bindingKind.isEmpty,
           RestorableAgentKind(
               persistedRawValue: bindingKind,
               registration: restorableAgent.registration
           )?.rawValue != restorableAgent.kind.rawValue {
            return binding
        }

        // Restore has no live hook cwd; use the snapshot's derived restorable cwd
        // and fall back to launch capture only for older snapshots.
        let snapshotRestorableWorkingDirectory =
            restorableAgent.workingDirectory ?? restorableAgent.launchCommand?.workingDirectory
        let resolvedWorkingDirectory = AgentResumeWorkingDirectory().resolve(
            kind: binding.kind ?? restorableAgent.kind.rawValue,
            runtimeCwd: binding.cwd,
            launchWorkingDirectory: snapshotRestorableWorkingDirectory
        )
        guard resolvedWorkingDirectory != binding.cwd else {
            return binding
        }
        return binding.retargetingWorkingDirectory(resolvedWorkingDirectory)
    }

    nonisolated static func restorableAgentForSessionRestore(
        _ restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?
    ) -> SessionRestorableAgentSnapshot? {
        guard let restorableAgent else { return nil }
        guard let resumeBinding, resumeBinding.isAgentHookBinding else {
            return restorableAgent
        }

        if let checkpointId = normalizedResumeBindingValue(resumeBinding.checkpointId),
           !ManagedAgentSessionIdentity.sessionIDsMatch(
               kind: restorableAgent.kind.rawValue,
               lhs: checkpointId,
               rhs: restorableAgent.sessionId
           ) {
            return nil
        }
        if let kindValue = normalizedResumeBindingValue(resumeBinding.kind) {
            guard let bindingKind = RestorableAgentKind(
                persistedRawValue: kindValue,
                registration: restorableAgent.registration
            ),
                  bindingKind.rawValue == restorableAgent.kind.rawValue else {
                return nil
            }
        }
        return restorableAgent
    }

    nonisolated private static func normalizedResumeBindingValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    nonisolated static func restorableTmuxStartCommand(_ rawCommand: String?) -> String? {
        makeSessionRestorePolicyService().restorableTmuxStartCommand(rawCommand)
    }

    nonisolated static func shouldPersistSessionScrollback(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        makeSessionRestorePolicyService().shouldPersistSessionScrollback(
            closeConfirmationRequired: resolveCloseConfirmation(
                shellActivityState: shellActivityState,
                fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
            )
        )
    }

    private func terminalSnapshotScrollback(
        panelId: UUID,
        capturedScrollback: String?,
        includeScrollback: Bool,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        guard includeScrollback else { return nil }
#if DEBUG
        let debugFallback = debugSessionSnapshotScrollbackFallbackPanelIds.contains(panelId)
            ? debugSessionSnapshotSyntheticScrollbackByPanelId[panelId]
            : nil
#else
        let debugFallback: String? = nil
#endif
        let fallback = allowFallbackScrollback
            ? (debugFallback ?? restoredTerminalScrollbackByPanelId[panelId])
            : nil
        let resolved = sessionRestorePolicy.resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallback,
            allowFallbackScrollback: allowFallbackScrollback
        )
#if DEBUG
        if debugFallback != nil {
            debugSessionSnapshotScrollbackFallbackPanelIds.remove(panelId)
            debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
            return resolved
        }
#endif
        if let resolved {
            restoredTerminalScrollbackByPanelId[panelId] = resolved
        } else {
            restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        }
        return resolved
    }

#if DEBUG
    func debugSeedSessionSnapshotScrollback(charactersPerTerminal: Int) -> (terminals: Int, characters: Int) {
        for panelId in debugSessionSnapshotScrollbackFallbackPanelIds {
            debugSessionSnapshotSyntheticScrollbackByPanelId.removeValue(forKey: panelId)
        }
        debugSessionSnapshotScrollbackFallbackPanelIds.removeAll(keepingCapacity: false)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeAll(keepingCapacity: false)

        let targetCharacters = min(
            max(0, charactersPerTerminal),
            SessionPersistencePolicy.maxScrollbackCharactersPerTerminal
        )
        guard targetCharacters > 0 else { return (0, 0) }

        var terminalCount = 0
        var totalCharacters = 0
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard panels[panelId] is TerminalPanel else { continue }
            let header = "cmux perf synthetic scrollback workspace=\(id.uuidString) panel=\(panelId.uuidString)\n"
            let paddingCount = max(0, targetCharacters - header.count)
            let scrollback = String((header + String(repeating: "s", count: paddingCount)).prefix(targetCharacters))
            debugSessionSnapshotSyntheticScrollbackByPanelId[panelId] = scrollback
            debugSessionSnapshotScrollbackFallbackPanelIds.insert(panelId)
            terminalCount += 1
            totalCharacters += scrollback.count
        }
        return (terminalCount, totalCharacters)
    }
#endif

    private func restoreSessionLayout(_ layout: SessionWorkspaceLayoutSnapshot) -> [SessionPaneRestoreEntry] {
        guard let rootPaneId = bonsplitController.allPaneIds.first else {
            return []
        }

        var leaves: [SessionPaneRestoreEntry] = []
        restoreSessionLayoutNode(layout, inPane: rootPaneId, leaves: &leaves)
        return leaves
    }

    private func restoreSessionLayoutNode(
        _ node: SessionWorkspaceLayoutSnapshot,
        inPane paneId: PaneID,
        leaves: inout [SessionPaneRestoreEntry]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append(SessionPaneRestoreEntry(paneId: paneId, snapshot: pane))
        case .split(let split):
            var anchorPanelId = bonsplitController
                .tabs(inPane: paneId)
                .compactMap { panelIdFromSurfaceId($0.id) }
                .first

            if anchorPanelId == nil {
                anchorPanelId = newTerminalSurface(inPane: paneId, focus: false)?.id
            }

            guard let anchorPanelId,
                  let newSplitPanel = newTerminalSplit(
                    from: anchorPanelId,
                    orientation: split.orientation.splitOrientation,
                    insertFirst: false,
                    focus: false
                  ),
                  let secondPaneId = self.paneId(forPanelId: newSplitPanel.id) else {
                leaves.append(
                    SessionPaneRestoreEntry(
                        paneId: paneId,
                        snapshot: SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
                    )
                )
                return
            }

            restoreSessionLayoutNode(split.first, inPane: paneId, leaves: &leaves)
            restoreSessionLayoutNode(split.second, inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func restoreAgentIndex(
        for panels: [SessionPanelSnapshot]
    ) -> RestorableAgentSessionIndex? {
        // Load at most once for this restore pass; every panel reuses the same snapshot.
        guard AgentSessionAutoResumeSettings.isEnabled(
            defaults: agentSessionAutoResumeDefaults
        ), panels.contains(where: { panel in
            panel.terminal?.agent != nil || panel.terminal?.resumeBinding?.isAgentHookBinding == true
        }) else {
            return nil
        }
        // Ownership-sensitive restore decisions use an injected authoritative
        // index, or request a fresh off-main scan and defer launch otherwise.
        return restorableAgentIndexProvider()
    }

    private func restorePane(
        _ paneId: PaneID,
        snapshot: SessionPaneLayoutSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot],
        snapshotWorkspaceId: UUID?,
        restorableAgentIndex: RestorableAgentSessionIndex?,
        oldToNewPanelIds: inout [UUID: UUID]
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }
        let desiredOldPanelIds = snapshot.panelIds.filter { panelSnapshotsById[$0] != nil }
        _ = bonsplitController.setFullWidthTabMode(false, inPane: paneId)

        var createdPanelIds: [UUID] = []
        for oldPanelId in desiredOldPanelIds {
            guard let panelSnapshot = panelSnapshotsById[oldPanelId] else { continue }
            guard let createdPanelId = createPanel(
                from: panelSnapshot,
                inPane: paneId,
                snapshotWorkspaceId: snapshotWorkspaceId,
                restorableAgentIndex: restorableAgentIndex
            ) else { continue }
            createdPanelIds.append(createdPanelId)
            oldToNewPanelIds[oldPanelId] = createdPanelId
        }

        guard !createdPanelIds.isEmpty else { return }

        for oldPanelId in existingPanelIds where !createdPanelIds.contains(oldPanelId) {
            _ = closePanel(oldPanelId, force: true)
        }

        for (index, panelId) in createdPanelIds.enumerated() {
            _ = reorderSurface(panelId: panelId, toIndex: index)
        }

        let selectedPanelId: UUID? = {
            if let selectedOldId = snapshot.selectedPanelId {
                return oldToNewPanelIds[selectedOldId]
            }
            return createdPanelIds.first
        }()

        if let selectedPanelId,
           let selectedTabId = surfaceIdFromPanelId(selectedPanelId) {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(selectedTabId)
        }

        if snapshot.isFullWidthTabMode == true {
            _ = bonsplitController.setFullWidthTabMode(true, inPane: paneId)
        }
    }

    func reconcileSurfaceResumeBindings(
        using surfaceResumeBindingIndex: SurfaceResumeBindingIndex,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil
    ) {
        for panelId in panels.keys {
            let storedBinding = surfaceResumeBindingsByPanelId[panelId]
            let detectedBinding = surfaceResumeBindingIndex.binding(workspaceId: id, panelId: panelId)
            if surfaceResumeBindingIndex.hasAmbiguousPanel(panelId), detectedBinding == nil {
                // A missing panel-only winner is uncertainty, not proof that a
                // process-backed binding exited; preserve the existing binding.
                continue
            }


            guard let storedBinding else {
                if let detectedBinding, detectedBinding.isProcessDetected {
                    guard surfaceResumeBindingMutationAllowed(
                        detectedBinding,
                        panelId: panelId
                    ) else {
                        continue
                    }
                    surfaceResumeBindingsByPanelId[panelId] = detectedBinding
                }
                continue
            }
            guard let detectedBinding else {
                if storedBinding.isProcessDetected {
                    guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                        continue
                    }
                    surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
                } else if isStaleAgentHookBinding(
                    storedBinding,
                    panelId: panelId,
                    restorableAgentIndex: restorableAgentIndex
                ) {
                    // Preserve explicit restore for the exited session, but
                    // prevent the stale binding from replaying automatically
                    // on the next relaunch (#8446).
                    retireAgentHookResumeBinding(panelId: panelId)
                }
                continue
            }
            if storedBinding.shouldYieldToDetectedSurfaceResumeBinding(detectedBinding) {
                guard surfaceResumeBindingMutationAllowed(
                    detectedBinding,
                    panelId: panelId
                ) else {
                    continue
                }
                invalidateRestoredAgentLifecycleIfBindingIsReplaced(
                    by: detectedBinding,
                    panelId: panelId
                )
                surfaceResumeBindingsByPanelId[panelId] = detectedBinding
            } else if storedBinding.isProcessDetected {
                guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                    continue
                }
                surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
            }
        }
    }

    func effectiveSurfaceResumeBinding(
        panelId: UUID,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?,
        downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable: Bool = false
    ) -> SurfaceResumeBindingSnapshot? {
        let storedBinding = surfaceResumeBindingsByPanelId[panelId]
        guard let surfaceResumeBindingIndex else {
            guard var storedBinding,
                  storedBinding.isProcessDetected,
                  downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable else {
                return storedBinding
            }
            // A windowless recovery freeze cannot synchronously verify process
            // detection after it releases this workspace graph. Preserve the
            // command for manual recovery without trusting it to auto-run.
            storedBinding.autoResume = false
            storedBinding.approvalPolicy = .manual
            storedBinding.approvalRecordId = nil
            surfaceResumeBindingsByPanelId[panelId] = storedBinding
            return storedBinding
        }

        let detectedBinding = surfaceResumeBindingIndex.binding(workspaceId: id, panelId: panelId)
        if surfaceResumeBindingIndex.hasAmbiguousPanel(panelId), detectedBinding == nil {
            // Keep an uncertain binding available for explicit manual resume,
            // but never carry process-detected auto-launch through ambiguity.
            return storedBinding?.disablingAutomaticResume()
        }
        guard let storedBinding else { return detectedBinding }
        guard let detectedBinding else {
            return storedBinding.isProcessDetected ? nil : storedBinding
        }
        if storedBinding.shouldYieldToDetectedSurfaceResumeBinding(detectedBinding) { return detectedBinding }
        if storedBinding.isProcessDetected { return nil }
        return storedBinding
    }

    func createPanel(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        snapshotWorkspaceId: UUID?,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil
    ) -> UUID? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let snapshot = Self.repairedLegacyHermesSessionPanelSnapshot(
            snapshot,
            workspaceId: snapshotWorkspaceId ?? id
        )
        let restoresUntrustedSavedDirectory =
            restoresLegacyRemoteDirectoryWithoutProvenance(snapshot)
        switch snapshot.type {
        case .terminal:
            let localTmuxStartCommand = sessionRestorePolicy
                .localTmuxStartCommand(snapshot.terminal?.tmuxStartCommand)
            let snapshotRestorableAgent = localTmuxStartCommand == nil ? snapshot.terminal?.agent : nil
            let persistedResumeBinding = localTmuxStartCommand == nil ? snapshot.terminal?.resumeBinding : nil
            let restorableAgent = Self.restorableAgentForSessionRestore(
                snapshotRestorableAgent,
                resumeBinding: persistedResumeBinding
            )
            let restoredHibernation = restorableAgent != nil ? snapshot.terminal?.hibernation : nil
            let autoResumeAgentSessions = AgentSessionAutoResumeSettings.isEnabled(defaults: agentSessionAutoResumeDefaults)
            // Only auto-resume if the agent was actively running when the snapshot was saved.
            // wasAgentRunning == nil means a legacy snapshot; treat as true for backwards compatibility.
            let agentWasRunningAtQuit = snapshot.terminal?.wasAgentRunning ?? true
            let shouldAutoResumeAgent = autoResumeAgentSessions && agentWasRunningAtQuit
            let resumeBinding = Self.resumeBindingForSessionRestore(
                persistedResumeBinding,
                restorableAgent: restorableAgent
            )
            // A persisted agent snapshot can coexist with a non-agent surface
            // binding (for example, a process-detected tmux attach). Keep the
            // snapshot available for manual continuation, but never let the
            // ownership-deferred path synthesize an agent resume command on
            // top of that binding.
            let restorableAgentCanAutoResume = restorableAgent != nil &&
                (resumeBinding == nil || resumeBinding?.isAgentHookBinding == true)
            let shouldCheckAgentOwnership = shouldAutoResumeAgent &&
                (restorableAgentCanAutoResume || resumeBinding?.isAgentHookBinding == true)
            let restoreAgentIndex = shouldCheckAgentOwnership ? restorableAgentIndex : nil
            let restoreIndexUnavailable = shouldCheckAgentOwnership && restoreAgentIndex == nil
            let expectedAgentKind = restorableAgent?.kind.rawValue ?? resumeBinding?.kind
            let expectedSessionId = restorableAgent?.sessionId ?? resumeBinding?.checkpointId
            let liveSessionOwner: LiveAgentSessionOwner? = if let expectedAgentKind,
                let expectedSessionId {
                restoreAgentIndex?.liveSessionOwner(
                    kind: expectedAgentKind,
                    sessionID: expectedSessionId,
                    revalidateProcessEvidence: true
                )
            } else {
                nil
            }
            let stablePanelHasLiveProcess = restoreAgentIndex?.hasCurrentLiveProcessForStablePanel(
                workspaceId: id,
                panelId: snapshot.id,
                revalidateProcessEvidence: false
            ) == true
            let stablePanelHasConflictingLiveProcess = restoreAgentIndex?.hasConflictingLiveStablePanelEntry(
                workspaceId: id,
                panelId: snapshot.id,
                expectedKind: expectedAgentKind,
                expectedSessionId: expectedSessionId,
                revalidateProcessEvidence: false
            ) == true
            let stablePanelHasUncertainProcess = restoreAgentIndex?.hasUncertainStablePanelEntry(
                panelId: snapshot.id,
                revalidateProcessEvidence: false
            ) == true
            let restoreOwnershipAmbiguous = shouldCheckAgentOwnership && (
                stablePanelHasConflictingLiveProcess ||
                restoreAgentIndex?.hasAmbiguousPanel(snapshot.id) == true ||
                (restoreAgentIndex?.hasCurrentAmbiguousPanel(
                    snapshot.id,
                    revalidateProcessEvidence: false
                ) == true)
            )
            let restoreStartupBlocked = restoreIndexUnavailable || restoreOwnershipAmbiguous ||
                stablePanelHasUncertainProcess
            let resumeBindingForStartup =
                restoredHibernation != nil ||
                restoreStartupBlocked ||
                liveSessionOwner != nil ||
                stablePanelHasLiveProcess ||
                (resumeBinding?.isProcessDetected == true && resumeBinding?.autoResume != true)
                    ? nil
                    : resumeBinding
            let effectiveResumeBindingForStartup = sessionRestorePolicy.approvedSurfaceResumeBinding(
                resumeBindingForStartup,
                autoResumeAgentSessions: shouldAutoResumeAgent,
                promptForApproval: true,
                approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
            )
            let canAttemptLocalBindingResume =
                effectiveResumeBindingForStartup?.launchFlavor == .local
            let unresolvedBindingLaunch: SurfaceResumeStartupLaunch? =
                if !restoreStartupBlocked,
                   liveSessionOwner == nil,
                   !stablePanelHasLiveProcess,
                   canAttemptLocalBindingResume,
                   let effectiveResumeBindingForStartup {
                    sessionRestorePolicy.surfaceResumeStartupLaunch(
                        forApprovedBinding: effectiveResumeBindingForStartup
                    )
                } else {
                    nil
                }
            let effectiveResumeBinding = unresolvedBindingLaunch != nil
                ? resumeBinding
                : nil
            let savedWorkingDirectory = effectiveResumeBinding?.cwd
                ?? (restoresUntrustedSavedDirectory ? nil : snapshot.terminal?.workingDirectory)
                ?? (restoresUntrustedSavedDirectory ? nil : restorableAgent?.workingDirectory)
                ?? (restoresUntrustedSavedDirectory ? nil : snapshot.directory)
            let workingDirectory = savedWorkingDirectory
                ?? (restoresUntrustedSavedDirectory ? nil : currentDirectory)
            // A persisted terminal cwd can already be the stray fallback cwd
            // from a prior auto-resume restore; the transient rescue/guard must
            // remember where the resume launcher actually sends the agent.
            let resumeSessionWorkingDirectory: String? = {
                if unresolvedBindingLaunch != nil {
                    return effectiveResumeBindingForStartup?.cwd ?? workingDirectory
                }
                guard let restorableAgent else { return savedWorkingDirectory }
                if restorableAgent.registration?.cwd == .ignore {
                    return nil
                }
                return restorableAgent.workingDirectory
                    ?? restorableAgent.launchCommand?.workingDirectory
                    ?? workingDirectory
            }()
            let restoredBindingLaunch = unresolvedBindingLaunch
            let restorableTmuxStartCommand = localTmuxStartCommand
                ?? (!restoreStartupBlocked &&
                    liveSessionOwner == nil &&
                    !stablePanelHasLiveProcess &&
                    restorableAgent == nil && restoredBindingLaunch == nil
                    ? sessionRestorePolicy.restorableTmuxStartCommand(snapshot.terminal?.tmuxStartCommand)
                    : nil)
            let restoredTmuxStartupScript = restorableTmuxStartCommand.flatMap {
                OneShotTerminalLauncherStore().writeStartupCommand(
                    command: $0,
                    workingDirectory: workingDirectory
                )
            }
            let restoredTmuxStartCommand = restoredTmuxStartupScript == nil ? nil : restorableTmuxStartCommand
            // A crash-restart can leave this exact agent session alive from the
            // previous launch (or a duplicate panel can reference the same
            // session in this same restore pass); firing another `codex
            // resume`/`claude --resume` on top of it just piles up redundant
            // processes contending for the same on-disk session data (#8446).
            // Consult the same live-process index already used for "reopen
            // closed tab" / Fork Conversation availability. Local commands
            // claim at the CLI's pre-exec boundary.
            let agentSessionAlreadyActive: Bool = {
                guard shouldAutoResumeAgent, restorableAgentCanAutoResume,
                      restoredHibernation == nil, restoredBindingLaunch == nil,
                      let restorableAgent else {
                    return false
                }
                if restoreIndexUnavailable {
                    // The off-main index refresh will resolve this staged panel.
                    return true
                }
                guard let restoreAgentIndex else { return true }
                if restoreStartupBlocked {
                    // A conflicting live owner must suppress this launch even
                    // when the persisted session is not the selected entry.
                    return true
                }
                if liveSessionOwner != nil {
                    return true
                }
                if restoreAgentIndex.hasCurrentAmbiguousPanel(
                    snapshot.id,
                    revalidateProcessEvidence: false
                ) {
                    // Do not launch while panel ownership is ambiguous; a live process
                    // may still be attached to another owner record.
                    return true
                }
                if restoreAgentIndex.hasCurrentLiveProcessForStablePanel(
                    workspaceId: id,
                    panelId: snapshot.id,
                    expectedKind: restorableAgent.kind.rawValue,
                    expectedSessionId: restorableAgent.sessionId,
                    revalidateProcessEvidence: false
                ) {
                    return true
                }
                // Local restores converge on the CLI admission RPC immediately
                // before exec.
                return false
            }()
            let restoredAgentResumeLaunch: SurfaceResumeStartupLaunch? =
                if shouldAutoResumeAgent && restorableAgentCanAutoResume,
                   restoredHibernation == nil && restoredBindingLaunch == nil
                    && !agentSessionAlreadyActive {
                    restorableAgent?.resumeStartupInput(
                        restoringWorkingDirectory: resumeSessionWorkingDirectory
                    ).map(SurfaceResumeStartupLaunch.input)
                } else {
                    nil
                }
            let liveOwnerNoticeInput = liveSessionOwner.map {
                AgentRestoreLiveOwnerNotice(processID: $0.processID).startupInput(
                    dialect: .loginShell
                )
            }
            // Build the candidate before arming the gate. A binding that is
            // disabled, unapproved, or cannot render a command must start as an
            // ordinary shell instead of waiting behind deferred admission.
            let deferredAgentResumeCandidateInput: String? = if restoreIndexUnavailable,
                restoredHibernation == nil,
                restorableAgentCanAutoResume || resumeBinding?.isAgentHookBinding == true {
                if let restorableAgent {
                    restorableAgent.resumeStartupInput(
                        restoringWorkingDirectory: resumeSessionWorkingDirectory
                    )
                } else {
                    sessionRestorePolicy
                        .approvedSurfaceResumeBinding(
                            resumeBinding,
                            autoResumeAgentSessions: shouldAutoResumeAgent,
                            promptForApproval: true,
                            approvalStoreURL: SurfaceResumeApprovalStore.defaultURL()
                        )
                        .flatMap {
                            return sessionRestorePolicy
                                .surfaceResumeStartupLaunch(forApprovedBinding: $0)?
                                .initialInput
                        }
                }
            } else {
                nil
            }
            let deferredAgentResumeStartupInput = deferredAgentResumeCandidateInput?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false ? deferredAgentResumeCandidateInput : nil
            let deferredAgentResumeAdmission = deferredAgentResumeStartupInput != nil
            let shouldReplayScrollback = sessionRestorePolicy.shouldReplaySessionScrollback(
                hasRestorableAgent: restorableAgent != nil,
                tmuxStartCommand: restoredTmuxStartCommand,
                hasResumeStartupWork: restoredBindingLaunch != nil ||
                    restoredAgentResumeLaunch != nil || deferredAgentResumeStartupInput != nil
            )
            let restoredStartupCommand = restoredTmuxStartupScript
            let restoredStartupInput = restoredBindingLaunch?.initialInput ??
                restoredAgentResumeLaunch?.initialInput ??
                deferredAgentResumeStartupInput ??
                liveOwnerNoticeInput
            let startupHandlesWorkingDirectory =
                restoredTmuxStartupScript != nil ||
                restoredAgentResumeLaunch != nil ||
                restoredBindingLaunch != nil ||
                deferredAgentResumeStartupInput != nil ||
                liveOwnerNoticeInput != nil
            // Guarded startup commands cd themselves and tolerate deleted saved directories.
            // Passing the same cwd to Ghostty can fail before the guarded command runs.
            let localWorkingDirectory = startupHandlesWorkingDirectory ? nil : workingDirectory
            let hostShellWorkingDirectory: String? = {
                guard startupHandlesWorkingDirectory else { return nil }
                let candidate = restoredTmuxStartupScript != nil
                    ? workingDirectory
                    : resumeSessionWorkingDirectory
                return OneShotTerminalLauncherStore.enterableWorkingDirectory(candidate)
            }()
            let requestedWorkingDirectory =
                localWorkingDirectory ?? hostShellWorkingDirectory
            let restoredAgentWillRunStartupInput =
                restoredAgentResumeLaunch?.initialInput != nil ||
                (restoredBindingLaunch?.initialInput != nil && resumeBinding?.isAgentHookBinding == true) ||
                deferredAgentResumeStartupInput != nil
#if DEBUG
            if let restorableAgent {
                let sessionPreview = String(restorableAgent.sessionId.prefix(8))
                let launchArgc = restorableAgent.launchCommand?.arguments.count ?? 0
                cmuxDebugLog(
                    "session.restore.agent panel=\(snapshot.id.uuidString.prefix(5)) " +
                    "kind=\(restorableAgent.kind.rawValue) session=\(sessionPreview) " +
                    "hasLaunch=\(restorableAgent.launchCommand == nil ? 0 : 1) " +
                    "launchArgc=\(launchArgc) hasResume=\(restoredAgentResumeLaunch == nil ? 0 : 1) " +
                    "autoResume=\(autoResumeAgentSessions ? 1 : 0) typedStartup=\(restoredStartupInput == nil ? 0 : 1) " +
                    "replayScrollback=\(shouldReplayScrollback ? 1 : 0)"
                )
            }
            if let resumeBinding {
                cmuxDebugLog(
                    "session.restore.surfaceResume panel=\(snapshot.id.uuidString.prefix(5)) " +
                    "kind=\(resumeBinding.kind ?? "unknown") source=\(resumeBinding.source ?? "unknown") " +
                    "hasLaunch=\(restoredBindingLaunch == nil ? 0 : 1) " +
                    "replayScrollback=\(shouldReplayScrollback ? 1 : 0)"
                )
            }
#endif
            let shouldReplayLocalScrollback = shouldReplayScrollback
            let restoredScrollback = shouldReplayLocalScrollback ? snapshot.terminal?.scrollback : nil
            let replayFileURL = SessionScrollbackReplayStore.replayFileURL(for: restoredScrollback)
            let replayEnvironment = SessionScrollbackReplayStore.replayEnvironment(forFileURL: replayFileURL)
            // Reuse the persisted surface id so the restored terminal keeps
            // the same identity (the panel/surface id IS the ghostty surface
            // id), which keeps agent-session terminal bindings valid across
            // relaunch/restore. Only reuse when no live surface already holds
            // that id (duplicate-workspace / restore-into-live can collide);
            // otherwise fall back to a fresh id and let the old->new remap
            // handle it, exactly as before.
            let reusableSurfaceId: UUID? =
                GhosttyApp.terminalSurfaceRegistry.surface(id: snapshot.id) == nil ? snapshot.id : nil
            guard let terminalPanel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: requestedWorkingDirectory,
                initialCommand: restoredStartupCommand,
                tmuxStartCommand: restoredTmuxStartCommand,
                initialInput: restoredStartupInput,
                startupEnvironment: replayEnvironment,
                runtimeSpawnPolicy: terminalStartupRestoreCoordinator.runtimeSpawnPolicy(
                    requestedPolicy: .pacedSessionRestore,
                    willRunStartupCommand: false,
                    willRunStartupInput: restoredAgentWillRunStartupInput,
                    awaitsDeferredAgentResume: deferredAgentResumeAdmission
                ),
                restoredSurfaceId: reusableSurfaceId,
                terminalFontSizeCreationPolicy: .sessionRestore(
                    overrideBasePoints: snapshot.terminal?.fontSize,
                    representedChangeTokens: Set(
                        snapshot.terminal?.fontSizeChangeTokens ?? []
                    )
                )
            ) else {
                if let replayFileURL { try? FileManager.default.removeItem(at: replayFileURL) }
                return nil
            }
            terminalPanel.surface.setStartupRestoreAdmissionFallbackCommand(nil)
            terminalPanel.adoptOwnedSessionScrollbackReplayArtifact(replayFileURL)
            if let storedResumeBinding = effectiveResumeBindingForStartup ?? resumeBinding {
                let restoredBinding = storedResumeBinding
                if surfaceResumeBindingMutationAllowed(
                    restoredBinding,
                    panelId: terminalPanel.id
                ) {
                    surfaceResumeBindingsByPanelId[terminalPanel.id] = restoredBinding
                }
            } else {
                if surfaceResumeBindingRemovalAllowed(panelId: terminalPanel.id) {
                    surfaceResumeBindingsByPanelId.removeValue(forKey: terminalPanel.id)
                }
            }
            // A terminal whose startup command cds itself (agent resume, tmux attach, agent-hook)
            // is spawned without a working directory, so its shell starts in the default directory
            // and shell integration reports that directory (typically home) before the startup
            // command cds into the saved one. Remember the saved directory so the spurious initial
            // report is ignored instead of overwriting the restored workspace cwd (#6617).
            // `shouldIgnoreRestoredGuardedDirectoryReport` decides how long to guard: once while
            // the saved directory still exists, persistently while it is on an unmounted volume,
            // and not at all once it has been deleted (the shell's reported cwd is then the real
            // fallback).
            if startupHandlesWorkingDirectory,
               localWorkingDirectory == nil,
               let guardedWorkingDirectory = resumeSessionWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !guardedWorkingDirectory.isEmpty {
                restoredGuardedWorkingDirectoriesByPanelId[terminalPanel.id] = .init(
                    directory: guardedWorkingDirectory
                )
            } else {
                restoredGuardedWorkingDirectoriesByPanelId.removeValue(forKey: terminalPanel.id)
            }
            let fallbackScrollback = SessionPersistencePolicy.truncatedScrollback(restoredScrollback)
            if let fallbackScrollback {
                restoredTerminalScrollbackByPanelId[terminalPanel.id] = fallbackScrollback
            } else {
                restoredTerminalScrollbackByPanelId.removeValue(forKey: terminalPanel.id)
            }
            terminalStartupRestoreCoordinator.stage(
                panel: terminalPanel,
                snapshot: restorableAgent,
                resumeBinding: resumeBinding,
                manualResumeAvailable: restorableAgent != nil,
                willRunStartupCommand: false,
                willRunStartupInput: restoredAgentWillRunStartupInput,
                resumeWorkingDirectory: resumeSessionWorkingDirectory,
                chatWorkingDirectory: resumeSessionWorkingDirectory,
                agentSessionAlreadyActive: liveSessionOwner != nil ||
                    (deferredAgentResumeAdmission
                        ? true
                        : (restoreIndexUnavailable ? false : agentSessionAlreadyActive)),
                ownsResumeLaunchClaim: false,
                defersStartupRestoreAdmission: deferredAgentResumeAdmission
            )
            if let liveSessionOwner {
                AgentRestoreSuppressionJournal().record(
                    kind: liveSessionOwner.kind,
                    sessionID: liveSessionOwner.sessionID,
                    workspaceID: id,
                    surfaceID: terminalPanel.id,
                    processID: liveSessionOwner.processID
                )
            }
            if deferredAgentResumeAdmission {
                deferAgentResumeRestore(
                    panelId: terminalPanel.id,
                    restore: DeferredAgentResumeRestore(
                        stablePanelID: snapshot.id,
                        restorableAgent: restorableAgent,
                        resumeBinding: resumeBinding,
                        workingDirectory: workingDirectory,
                        resumeWorkingDirectory: resumeSessionWorkingDirectory
                    )
                )
            }
            if let restorableAgent {
                if let restoredHibernation,
                   restorableAgent.resumeCommand != nil {
                    terminalPanel.enterAgentHibernation(
                        agent: restorableAgent,
                        lastActivityAt: Date(timeIntervalSince1970: restoredHibernation.lastActivityAt),
                        hibernatedAt: Date(timeIntervalSince1970: restoredHibernation.hibernatedAt)
                    )
                }
            }
            terminalPanel.restoreSessionTextBoxDraft(snapshot.terminal?.textBoxDraft)
            applySessionPanelMetadata(snapshot, toPanelId: terminalPanel.id)
            armRestoredPanelTitleBoundary(
                panelId: terminalPanel.id,
                internallySeededInput: restoredStartupInput
            )
            if restoredAgentWillRunStartupInput {
                // Keep the typed local resume selector so the shell-state
                // handler can replay it if the login shell drops the typeahead.
                restoredAgentLifecycle.registerStartupInput(
                    restoredStartupInput,
                    panelId: terminalPanel.id
                )
#if DEBUG
                cmuxDebugLog(
                    "session.restore.startupInput.registered panel=\(terminalPanel.id.uuidString.prefix(5)) " +
                    "bytes=\(restoredStartupInput?.utf8.count ?? 0) deferred=\(deferredAgentResumeAdmission ? 1 : 0)"
                )
#endif
            }
            return terminalPanel.id
        case .markdown:
            guard let filePath = snapshot.markdown?.filePath,
                  let markdownPanel = newMarkdownSurface(
                    inPane: paneId,
                    filePath: filePath,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: markdownPanel.id)
            return markdownPanel.id
        case .filePreview:
            guard let filePath = snapshot.filePreview?.filePath,
                  let filePreviewPanel = newFilePreviewSurface(
                    inPane: paneId,
                    filePath: filePath,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: filePreviewPanel.id)
            return filePreviewPanel.id
        case .rightSidebarTool:
            guard let mode = snapshot.rightSidebarTool?.mode,
                  mode.canOpenAsPane,
                  mode.isAvailable(),
                  let toolPanel = newRightSidebarToolSurface(
                    inPane: paneId,
                    mode: mode,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: toolPanel.id)
            return toolPanel.id
        case .customSidebar: return restoreCustomSidebarPanel(from: snapshot, inPane: paneId)
        case .simulator: return restoreSimulatorPanel(from: snapshot, inPane: paneId)
        case .agentSession:
            guard let agentSession = snapshot.agentSession,
                  let agentPanel = newAgentSessionSurface(
                    inPane: paneId,
                    providerID: agentSession.providerID,
                    rendererKind: agentSession.rendererKind,
                    workingDirectory: restoresUntrustedSavedDirectory ? nil : (agentSession.workingDirectory ?? snapshot.directory),
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: agentPanel.id)
            return agentPanel.id
        case .project:
            guard let projectPath = snapshot.project?.projectPath,
                  let projectPanel = newProjectSurface(
                    inPane: paneId,
                    projectPath: projectPath,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: projectPanel.id)
            return projectPanel.id
        case .workspaceTodo:
            guard let todoPanel = newWorkspaceTodoSurface(inPane: paneId, focus: false) else { return nil }
            applySessionPanelMetadata(snapshot, toPanelId: todoPanel.id)
            return todoPanel.id
        case .notifications:
            guard snapshot.notificationsPanel != nil,
                  let notificationsPanel = newNotificationsSurface(inPane: paneId, focus: false) else { return nil }
            applySessionPanelMetadata(snapshot, toPanelId: notificationsPanel.id)
            return notificationsPanel.id
            return nil
        }
    }
    func applySessionPanelMetadata(_ snapshot: SessionPanelSnapshot, toPanelId panelId: UUID) {
        adoptPersistedStableSurfaceId(from: snapshot, panelId: panelId)

        if let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            panelTitles[panelId] = title
        }

        setPanelCustomTitle(panelId: panelId, title: snapshot.customTitle, source: snapshot.effectiveCustomTitleSource ?? .user)
        setPanelPinned(panelId: panelId, pinned: snapshot.isPinned)

        // The bonsplit tab header only refreshes when `updateTab` is called; the writes
        // above never reach it (`setPanelCustomTitle` skips the sync when there is no
        // custom title), so push the restored title to the tab now, mirroring
        // `updatePanelTitle`, instead of waiting for the next OSC title update.
        if let panel = panels[panelId], let tabId = surfaceIdFromPanelId(panelId) {
            bonsplitController.updateTab(
                tabId,
                title: resolvedPanelTitle(panelId: panelId, fallback: panelTitles[panelId] ?? panel.displayTitle),
                hasCustomTitle: panelCustomTitles[panelId] != nil
            )
        }

        if snapshot.isManuallyUnread {
            markPanelUnread(panelId)
        } else {
            clearManualUnread(panelId: panelId)
        }
        let hasUnreadPanelNotification = snapshot.notifications?.contains(where: { !$0.isRead }) == true
        if snapshot.hasUnreadIndicator == true, !hasUnreadPanelNotification {
            let contributesToWorkspaceUnread = snapshot.restoredUnreadContributesToWorkspace
                ?? (snapshot.notifications?.isEmpty ?? true)
            restorePanelUnreadIndicator(
                panelId,
                contributesToWorkspaceUnread: contributesToWorkspaceUnread
            )
        } else {
            clearRestoredUnreadIndicator(panelId: panelId)
        }

        let restoredDirectoryRequiresRemoteTrust =
            remoteDirectoryTrustRequiredPanelIds.contains(panelId) ||
                restoresLegacyRemoteDirectoryWithoutProvenance(snapshot)
        if let directory = snapshot.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            updatePanelDirectory(panelId: panelId, directory: directory, displayLabel: nil, source: .restoredSnapshotMetadata)
            if restoredDirectoryRequiresRemoteTrust {
                remoteDirectoryTrustRequiredPanelIds.insert(panelId)
            }
        }

        if restoredDirectoryRequiresRemoteTrust {
            clearPanelGitBranch(panelId: panelId)
        } else if let branch = snapshot.gitBranch {
            panelGitBranches[panelId] = SidebarGitBranchState(branch: branch.branch, isDirty: branch.isDirty)
        } else {
            panelGitBranches.removeValue(forKey: panelId)
        }

        if snapshot.terminal?.hibernation != nil {
            surfaceListeningPorts.removeValue(forKey: panelId)
        } else {
            surfaceListeningPorts[panelId] = Array(Set(snapshot.listeningPorts)).sorted()
        }

        if let ttyName = snapshot.ttyName?.trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty {
            restorePersistedSurfaceTTYName(ttyName, panelId: panelId)
        } else {
            restorePersistedSurfaceTTYName(nil, panelId: panelId)
        }
    }

    private func restoreWorkspaceManualUnread(_ isManuallyUnread: Bool) {
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
        if isManuallyUnread {
            notificationStore.markUnread(forTabId: id)
        } else {
            notificationStore.clearManualUnread(forTabId: id)
        }
        syncUnreadBadgeStateForAllPanels()
    }

    private func notificationSnapshots(surfaceId: UUID?) -> [SessionNotificationSnapshot] {
        AppDelegate.shared?.notificationStore?
            .notifications(forTabId: id, surfaceId: surfaceId)
            .map(SessionNotificationSnapshot.init(notification:)) ?? []
    }

    private func restoredSessionNotifications(
        from snapshot: SessionWorkspaceSnapshot,
        oldToNewPanelIds: [UUID: UUID]
    ) -> [TerminalNotification] {
        var notifications = (snapshot.notifications ?? []).map {
            $0.terminalNotification(tabId: id, surfaceId: nil, panelId: nil)
        }

        for panelSnapshot in snapshot.panels {
            guard let newPanelId = oldToNewPanelIds[panelSnapshot.id] else { continue }
            notifications.append(
                contentsOf: (panelSnapshot.notifications ?? []).map {
                    $0.terminalNotification(
                        tabId: id,
                        surfaceId: newPanelId,
                        panelId: newPanelId
                    )
                }
            )
        }

        return notifications
    }

}

// MARK: - Config-driven terminal input delivery

extension Workspace {

    /// Delivers config-driven startup input (`Workspace+CustomLayout.swift`) once
    /// the terminal surface is ready, or immediately when it already is.
    func sendInputWhenReady(
        _ text: String,
        to panel: TerminalPanel,
        reason: WorkspacePendingTerminalInputReason = .configurationCommand
    ) {
        if panel.surface.surface != nil {
            panel.sendInput(text)
            return
        }

        let timeout = reason.timeout
        let panelId = panel.id
        let registration = WorkspacePendingTerminalInputObserver()

        registration.observer = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: panel.surface,
            queue: .main
        ) { [weak self, registration] _ in
            Task { @MainActor [weak self, registration] in
                guard
                    let self,
                    self.hasPendingTerminalInputObserver(registration, forPanelId: panelId)
                else {
                    return
                }

                self.removePendingTerminalInputObserver(registration, forPanelId: panelId)
                if let panel = self.panels[panelId] as? TerminalPanel {
                    panel.sendInput(text)
                }
            }
        }
        pendingTerminalInputObserversByPanelId[panelId, default: []].append(registration)
        panel.surface.requestBackgroundSurfaceStartIfNeeded()

        guard let timeout else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, registration] in
            Task { @MainActor [weak self, registration] in
                guard
                    let self,
                    self.hasPendingTerminalInputObserver(registration, forPanelId: panelId)
                else {
                    return
                }

                self.removePendingTerminalInputObserver(registration, forPanelId: panelId)
                #if DEBUG
                NSLog("[CmuxConfig] surface not ready after 3s, dropping command (%d chars)", text.count)
                #endif
            }
        }
    }

    private func hasPendingTerminalInputObserver(
        _ registration: WorkspacePendingTerminalInputObserver,
        forPanelId panelId: UUID
    ) -> Bool {
        pendingTerminalInputObserversByPanelId[panelId]?.contains {
            $0 === registration
        } == true
    }

    private func removePendingTerminalInputObserver(
        _ registration: WorkspacePendingTerminalInputObserver,
        forPanelId panelId: UUID
    ) {
        if let observer = registration.observer {
            NotificationCenter.default.removeObserver(observer)
            registration.observer = nil
        }
        pendingTerminalInputObserversByPanelId[panelId]?.removeAll {
            $0 === registration
        }
        if pendingTerminalInputObserversByPanelId[panelId]?.isEmpty == true {
            pendingTerminalInputObserversByPanelId.removeValue(forKey: panelId)
        }
    }

    func removePendingTerminalInputObservers(forPanelId panelId: UUID) {
        guard let observers = pendingTerminalInputObserversByPanelId.removeValue(forKey: panelId) else {
            return
        }
        for registration in observers {
            if let observer = registration.observer {
                NotificationCenter.default.removeObserver(observer)
                registration.observer = nil
            }
        }
    }

}
/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
final class Workspace: Identifiable, ObservableObject, FilePreviewTabMetadataHost {
    static let terminalScrollBarHiddenDidChangeNotification = Notification.Name(
        "cmux.workspaceTerminalScrollBarHiddenDidChange"
    )
    let id: UUID
    private(set) var isRetiredFromOwningTabManager = false
    /// Restart-stable workspace identifier persisted for durable deep links.
    private(set) var stableId = UUID()
    /// Durable idempotency key for task-composer workspace creation.
    var taskCreateOperationID: UUID?
    private var forkAgentConversationInFlightPanelIds: Set<UUID> = []

    func beginForkAgentConversationAction(panelId: UUID) -> Bool {
        guard !forkAgentConversationInFlightPanelIds.contains(panelId) else {
            return false
        }
        forkAgentConversationInFlightPanelIds.insert(panelId)
        return true
    }

    func endForkAgentConversationAction(panelId: UUID) {
        forkAgentConversationInFlightPanelIds.remove(panelId)
    }

    /// When this workspace instance came into existence in this app session
    /// (creation, or restore at launch). The mobile list's last-activity
    /// fallback: a workspace that never fired a notification still carries a
    /// real timestamp instead of nothing.
    let createdAt = Date()
    @Published var title: String
    @Published var customTitle: String?
    /// Provenance of `customTitle`: `.user` for manual renames (sidebar,
    /// CLI, command palette), `.auto` for AI auto-naming. `nil` when no
    /// custom title is set. A present title with absent provenance is
    /// treated as `.user` so auto-naming never overwrites a title it
    /// cannot prove it owns.
    @Published var customTitleSource: CustomTitleSource?
    @Published var customDescription: String?
    private(set) var customDescriptionRevision: UInt64 = 0

    func bumpCustomDescriptionRevision() {
        customDescriptionRevision &+= 1
    }

    @Published var isPinned: Bool = false
    /// Suppresses notification history/recording, unread badges, sound,
    /// desktop banners, pane flashes, phone forwarding, command hooks, and
    /// reorder effects for this workspace. Persisted in the session manifest
    /// so an intentional mute survives relaunch.
    @Published var isMuted: Bool = false
    /// Identifier of the WorkspaceGroup this workspace belongs to, or nil if ungrouped.
    /// The group entity itself lives in `TabManager.workspaceGroups`.
    @Published var groupId: UUID?
    @Published var customColor: String?  // hex string, e.g. "#C0392B"
    /// User-defined environment variables applied to every shell spawned in this
    /// workspace: the initial terminal, every later pane/surface/split, and every
    /// surface recreated on session restore. Managed `CMUX_*` and terminal-identity
    /// variables always win — this dictionary is merged through the
    /// `additionalEnvironment` / `initialEnvironmentOverrides` channels, both of
    /// which skip `protectedStartupEnvironmentKeys` in
    /// `mergedStartupEnvironment(...)`, so a workspace env entry can never clobber
    /// the variables the daemon relies on (CMUX_WORKSPACE_ID, CMUX_SOCKET_PATH, …).
    /// Persisted in the session manifest and restored before surfaces are rebuilt.
    @Published var workspaceEnvironment: [String: String] = [:]
    // Legacy in-memory state for old helpers/tests. Product UI, rendering, and
    // session persistence no longer honor per-workspace scrollbar overrides.
    @Published private(set) var terminalScrollBarHidden: Bool = false
    @Published var currentDirectory: String {
        didSet {
            let oldDirectory = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let newDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard oldDirectory != newDirectory else { return }
            scheduleExtensionSidebarProjectRootRefresh(for: currentDirectory)
            // Notify the sidebar so anchor-cwd-driven group config (color,
            // icon, context menu, newWorkspacePlacement) refreshes even
            // when the anchor isn't the visible/selected workspace. Group
            // headers are the anchor's only sidebar surface, so a
            // TabItemView-style observation isn't mounted for them.
            NotificationCenter.default.post(
                name: .workspaceCurrentDirectoryDidChange,
                object: self,
                userInfo: ["workspaceId": id]
            )
        }
    }
    @Published private(set) var extensionSidebarProjectRootPath: String?
    private var extensionSidebarProjectRootRefreshID: UInt64 = 0
    @Published private(set) var surfaceTabBarDirectory: String?
    let closeTabWarningDefaults, agentSessionAutoResumeDefaults: UserDefaults
    let agentChatResumeIntentRecorder: any AgentChatResumeIntentRecording
    /// Supplies one authoritative agent index for a restore pass. Production
    /// restores request a fresh off-main scan; tests and composed restore flows
    /// may inject a prepared snapshot.
    let restorableAgentIndexProvider: @MainActor () -> RestorableAgentSessionIndex?
    private let settings: any SettingsReading

    /// Ordinal for CMUX_PORT range assignment (monotonically increasing per app session)
    var portOrdinal: Int = 0

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController
    /// Process/window composition capability registry shared with every pane target.
    let tabDragTransferRegistry: TabDragTransferRegistry
    /// One content-change pipeline shared by every file-backed panel in this workspace.
    let fileContentChangeCoordinator: FileContentChangeCoordinator

    /// Backing store for `dockSplit`, created on first access. Kept optional so
    /// workspace teardown can tear down the Dock only when it was actually used
    /// (and so reading it during teardown does not lazily create one).
    private(set) var _dockSplit: DockSplitStore?

    /// The right-sidebar Dock for this workspace: its own Bonsplit tree of
    /// terminal panels, separate from the main-area `bonsplitController`.
    /// Created on first access so workspaces that never open the Dock pay nothing.
    var dockSplit: DockSplitStore? {
        guard !isRetiredFromOwningTabManager else { return nil }
        if let existing = _dockSplit { return existing }
        let store = DockSplitStore(
            workspaceId: id,
            baseDirectoryProvider: { [weak self] in self?.currentDirectory },
            tabDragTransferRegistry: tabDragTransferRegistry,
            settings: settings,
            agentSessionAutoResumeDefaults: agentSessionAutoResumeDefaults,
            agentChatResumeIntentRecorder: agentChatResumeIntentRecorder,
            fileContentChangeCoordinator: fileContentChangeCoordinator,
            restorableAgentIndexProvider: restorableAgentIndexProvider
        )
        store.terminalFontSizeChangeCoordinator =
            terminalFontSizeChangeCoordinator
        store.terminalFontSizeChangeArbiter =
            terminalFontSizeChangeArbiter
        store.terminalFontSizeOwningWorkspace = self
        if let inheritanceContext =
                activeTerminalFontSizeChangeInheritanceContext {
            store.beginTerminalFontSizeChangeInheritance(
                token: inheritanceContext.token,
                change: inheritanceContext.change,
                configuredRuntimePoints:
                    inheritanceContext.configuredRuntimePoints,
                magnificationPercent:
                    inheritanceContext.magnificationPercent,
                fallbackLineage: inheritanceContext.fallbackLineage,
                fallbackLineageAlreadyIncludesChange: true
            )
        } else {
            store.rememberTerminalFontSizeLineageForNewTerminals(
                fallback:
                    lastRememberedTerminalFontSizeLineageForConfigInheritance()
            )
        }
        _dockSplit = store
        return store
    }

    /// How this workspace lays out its panels. Mutate through
    /// `setLayoutMode(_:)` (Workspace+CanvasLayout.swift) so canvas frames
    /// are seeded from the split layout on first entry.
    @Published var layoutMode: WorkspaceLayoutMode = .splits

    /// Durable canvas-layout state (pane frames, z-order). Lives on the
    /// workspace so it survives canvas view remounts and workspace switches.
    let canvasModel = CanvasModel(metricsProvider: { CanvasLayoutSettings.currentMetrics() })
    private struct SurfaceTabBarExecutableButton {
        let button: CmuxSurfaceTabBarButton
        let builtInAction: CmuxSurfaceTabBarBuiltInAction?
        let workspaceCommand: CmuxResolvedCommand?
        let terminalCommandSourcePath: String?
    }

    private var surfaceTabBarCommandButtons: [String: SurfaceTabBarExecutableButton] = [:]
    private var surfaceTabBarButtonSourcePath: String?
    private var surfaceTabBarButtonGlobalConfigPath: String?
    private var surfaceTabBarButtonConfiguration: SurfaceTabBarButtonConfiguration?
    private var featureFlagsObserver: NSObjectProtocol?

    /// The pane-tree sub-model (CmuxPanes): owns the panel registry, the
    /// surface-id mapping, and the pane-layout bookkeeping. The legacy
    /// accessors below forward here; `Workspace` hosts the property-observer
    /// hooks via `PaneTreeHosting`.
    let paneTree = PaneTreeModel<any Panel>()

    /// The surface-list derivation sub-model (CmuxWorkspaces): derives
    /// the ordered panel-id lists, focused panel, representative panel, per-pane
    /// selection, the `tabIdsTo*` pane queries, and the `paneLayoutVersion`
    /// reorder bump. `Workspace` is its tree-reading host via
    /// `WorkspaceSurfaceTreeReading`; the legacy accessors below forward here.
    let surfaceList = WorkspaceSurfaceListModel()

    /// The surface-registry sub-model (CmuxWorkspaceCore): owns the
    /// per-surface registry annotations (tty names, shell-activity states)
    /// and the transient tab-selection/focus-reassert request state. The
    /// legacy accessors below forward here. None of the moved properties
    /// were `@Published`, so no observer hooks are required.
    let surfaceRegistry = SurfaceRegistryModel<PendingTabSelectionRequest>()

    /// The split-layout sub-model (CmuxPanes): owns the split/detach
    /// choreography bookkeeping (programmatic-split flag, detaching surface
    /// ids, captured transfer payloads, detach-close transaction count). The
    /// legacy accessors below forward here. None of the moved properties
    /// were `@Published`, so no observer hooks are required.
    private let splitLayout = SplitLayoutModel<DetachedSurfaceTransfer>()

    /// Legacy Combine bridge for the remaining `workspace.$panels`
    /// subscribers. Driven exclusively from `panelsWillChange(to:)`, so it
    /// emits the new value during willSet and replays the current value on
    /// subscribe — the exact `Published.Publisher` semantics those call
    /// sites were written against. Single seam; delete when the subscribers
    /// move to @Observable observation.
    let panelsPublisher = CurrentValueSubject<[UUID: any Panel], Never>([:])
    /// Legacy Combine bridge for the remaining `$paneLayoutVersion`
    /// subscribers; same contract as `panelsPublisher`.
    let paneLayoutVersionPublisher = CurrentValueSubject<Int, Never>(0)

    /// Mapping from bonsplit TabID to our Panel instances
    var panels: [UUID: any Panel] {
        get { paneTree.panels }
        set { paneTree.panels = newValue }
    }

    /// Monotonic counter bumped only when the spatial (left-to-right, top-to-bottom)
    /// order of panels changes without the panel *set* changing — i.e. a pure
    /// drag-reorder of tabs within or across panes. Membership changes already
    /// fire `$panels`; pure reorders mutate only `bonsplitController` state, which
    /// is not `@Published`, so observers (e.g. the mobile workspace-list observer)
    /// would otherwise never learn about a reorder. We gate the bump on an actual
    /// change of `orderedPanelIds` so that divider drags and selection-only events
    /// (which also flow through `didChangeGeometry`) do not fire `objectWillChange`.
    var paneLayoutVersion: Int {
        get { paneTree.paneLayoutVersion }
        set { paneTree.paneLayoutVersion = newValue }
    }

    /// Panes being moved to another workspace: their surface projection moves with them
    /// instead of ending when they leave this one (see `Workspace+SurfaceCatalog.swift`).
    var surfaceTransferringPanelIds: Set<UUID> = []
    /// Subscriptions for panel updates (e.g., markdown title changes)
    var panelSubscriptions: [UUID: AnyCancellable] = [:]
    private var agentSessionPanelCallbackIds: Set<UUID> = []

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels);
    /// stored in the split-layout sub-model.
    var isProgrammaticSplit: Bool {
        get { splitLayout.isProgrammaticSplit }
        set { splitLayout.isProgrammaticSplit = newValue }
    }
    var activeMovingTabSplitFocusIntent: MovingTabSplitFocusIntent?
    private var debugStressPreloadSelectionDepth = 0

    /// Last terminal panel used as an inheritance source (typically last focused terminal).
    var lastTerminalConfigInheritancePanelId: UUID?
    /// Last known terminal font lineage from an inheritance source. The
    /// surface owns live lineage; this fallback only survives removal of the
    /// last source panel.
    private var lastTerminalConfigInheritanceFontSizeLineage: TerminalFontSizeLineage?
#if DEBUG
    var debugInheritedTerminalConfigInvocationCount = 0
#endif
    /// Predicts per-source post-change lineage while a bounded workspace font
    /// request spans multiple event-loop turns.
    var activeTerminalFontSizeChangeInheritanceContext:
        TerminalFontSizeChangeInheritanceContext?
    weak var terminalFontSizeChangeCoordinator:
        WorkspaceTerminalFontSizeCoordinator?
    weak var terminalFontSizeChangeArbiter:
        WorkspaceTerminalFontSizeArbiter?

    /// Wires a coordinator into the workspace and its already-created Dock.
    func setTerminalFontSizeChangeCoordinator(
        _ coordinator: WorkspaceTerminalFontSizeCoordinator?
    ) {
        terminalFontSizeChangeCoordinator = coordinator
        _dockSplit?.terminalFontSizeChangeCoordinator = coordinator
    }

    /// Wires an arbiter into the workspace and its already-created Dock.
    func setTerminalFontSizeChangeArbiter(
        _ arbiter: WorkspaceTerminalFontSizeArbiter?
    ) {
        terminalFontSizeChangeArbiter = arbiter
        _dockSplit?.terminalFontSizeChangeArbiter = arbiter
    }

    weak var owningTabManager: TabManager?

    // Closing tabs mutates split layout immediately; terminal views handle their own AppKit
    // layout/size synchronization.

    /// The currently focused pane's panel ID. Forwards to
    /// ``WorkspaceSurfaceListModel/focusedPanelId``.
    var focusedPanelId: UUID? {
        surfaceList.focusedPanelId
    }

    /// Panel ids in bonsplit's spatial order: depth-first over the split tree
    /// (left/top child before right/bottom child), and within each pane in tab
    /// order. This is the on-screen left-to-right, top-to-bottom ordering and is
    /// the single source of truth for serializing panels (e.g. the mobile
    /// terminal list) and for detecting reorders. Any panels not currently in
    /// bonsplit are appended in a stable id order so the list never drops a panel.
    /// Forwards to ``WorkspaceSurfaceListModel/orderedPanelIds``.
    var orderedPanelIds: [UUID] {
        surfaceList.orderedPanelIds
    }

    /// The workspace-owned terminal panel selected in the focused pane.
    var focusedTerminalPanel: TerminalPanel? {
        guard let panelId = focusedPanelId,
              let panel = panels[panelId] as? TerminalPanel else {
            return nil
        }
        return panel
    }

    /// Forwards to
    /// ``WorkspaceSurfaceListModel/representativePanelIdForWorkspaceManualUnread()``.
    func representativePanelIdForWorkspaceManualUnread() -> UUID? {
        surfaceList.representativePanelIdForWorkspaceManualUnread()
    }

    /// Forwards to
    /// ``WorkspaceSurfaceListModel/effectiveSelectedPanelId(inPaneId:)``.
    func effectiveSelectedPanelId(inPane paneId: PaneID) -> UUID? {
        surfaceList.effectiveSelectedPanelId(inPaneId: paneId.id)
    }

    /// Published directory for each panel
    @Published var panelDirectories: [UUID: String] = [:] {
        didSet { surfaceCatalogPanelMetadataDidChange(old: oldValue, new: panelDirectories) }
    }
    /// Optional human-friendly sidebar label per panel, reported via
    /// `report_pwd <label> --path=<real-path>`. Display-only: the File
    /// Explorer, Finder root, and git probing always use `panelDirectories`.
    /// An explicit label overwrites the previous one; a label-less directory
    /// change clears it, while same-directory re-reports keep it. Stored in
    /// ``sidebarMetadata`` so label-only updates refresh the sidebar pipeline
    /// without workspace-wide invalidation.
    var panelDirectoryDisplayLabels: [UUID: String] {
        get { sidebarMetadata.panelDirectoryDisplayLabels }
        set { sidebarMetadata.panelDirectoryDisplayLabels = newValue }
    }
    @Published var panelTitles: [UUID: String] = [:] {
        didSet { surfaceCatalogPanelMetadataDidChange(old: oldValue, new: panelTitles) }
    }
    @Published var panelCustomTitles: [UUID: String] = [:]
    /// Provenance of entries in `panelCustomTitles` (see ``CustomTitleSource``).
    /// An entry may be absent for a title carried across panel moves or
    /// restored from older snapshots; absent provenance is treated as `.user`.
    var panelCustomTitleSources: [UUID: CustomTitleSource] = [:]
    @Published var pinnedPanelIds: Set<UUID> = []
    var pinMutationTokensByPanelId: [UUID: UUID] = [:]
    let panelUnread = WorkspacePanelUnreadModel()
    var manualUnreadPanelIds: Set<UUID> {
        get { panelUnread.panelIds }
        set {
            guard panelUnread.replace(with: newValue) else { return }
            syncPanelDerivedWorkspaceUnread()
        }
    }
    @Published private var restoredUnreadPanelIndicators: [UUID: RestoredPanelUnreadIndicator] = [:] {
        didSet {
            guard restoredUnreadPanelIndicators != oldValue else { return }
            syncPanelDerivedWorkspaceUnread()
        }
    }
    var restoredUnreadPanelIds: Set<UUID> { Set(restoredUnreadPanelIndicators.keys) }

    var hasAnyRestoredUnreadPanelIndicator: Bool { !restoredUnreadPanelIndicators.isEmpty }
    @Published private(set) var tmuxLayoutSnapshot: LayoutSnapshot?
    @Published private(set) var tmuxWorkspaceFlashPanelId: UUID?
    @Published private(set) var tmuxWorkspaceFlashReason: WorkspaceAttentionFlashReason?
    @Published private(set) var tmuxWorkspaceFlashToken: UInt64 = 0
    var manualUnreadMarkedAt: [UUID: Date] = [:]
    /// The sidebar-metadata sub-model (CmuxSidebar): owns the
    /// sidebar status entries, metadata blocks, log entries, progress, and
    /// git-branch / pull-request presentation state. The legacy accessors below
    /// forward here. The moved properties were `@Published` and fed the sidebar
    /// observation publishers, so the model exposes per-field Combine publishers
    /// (`statusEntriesPublisher` etc.) that `makeSidebarObservationPublisher()`
    /// subscribes to in place of the former `$projection`s, preserving the
    /// debounced refresh timing byte-identically.
    let sidebarMetadata = WorkspaceSidebarMetadataModel(
        limitProvider: WorkspaceSidebarLogEntryLimitProvider()
    )
    var statusEntries: [String: SidebarStatusEntry] {
        get { sidebarMetadata.statusEntries }
        set { sidebarMetadata.statusEntries = newValue }
    }
    var metadataBlocks: [String: SidebarMetadataBlock] {
        get { sidebarMetadata.metadataBlocks }
        set { sidebarMetadata.metadataBlocks = newValue }
    }
    @Published private(set) var latestConversationMessage: String?
    @Published private(set) var latestSubmittedMessage: String?
    @Published private(set) var latestSubmittedAt: Date?
    var logEntries: [SidebarLogEntry] {
        get { sidebarMetadata.logEntries }
        set { sidebarMetadata.logEntries = newValue }
    }
    var progress: SidebarProgressState? {
        get { sidebarMetadata.progress }
        set { sidebarMetadata.progress = newValue }
    }
    var gitBranch: SidebarGitBranchState? {
        get { sidebarMetadata.gitBranch }
        set { sidebarMetadata.gitBranch = newValue }
    }
    var panelGitBranches: [UUID: SidebarGitBranchState] {
        get { sidebarMetadata.panelGitBranches }
        set { sidebarMetadata.panelGitBranches = newValue }
    }
    @Published var surfaceListeningPorts: [UUID: [Int]] = [:]
    var agentListeningPorts: [Int] = []
    @Published var listeningPorts: [Int] = []
    private(set) var remoteDirectoryTrustRequiredPanelIds: Set<UUID> = []
    private(set) var remoteDirectoryReportPanelIds: Set<UUID> = []

    /// The shell-activity classification per panel id; stored in the
    /// surface-registry sub-model.
    var panelShellActivityStates: [UUID: PanelShellActivityState] {
        get { surfaceRegistry.panelShellActivityStates }
        set { surfaceRegistry.panelShellActivityStates = newValue }
    }
    /// Per-panel admission state preventing restored PTY startup noise from
    /// taking ownership of the persisted title.
    var restoredPanelTitleBoundariesByPanelId: [UUID: RestoredPanelTitleBoundary] = [:]
    /// Agent runtime maps that affect sidebar status visibility.
    let sidebarAgentRuntimeObservation = WorkspaceSidebarAgentRuntimeObservationModel()
    /// Todo lifecycle state: manual status override + persisted checklist (all logic lives in `Workspace+Todos.swift`).
    let todoState = WorkspaceTodoState()
    let sidebarProcessTitleObservation: WorkspaceSidebarProcessTitleObservationModel
    var restoredTerminalScrollbackByPanelId: [UUID: String] = [:]
#if DEBUG
    var debugSessionSnapshotScrollbackFallbackPanelIds: Set<UUID> = []
    var debugSessionSnapshotSyntheticScrollbackByPanelId: [UUID: String] = [:]
#endif
    let terminalStartupRestoreCoordinator: TerminalStartupRestoreCoordinator
    var restoredAgentLifecycle: RestoredAgentLifecycleCoordinator {
        terminalStartupRestoreCoordinator.lifecycle
    }
    var restoredAgentSnapshotsByPanelId: [UUID: SessionRestorableAgentSnapshot] {
        restoredAgentLifecycle.snapshotsByPanelId
    }
    var surfaceResumeBindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
    /// In-memory compare-and-claim state held while a CLI restore hands the
    /// validated binding to its child process.
    @ObservationIgnored var surfaceResumeRestoreClaimsByPanelId: [
        UUID: (binding: SurfaceResumeBindingSnapshot, claimedAt: Date)
    ] = [:]
    var restoredGuardedWorkingDirectoriesByPanelId: [UUID: RestoredWorkingDirectoryGuard] = [:]
    /// The session directory each restored auto-resume launcher targets, kept
    /// for the resumed run so split/new-tab cwd inheritance can rescue a
    /// clobbered tracked cwd while the agent holds the pane's foreground (#7155).
    var restoredResumeSessionWorkingDirectoriesByPanelId: [UUID: String] {
        get { restoredAgentLifecycle.resumeWorkingDirectoriesByPanelId }
        set { restoredAgentLifecycle.resumeWorkingDirectoriesByPanelId = newValue }
    }
    var deferredAgentResumeRestoresByPanelId: [UUID: DeferredAgentResumeRestore] = [:]
    var deferredAgentResumeClaimsByPanelId: [UUID: (kind: String, sessionId: String)] = [:]
    var deferredAgentResumeIndexTask: Task<Void, Never>?
    enum RestoredAgentResumeState: Equatable {
        case manualResumeAvailable, awaitingAutoResumeCommand, autoResumeCommandRunning, observedAgentCommandRunning, completedAgentExit
    }
    var restoredAgentResumeStatesByPanelId: [UUID: RestoredAgentResumeState] {
        restoredAgentLifecycle.resumeStatesByPanelId
    }
    var invalidatedRestoredAgentFingerprintsByPanelId: [UUID: Int] {
        get { restoredAgentLifecycle.invalidatedFingerprintsByPanelId }
        set { restoredAgentLifecycle.invalidatedFingerprintsByPanelId = newValue }
    }
    private var pendingTerminalInputObserversByPanelId: [UUID: [WorkspacePendingTerminalInputObserver]] = [:]
    private let sessionRestorePolicy: WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot>
    /// Coalesces portal/focus follow-up requests emitted while Bonsplit is being rebuilt.
    private var sessionRestoreLayoutSuppressionDepth = 0
    private var sessionRestoreLayoutFollowUpRequested = false

    typealias SurfaceResumeStartupLaunch = WorkspaceSurfaceResumeStartupLaunch

    // Sidebar rows cache snapshots, so observation must begin with the current
    // workspace state. Build state publishers from @Published current values
    // instead of dropping the first value and repairing timing with a Void event.
    lazy var sidebarImmediateObservationPublisher: AnyPublisher<Void, Never> = makeSidebarImmediateObservationPublisher()
    lazy var sidebarObservationPublisher: AnyPublisher<Void, Never> = makeSidebarObservationPublisher()

    private func scheduleExtensionSidebarProjectRootRefresh(for directory: String) {
        extensionSidebarProjectRootRefreshID &+= 1
        let refreshID = extensionSidebarProjectRootRefreshID
        guard !usesRemoteDirectoryProvenance else {
            extensionSidebarProjectRootPath = nil
            return
        }
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectory.isEmpty else {
            extensionSidebarProjectRootPath = nil
            return
        }

        Task.detached(priority: .utility) { [weak self, trimmedDirectory, refreshID] in
            let projectRootPath = Self.extensionSidebarProjectRootPath(onDiskFor: trimmedDirectory)
            await MainActor.run { [weak self] in
                guard let self,
                      self.extensionSidebarProjectRootRefreshID == refreshID else {
                    return
                }
                self.extensionSidebarProjectRootPath = projectRootPath
            }
        }
    }

    nonisolated private static func extensionSidebarProjectRootPath(onDiskFor directory: String) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default
        while url.path != "/" {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    var focusedSurfaceId: UUID? { focusedPanelId }
    var surfaceDirectories: [UUID: String] {
        get { panelDirectories }
        set { panelDirectories = newValue }
    }

    var processTitle: String

    nonisolated static func resolveCloseConfirmation(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        switch shellActivityState ?? .unknown {
        case .promptIdle:
            return false
        case .commandRunning:
            return true
        case .unknown:
            return fallbackNeedsConfirmClose
        }
    }

    nonisolated static func makeSessionRestorePolicyService()
        -> WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot> {
        WorkspaceSessionRestorePolicyService(
            applyStoredApproval: { binding, fileURL, signingSecret in
                switch SurfaceResumeApprovalStore.applyingStoredApprovalLookup(
                    to: binding,
                    fileURL: fileURL,
                    signingSecret: signingSecret
                ) {
                case .pendingSigningSecret:
                    return nil
                case let .resolved(effectiveBinding):
                    return effectiveBinding
                }
            },
            shouldRunPromptedSurfaceResume: { binding in
                Self.shouldRunPromptedSurfaceResume(binding)
            },
            isRunningUnderAutomatedTests: {
                SessionRestorePolicy.isRunningUnderAutomatedTests()
            },
            truncateScrollback: { text in
                SessionPersistencePolicy.truncatedScrollback(text)
            },
            hermesCodexEnvironment: WorkspaceHermesCodexEnvironment(
                customBaseURLEnvironmentKey: HermesAgentCodexEnvironment.customBaseURLEnvironmentKey,
                defaultProvider: HermesAgentCodexEnvironment.defaultProvider,
                codexResponsesAPIMode: HermesAgentCodexEnvironment.codexResponsesAPIMode,
                applyingDefaultCodexBaseURL: { environment in
                    HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(to: environment)
                },
                resolvingDefaultCodexModel: { environment in
                    HermesAgentCodexEnvironment.defaultCodexModel(environment: environment)
                }
            )
        )
    }

    nonisolated private static func shouldRunPromptedSurfaceResume(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        guard Thread.isMainThread, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return false
        }
        return MainActor.assumeIsolated {
            shouldRunPromptedSurfaceResumeOnMain(binding)
        }
    }

    @MainActor
    private static func shouldRunPromptedSurfaceResumeOnMain(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        let promptBatch = SurfaceResumeRunPromptBatch.shared
        switch promptBatch.effectiveDecision {
        case .runAll:
            return true
        case .skipAll:
            return false
        case nil:
            break
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "surfaceResumeApproval.runPrompt.title",
            defaultValue: "Run Resume Command?"
        )
        let informativeText = String(
            format: String(
                localized: "surfaceResumeApproval.runPrompt.message",
                defaultValue: "cmux is restoring a terminal with this resume command:\n\nWorking directory: %@\n\n%@"
            ),
            binding.cwd ?? String(localized: "surfaceResumeApproval.cwd.none", defaultValue: "None"),
            binding.command
        )
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.runPrompt.run", defaultValue: "Run"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.runPrompt.runAll", defaultValue: "Run All"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.runPrompt.skip", defaultValue: "Skip"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.runPrompt.skipAll", defaultValue: "Skip All"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(
            localized: "surfaceResumeApproval.runPrompt.dontAskAgain",
            defaultValue: "Don’t ask again for this command"
        )
        let content = CmuxAlertContent(
            flattenedText: informativeText,
            separatingScrollableDetails: binding.command
        )
        let response = alert.runCmuxModal(content: content)
        let shouldRun: Bool
        if response == .alertFirstButtonReturn {
            shouldRun = true
        } else if response == .alertSecondButtonReturn {
            promptBatch.recordDecision(.runAll)
            shouldRun = true
        } else if response == .alertThirdButtonReturn {
            shouldRun = false
        } else if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
            promptBatch.recordDecision(.skipAll)
            shouldRun = false
        } else {
            shouldRun = false
        }

        if alert.suppressionButton?.state == .on {
            SurfaceResumeApprovalStore.approve(
                binding: binding,
                policy: shouldRun ? .auto : .manual
            )
        }
        return shouldRun
    }

    // MARK: - Initialization

    static func currentSplitButtonTooltips() -> BonsplitConfiguration.SplitButtonTooltips {
        BonsplitConfiguration.SplitButtonTooltips(
            newTerminal: KeyboardShortcutSettings.Action.newSurface.tooltip("New Terminal"),
            splitRight: KeyboardShortcutSettings.Action.splitRight.tooltip("Split Right"),
            splitDown: KeyboardShortcutSettings.Action.splitDown.tooltip("Split Down")
        )
    }

    nonisolated static func usesSharedSurfaceBackdrop(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "sidebarMatchTerminalBackground")
    }

    nonisolated static func usesWindowRootTerminalBackdrop() -> Bool {
        true
    }

    /// Identifies the Bonsplit host whose general background is being resolved.
    ///
    /// A workspace Bonsplit tree sits directly under the window backdrop and
    /// keeps its semantic chrome color for native tab treatment. A mounted Dock
    /// has a separate root hosting boundary, so its general background must be
    /// clear when the shared terminal backdrop owns the surface.
    enum BonsplitChromeHost: Equatable, Sendable {
        case workspace
        case dock
    }

    /// Resolves a terminal surface color against the rendered-backdrop
    /// authority. Opaque themes keep the terminal scheme; translucent themes
    /// composite over the window base the ambient appearance paints, so the
    /// resulting hex (and the black/white foregrounds Bonsplit derives from
    /// it) matches what is actually visible behind the tab strip.
    nonisolated static func resolvedTerminalChromeBackgroundColor(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        terminalColorScheme: ColorScheme,
        ambientColorScheme: ColorScheme
    ) -> NSColor {
        WindowAppearanceSnapshot.resolvedChromeBackgroundColor(
            backgroundColor: backgroundColor,
            opacity: backgroundOpacity,
            colorScheme: WindowAppearanceSnapshot.resolvedChromeColorScheme(
                terminalScheme: terminalColorScheme,
                backgroundColor: backgroundColor,
                opacity: backgroundOpacity,
                ambientScheme: ambientColorScheme
            )
        )
    }

    /// Convenience over the injectable seam above for live app state.
    /// Workspace/Bonsplit objects can be created before a SwiftUI
    /// `WindowAppearanceSnapshot` is mounted, so they use this composition
    /// seam instead of AppKit's ambient window appearance.
    @MainActor
    static func resolvedTerminalChromeBackgroundColor(
        backgroundColor: NSColor,
        backgroundOpacity: Double
    ) -> NSColor {
        resolvedTerminalChromeBackgroundColor(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            terminalColorScheme: GhosttyApp.shared.effectiveTerminalColorSchemePreference == .dark ? .dark : .light,
            ambientColorScheme: AppearanceSettings.currentAmbientColorScheme()
        )
    }

    nonisolated static func bonsplitChromeHex(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        sharesWindowBackdrop: Bool = false,
        chromeBackgroundColor: NSColor? = nil
    ) -> String {
        _ = sharesWindowBackdrop
        let themedColor = chromeBackgroundColor ?? WindowAppearanceSnapshot.compositedTerminalColor(
            backgroundColor: backgroundColor,
            opacity: backgroundOpacity
        )
        let includeAlpha = themedColor.alphaComponent < 0.999
        return themedColor.hexString(includeAlpha: includeAlpha)
    }

    nonisolated static func usesBonsplitPaneTerminalBackdrop(
        renderingMode: GhosttyTerminalBackdropRenderingMode,
        sharesWindowBackdrop: Bool
    ) -> Bool {
        // The window root backdrop owns terminal fills. Bonsplit pane fills
        // would add a second translucent layer under the Metal surface.
        return false
    }

    /// Resolves Bonsplit colors while keeping terminal backdrop ownership explicit.
    nonisolated static func bonsplitChromeColors(
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        sharesWindowBackdrop: Bool = false,
        renderingMode: GhosttyTerminalBackdropRenderingMode = .windowHostBackdrop,
        paneBorderColorHex: String? = nil,
        chromeBackgroundColor: NSColor? = nil,
        chromeHost: BonsplitChromeHost = .workspace
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        let surfaceHex = bonsplitChromeHex(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            chromeBackgroundColor: chromeBackgroundColor
        )
        let defaultBorderHex = WindowChromeColorResolver()
            .separatorColor(
                forChromeBackground: chromeBackgroundColor
                    ?? WindowAppearanceSnapshot.compositedTerminalColor(
                        backgroundColor: backgroundColor,
                        opacity: backgroundOpacity
                    )
            )
            .hexString(includeAlpha: true)
        let borderHex = PaneChromeSettings.resolvedPaneBorderHex(
            configuredHex: paneBorderColorHex,
            fallback: defaultBorderHex
        )

        // Keep this decision on the same owner plan used by terminal surfaces.
        // The Dock is the only Bonsplit host with an extra root fill between
        // clear panes and the window backdrop; its pre-snapshot configuration
        // remains opaque until a mounted snapshot can provide that backdrop.
        let terminalFillOwner = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: renderingMode,
            surfaceBackgroundColor: nil,
            defaultBackgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            usesBonsplitPaneBackdrop: usesBonsplitPaneTerminalBackdrop(
                renderingMode: renderingMode,
                sharesWindowBackdrop: sharesWindowBackdrop
            )
        ).owner
        let clearsDockGeneralBackground = chromeHost == .dock &&
            terminalFillOwner == .sharedWindowBackdrop
        let generalBackgroundHex = clearsDockGeneralBackground
            ? "#00000000"
            : surfaceHex

        if sharesWindowBackdrop {
            return .init(
                backgroundHex: generalBackgroundHex,
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000",
                borderHex: borderHex
            )
        }

        let paneBackgroundHex = usesBonsplitPaneTerminalBackdrop(
            renderingMode: renderingMode,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
            ? surfaceHex
            : "#00000000"
        return .init(
            backgroundHex: generalBackgroundHex,
            tabBarBackgroundHex: surfaceHex,
            splitButtonBackdropHex: surfaceHex,
            paneBackgroundHex: paneBackgroundHex,
            borderHex: borderHex
        )
    }

    nonisolated static func resolvedChromeColors(
        from backgroundColor: NSColor,
        sharesWindowBackdrop: Bool = false,
        renderingMode: GhosttyTerminalBackdropRenderingMode = .windowHostBackdrop,
        paneBorderColorHex: String? = nil
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        // Keep this signature aligned with bonsplitChromeHex for settings tests
        // and future background-image handling.
        let backgroundHex = backgroundColor.hexString()
        let defaultBorderHex = WindowChromeColorResolver()
            .separatorColor(forChromeBackground: backgroundColor)
            .hexString(includeAlpha: true)
        let borderHex = PaneChromeSettings.resolvedPaneBorderHex(
            configuredHex: paneBorderColorHex,
            fallback: defaultBorderHex
        )

        if sharesWindowBackdrop {
            return .init(
                backgroundHex: backgroundHex,
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000",
                borderHex: borderHex
            )
        }

        let paneBackgroundHex = usesBonsplitPaneTerminalBackdrop(
            renderingMode: renderingMode,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
            ? backgroundHex
            : "#00000000"
        return .init(
            backgroundHex: backgroundHex,
            tabBarBackgroundHex: backgroundHex,
            splitButtonBackdropHex: backgroundHex,
            paneBackgroundHex: paneBackgroundHex,
            borderHex: borderHex
        )
    }

    private static func bonsplitChromeColorsEqual(
        _ lhs: BonsplitConfiguration.Appearance.ChromeColors,
        _ rhs: BonsplitConfiguration.Appearance.ChromeColors
    ) -> Bool {
        lhs.backgroundHex == rhs.backgroundHex &&
            lhs.tabBarBackgroundHex == rhs.tabBarBackgroundHex &&
            lhs.splitButtonBackdropHex == rhs.splitButtonBackdropHex &&
            lhs.paneBackgroundHex == rhs.paneBackgroundHex &&
            lhs.borderHex == rhs.borderHex
    }

    private static func bonsplitChromeColorsLogDescription(
        _ colors: BonsplitConfiguration.Appearance.ChromeColors
    ) -> String {
        "bg=\(colors.backgroundHex ?? "nil") " +
            "tabBarBg=\(colors.tabBarBackgroundHex ?? "nil") " +
            "splitBackdrop=\(colors.splitButtonBackdropHex ?? "nil") " +
            "paneBg=\(colors.paneBackgroundHex ?? "nil") " +
            "border=\(colors.borderHex ?? "nil")"
    }

    private static func bonsplitAppearance(
        from backgroundColor: NSColor,
        backgroundOpacity: Double,
        tabTitleFontSize: CGFloat = 11
    ) -> BonsplitConfiguration.Appearance {
        let sharesWindowBackdrop = usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let chromeColors = Self.bonsplitChromeColors(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode,
            paneBorderColorHex: PaneChromeSettings.paneBorderColorHex(),
            chromeBackgroundColor: Self.resolvedTerminalChromeBackgroundColor(
                backgroundColor: backgroundColor,
                backgroundOpacity: backgroundOpacity
            )
        )
        return BonsplitConfiguration.Appearance(
            tabBarHeight: WindowChromeMetrics.bonsplitTabBarHeight,
            tabTitleFontSize: tabTitleFontSize,
            dividerHitExpansion: PortalSplitDividerRegion.dividerHitExpansion,
            splitButtonBackdropEffect: Self.bonsplitSplitButtonBackdropEffect(),
            splitButtonTooltips: Self.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: chromeColors,
            usesSharedBackdrop: sharesWindowBackdrop
        )
    }

    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        let sharesWindowBackdrop = Self.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let nextChromeColors = Self.bonsplitChromeColors(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode,
            paneBorderColorHex: PaneChromeSettings.paneBorderColorHex(),
            chromeBackgroundColor: Self.resolvedTerminalChromeBackgroundColor(
                backgroundColor: config.backgroundColor,
                backgroundOpacity: config.backgroundOpacity
            )
        )
        let nextTabTitleFontSize = config.surfaceTabBarFontSize
        let currentAppearance = bonsplitController.configuration.appearance
        let currentTabTitleFontSize = currentAppearance.tabTitleFontSize
        let colorsChanged = !Self.bonsplitChromeColorsEqual(
            currentAppearance.chromeColors,
            nextChromeColors
        )
        let sharedBackdropChanged = currentAppearance.usesSharedBackdrop != sharesWindowBackdrop
        let fontSizeChanged = abs(currentTabTitleFontSize - nextTabTitleFontSize) > 0.0001
        let isNoOp = !colorsChanged && !sharedBackdropChanged && !fontSizeChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "current=[\(Self.bonsplitChromeColorsLogDescription(currentAppearance.chromeColors))] " +
                "next=[\(Self.bonsplitChromeColorsLogDescription(nextChromeColors))] " +
                "currentTabFont=\(String(format: "%.3f", currentTabTitleFontSize)) " +
                "nextTabFont=\(String(format: "%.3f", nextTabTitleFontSize)) " +
                "sharesWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) " +
                "currentUsesSharedBackdrop=\(currentAppearance.usesSharedBackdrop ? 1 : 0) " +
                "paneBackdrop=\(Self.usesBonsplitPaneTerminalBackdrop(renderingMode: renderingMode, sharesWindowBackdrop: sharesWindowBackdrop) ? 1 : 0) " +
                "noop=\(isNoOp)"
            )
        }

        guard !isNoOp else { return }

        if colorsChanged {
            bonsplitController.configuration.appearance.chromeColors = nextChromeColors
        }
        if sharedBackdropChanged {
            bonsplitController.configuration.appearance.usesSharedBackdrop = sharesWindowBackdrop
        }
        if fontSizeChanged {
            bonsplitController.configuration.appearance.tabTitleFontSize = nextTabTitleFontSize
        }

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) " +
                "resulting=[\(Self.bonsplitChromeColorsLogDescription(bonsplitController.configuration.appearance.chromeColors))] " +
                "resultingUsesSharedBackdrop=\(bonsplitController.configuration.appearance.usesSharedBackdrop ? 1 : 0) " +
                "resultingTabFont=\(String(format: "%.3f", bonsplitController.configuration.appearance.tabTitleFontSize))"
            )
        }
    }

    func applyGhosttyChrome(backgroundColor: NSColor, backgroundOpacity: Double, reason: String = "unspecified") {
        let sharesWindowBackdrop = Self.usesWindowRootTerminalBackdrop()
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let nextChromeColors = Self.bonsplitChromeColors(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            renderingMode: renderingMode,
            paneBorderColorHex: PaneChromeSettings.paneBorderColorHex(),
            chromeBackgroundColor: Self.resolvedTerminalChromeBackgroundColor(
                backgroundColor: backgroundColor,
                backgroundOpacity: backgroundOpacity
            )
        )
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let currentUsesSharedBackdrop = bonsplitController.configuration.appearance.usesSharedBackdrop
        let colorsChanged = !Self.bonsplitChromeColorsEqual(currentChromeColors, nextChromeColors)
        let sharedBackdropChanged = currentUsesSharedBackdrop != sharesWindowBackdrop
        let isNoOp = !colorsChanged && !sharedBackdropChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "current=[\(Self.bonsplitChromeColorsLogDescription(currentChromeColors))] " +
                "next=[\(Self.bonsplitChromeColorsLogDescription(nextChromeColors))] " +
                "sharesWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) " +
                "currentUsesSharedBackdrop=\(currentUsesSharedBackdrop ? 1 : 0) " +
                "paneBackdrop=\(Self.usesBonsplitPaneTerminalBackdrop(renderingMode: renderingMode, sharesWindowBackdrop: sharesWindowBackdrop) ? 1 : 0) " +
                "noop=\(isNoOp)"
            )
        }

        if isNoOp {
            return
        }
        if colorsChanged {
            bonsplitController.configuration.appearance.chromeColors = nextChromeColors
        }
        if sharedBackdropChanged {
            bonsplitController.configuration.appearance.usesSharedBackdrop = sharesWindowBackdrop
        }
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) " +
                "resulting=[\(Self.bonsplitChromeColorsLogDescription(bonsplitController.configuration.appearance.chromeColors))] " +
                "resultingUsesSharedBackdrop=\(bonsplitController.configuration.appearance.usesSharedBackdrop ? 1 : 0)"
            )
        }
    }

    init(
        id: UUID? = nil,
        title: String = "Terminal",
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalStartupRestoreAgent: SessionRestorableAgentSnapshot? = nil,
        initialTerminalStartupRestoreCommitOwner: WorkspaceTerminalStartupRestoreCommitOwner = .workspaceTopology,
        initialTerminalEnvironment: [String: String] = [:],
        workspaceEnvironment: [String: String] = [:],
        allowTextBoxFocusDefault: Bool = true,
        tabDragTransferRegistry: TabDragTransferRegistry? = nil,
        settings: any SettingsReading = UserDefaultsSettingsClient(defaults: .standard),
        closeTabWarningDefaults: UserDefaults = .standard,
        agentSessionAutoResumeDefaults: UserDefaults = .standard,
        initialDetachedSurface: DetachedSurfaceTransfer? = nil,
        sessionRestorePolicy: WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot>? = nil,
        sidebarProcessTitleObservation: WorkspaceSidebarProcessTitleObservationModel? = nil,
        agentChatResumeIntentRecorder: any AgentChatResumeIntentRecording = AgentChatTranscriptResumeIntentRecorder(),
        fileContentChangeCoordinator: FileContentChangeCoordinator? = nil,
        restorableAgentIndexProvider: (@MainActor () -> RestorableAgentSessionIndex?)? = nil
    ) {
        let tabDragTransferRegistry = tabDragTransferRegistry ?? TabDragTransferRegistry()
        let resolvedID = id ?? UUID()
        let restoredAgentLifecycle = RestoredAgentLifecycleCoordinator()
        let resolvedRestorableAgentIndexProvider: @MainActor () -> RestorableAgentSessionIndex? =
            restorableAgentIndexProvider ?? {
                SharedLiveAgentIndex.shared.currentIndexForOwnershipSensitiveRestore()
            }
        self.id = resolvedID
        self.sessionRestorePolicy = sessionRestorePolicy ?? Self.makeSessionRestorePolicyService()
        self.sidebarProcessTitleObservation = sidebarProcessTitleObservation ?? WorkspaceSidebarProcessTitleObservationModel()
        self.settings = settings
        self.closeTabWarningDefaults = closeTabWarningDefaults
        self.agentSessionAutoResumeDefaults = agentSessionAutoResumeDefaults
        self.agentChatResumeIntentRecorder = agentChatResumeIntentRecorder
        self.restorableAgentIndexProvider = resolvedRestorableAgentIndexProvider
        self.tabDragTransferRegistry = tabDragTransferRegistry
        self.fileContentChangeCoordinator =
            fileContentChangeCoordinator ?? FileContentChangeCoordinator()
        self.terminalStartupRestoreCoordinator = TerminalStartupRestoreCoordinator(
            workspaceID: resolvedID,
            lifecycle: restoredAgentLifecycle,
            resumeIntentRecorder: agentChatResumeIntentRecorder
        )
        let sanitizedWorkspaceEnvironment = Self.sanitizedWorkspaceEnvironment(workspaceEnvironment)
        self.workspaceEnvironment = sanitizedWorkspaceEnvironment
        self.portOrdinal = portOrdinal
        self.processTitle = title
        self.title = title
        self.customTitle = nil
        self.customTitleSource = nil
        self.customDescription = nil

        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        let initialDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path
        self.currentDirectory = initialDirectory
        self.surfaceTabBarDirectory = initialDirectory

        // Preserve terminal state and inherit tab-strip sizing without repeated config parsing.
        let initialSurfaceTabBarFontSize = GhosttyConfig.loadForCmux(globalFontMagnificationPercent: GlobalFontMagnification.storedPercent).surfaceTabBarFontSize
        let appearance = Self.bonsplitAppearance(
            from: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            tabTitleFontSize: initialSurfaceTabBarFontSize
        )
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: !CloseTabWarningStore(defaults: closeTabWarningDefaults).hidesTabCloseButton,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            appearance: appearance
        )
        self.bonsplitController = BonsplitController(
            configuration: config,
            tabDragTransferRegistry: tabDragTransferRegistry
        )
        paneTree.attach(host: self)
        surfaceList.attach(tree: self)
        bonsplitController.contextMenuShortcuts = Self.buildContextMenuShortcuts()

        // Remove the default "Welcome" tab that bonsplit creates
        let welcomeTabIds = bonsplitController.allTabIds

        // When the workspace boots with an explicit initial command, hold the PTY
        // open after that command exits so its output stays readable.
        var resolvedConfigTemplate = configTemplate
        if let trimmedCommand = initialTerminalCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedCommand.isEmpty {
            var template = resolvedConfigTemplate ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            resolvedConfigTemplate = template
        }

        var initialTabId: TabID?
        if let initialDetachedSurface {
            if let initialPaneId = bonsplitController.allPaneIds.first,
               attachDetachedSurface(initialDetachedSurface, inPane: initialPaneId, focus: false) != nil {
                initialTabId = surfaceIdFromPanelId(initialDetachedSurface.panelId)
            }
        } else {
            // Create initial terminal panel
            let terminalPanel = TerminalPanel(
                workspaceId: self.id,
                context: GHOSTTY_SURFACE_CONTEXT_TAB,
                configTemplate: resolvedConfigTemplate,
                workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil,
                portOrdinal: portOrdinal,
                initialCommand: initialTerminalCommand,
                initialInput: initialTerminalInput,
                initialEnvironmentOverrides: Self.startupEnvironment(
                    workspaceEnvironment: sanitizedWorkspaceEnvironment,
                    overlaying: initialTerminalEnvironment
                ),
                runtimeSpawnPolicy: terminalStartupRestoreCoordinator.runtimeSpawnPolicy(
                    requestedPolicy: .immediate,
                    willRunStartupCommand: false,
                    willRunStartupInput:
                        initialTerminalStartupRestoreAgent != nil && initialTerminalInput != nil
                )
            )
            configureNewTerminalPanel(
                terminalPanel,
                allowTextBoxFocusDefault: allowTextBoxFocusDefault
            )
            panels[terminalPanel.id] = terminalPanel
            panelTitles[terminalPanel.id] = terminalPanel.displayTitle

            // Create initial tab in bonsplit and store the mapping
            if let tabId = bonsplitController.createTab(
                title: title,
                icon: "terminal.fill",
                kind: SurfaceKind.terminal.rawValue,
                isDirty: false,
                isPinned: false
            ) {
                bindSurface(tabId, toPanelId: terminalPanel.id)
                initialTabId = tabId
                rememberTerminalConfigInheritanceSource(terminalPanel)
                if let initialTerminalStartupRestoreAgent {
                    terminalStartupRestoreCoordinator.stage(
                        panel: terminalPanel,
                        snapshot: initialTerminalStartupRestoreAgent,
                        manualResumeAvailable: true,
                        willRunStartupCommand: false,
                        willRunStartupInput: initialTerminalInput != nil,
                        resumeWorkingDirectory: initialTerminalStartupRestoreAgent.workingDirectory
                    )
                    if initialTerminalStartupRestoreCommitOwner == .workspaceTopology {
                        terminalStartupRestoreCoordinator.commitPendingRestores(
                            panelIDs: [terminalPanel.id]
                        )
                    }
                }
            } else if initialTerminalStartupRestoreAgent != nil {
                panels.removeValue(forKey: terminalPanel.id)
                panelTitles.removeValue(forKey: terminalPanel.id)
                terminalPanel.surface.teardownSurface()
            }
        }

        // Close the default Welcome tab(s)
        for welcomeTabId in welcomeTabIds {
            bonsplitController.closeTab(welcomeTabId)
        }

        bonsplitController.onExternalTabDrop = { [weak self] request in
            self?.handleExternalTabDrop(request) ?? false
        }
        bonsplitController.onExternalFileDrop = { [weak self] request in
            self?.handleExternalFileDrop(request) ?? false
        }
        bonsplitController.tabContextMoveDestinationsProvider = { [weak self] tabId, _ in
            self?.bonsplitTabMoveDestinations(for: tabId) ?? []
        }
        configureForkAgentConversationContextMenuAvailability()
        bonsplitController.tabContextForkConversationDefaultActionProvider = { _, _ in
            AgentConversationForkDefaultSettings.current().tabContextAction
        }
        bonsplitController.onTabCloseRequest = { [weak self] tabId, _, source in
            switch source {
            case .closeButton:
                self?.markTabCloseButtonClose(surfaceId: tabId)
            case .middleClick:
                self?.markTabStripMiddleClickClose(surfaceId: tabId)
            }
        }
        bonsplitController.onTabZoomToggleRequest = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return false }
            return self.toggleSplitZoom(panelId: panelId)
        }
        bonsplitController.onTabFullWidthToggleRequest = { [weak self] tabId, _ in
            guard let self,
                  let panelId = self.panelIdFromSurfaceId(tabId) else { return false }
            return self.toggleFullWidthTabMode(panelId: panelId)
        }

        // Set ourselves as delegate
        bonsplitController.delegate = self

        // Ensure bonsplit has a focused pane and our didSelectTab handler runs for the
        // initial terminal. bonsplit's createTab selects internally but does not emit
        // didSelectTab, and focusedPaneId can otherwise be nil until user interaction.
        if let initialTabId, initialDetachedSurface == nil {
            // Focus the pane containing the initial tab (or the first pane as fallback).
            let paneToFocus: PaneID? = {
                for paneId in bonsplitController.allPaneIds {
                    if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == initialTabId }) {
                        return paneId
                    }
                }
                return bonsplitController.allPaneIds.first
            }()
            if let paneToFocus {
                bonsplitController.focusPane(paneToFocus)
            }
            bonsplitController.selectTab(initialTabId)
        }
        tmuxLayoutSnapshot = bonsplitController.layoutSnapshot()
        scheduleExtensionSidebarProjectRootRefresh(for: currentDirectory)

        // Forward shared agent-index refreshes so the bonsplit tab-bar re-evaluates
        // Fork Conversation availability when a background refresh lands.
        sharedLiveAgentIndexObserver = NotificationCenter.default.addObserver(
            forName: .sharedLiveAgentIndexDidChange,
            object: SharedLiveAgentIndex.shared,
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, !self.isRetiredFromOwningTabManager else { return }
                if let index = SharedLiveAgentIndex.shared.index {
                    let completedPanelIds: [UUID]
                    if let panelIdsByWorkspaceId = notification.userInfo?["panelIdsByWorkspaceId"] as? [UUID: Set<UUID>] {
                        guard let changedPanelIds = panelIdsByWorkspaceId[self.id] else {
                            return
                        }
                        completedPanelIds = changedPanelIds.filter { panelId in
                            self.restoredAgentResumeStatesByPanelId[panelId] == .completedAgentExit
                        }
                    } else if let changedWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                              changedWorkspaceId != self.id {
                        return
                    } else if let changedPanelId = notification.userInfo?["panelId"] as? UUID {
                        completedPanelIds = self.restoredAgentResumeStatesByPanelId[changedPanelId] == .completedAgentExit
                            ? [changedPanelId]
                            : []
                    } else {
                        completedPanelIds = self.restoredAgentResumeStatesByPanelId.compactMap { panelId, state in
                            state == .completedAgentExit ? panelId : nil
                        }
                    }
                    for panelId in completedPanelIds {
                        guard let observation = index.entry(workspaceId: self.id, panelId: panelId) else {
                            continue
                        }
                        self.reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
                    }
                }
                self.objectWillChange.send()
            }
        }
        featureFlagsObserver = NotificationCenter.default.addObserver(
            forName: .cmuxFeatureFlagsDidChange,
            object: CmuxFeatureFlags.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isRetiredFromOwningTabManager else { return }
                self.reapplySurfaceTabBarButtonsForFeatureFlags()
            }
        }
    }

    private var sharedLiveAgentIndexObserver: NSObjectProtocol?

    deinit {
        for registrations in pendingTerminalInputObserversByPanelId.values {
            for registration in registrations {
                if let observer = registration.observer {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        if let sharedLiveAgentIndexObserver {
            NotificationCenter.default.removeObserver(sharedLiveAgentIndexObserver)
        }
        if let featureFlagsObserver {
            NotificationCenter.default.removeObserver(featureFlagsObserver)
        }
        deferredAgentResumeIndexTask?.cancel()
        PortScanner.shared.scheduleAgentWorkspaceUnregistration(workspaceId: id)
    }

    func refreshSplitButtonTooltips() {
        let tooltips = Self.currentSplitButtonTooltips()
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtonTooltips != tooltips else { return }
        configuration.appearance.splitButtonTooltips = tooltips
        bonsplitController.configuration = configuration
    }

    func refreshSplitButtonBackdropEffect() {
        var configuration = bonsplitController.configuration
        configuration.appearance.splitButtonBackdropEffect = Self.bonsplitSplitButtonBackdropEffect()
        bonsplitController.configuration = configuration
    }

    func refreshTabCloseButtonVisibility() {
        let allowCloseTabs = !CloseTabWarningStore(defaults: closeTabWarningDefaults).hidesTabCloseButton
        var configuration = bonsplitController.configuration
        guard configuration.allowCloseTabs != allowCloseTabs else { return }
        configuration.allowCloseTabs = allowCloseTabs
        bonsplitController.configuration = configuration
    }

    func applySurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        sourcePath: String?,
        globalConfigPath: String,
        terminalCommandSourcePaths: [String: String],
        workspaceCommands: [String: CmuxResolvedCommand]
    ) {
        surfaceTabBarButtonConfiguration = SurfaceTabBarButtonConfiguration(
            buttons: buttons,
            sourcePath: sourcePath,
            globalConfigPath: globalConfigPath,
            terminalCommandSourcePaths: terminalCommandSourcePaths,
            workspaceCommands: workspaceCommands
        )
        let buttons = buttons.filter { button in
            guard case .builtIn(let builtInAction) = button.action else { return true }
            if builtInAction == .newAgentChat { return CmuxFeatureFlags.shared.isAgentChatUIEnabled }
            if builtInAction == .newSimulator { return CmuxFeatureFlags.shared.isSimulatorEnabled }
            return true
        }
        let executableButtons = Dictionary(
            uniqueKeysWithValues: buttons.compactMap { button in
                if button.terminalCommand != nil {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: button.actionSourcePath ?? terminalCommandSourcePaths[button.id]
                        )
                    )
                }
                if let workspaceCommand = workspaceCommands[button.id] {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: workspaceCommand,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                if button.action.inlineWorkspace != nil {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                if case .builtIn(let builtInAction) = button.action,
                   builtInAction.bonsplitAction == nil {
                    return (
                        button.id,
                        SurfaceTabBarExecutableButton(
                            button: button,
                            builtInAction: builtInAction,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                return nil
            }
        )
        surfaceTabBarCommandButtons = executableButtons
        surfaceTabBarButtonSourcePath = sourcePath
        surfaceTabBarButtonGlobalConfigPath = globalConfigPath

        let bonsplitButtons = buttons.map { button in
            let executable = executableButtons[button.id]
            let allowProjectLocalIcon = executable.map {
                CmuxConfigExecutor.isTrustedSurfaceButton(
                    $0.button,
                    workspaceCommand: $0.workspaceCommand,
                    terminalCommandSourcePath: $0.terminalCommandSourcePath,
                    surfaceTabBarConfigSourcePath: sourcePath,
                    globalConfigPath: globalConfigPath
                )
            } ?? true
            return button.bonsplitActionButton(
                configSourcePath: sourcePath,
                globalConfigPath: globalConfigPath,
                allowProjectLocalIcon: allowProjectLocalIcon
            )
        }
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtons != bonsplitButtons else { return }
        configuration.appearance.splitButtons = bonsplitButtons
        bonsplitController.configuration = configuration
    }

    private func reapplySurfaceTabBarButtonsForFeatureFlags() {
        guard let configuration = surfaceTabBarButtonConfiguration else { return }
        applySurfaceTabBarButtons(
            configuration.buttons,
            sourcePath: configuration.sourcePath,
            globalConfigPath: configuration.globalConfigPath,
            terminalCommandSourcePaths: configuration.terminalCommandSourcePaths,
            workspaceCommands: configuration.workspaceCommands
        )
    }

    // MARK: - Surface ID to Panel ID Mapping

    /// Mapping from bonsplit TabID (surface id) to the owning panel id;
    /// stored in the pane-tree sub-model.
    var surfaceIdToPanelId: [TabID: UUID] {
        paneTree.surfaceIdToPanelId
    }

    /// Registers a bonsplit surface as the active owner for a panel.
    func bindSurface(_ surfaceId: TabID, toPanelId panelId: UUID) {
        paneTree.bindSurface(surfaceId, toPanelId: panelId)
    }

    /// Removes one bonsplit surface mapping.
    func removeSurfaceMapping(forSurfaceId surfaceId: TabID) {
        paneTree.removeSurfaceMapping(forSurfaceId: surfaceId)
    }

    /// Removes every bonsplit surface mapping for a closed panel.
    func removeSurfaceMappings(forPanelId panelId: UUID) {
        paneTree.removeSurfaceMappings(forPanelId: panelId)
    }

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    /// This is used by app-level confirmation prompts (for example, Close Tab) so the
    /// Bonsplit delegate doesn't block the close after the user already confirmed.
    private var forceCloseTabIds: Set<TabID> = []

    /// Tab IDs that are currently showing (or about to show) a close confirmation prompt.
    /// Prevents repeated close gestures (e.g., middle-click spam) from stacking dialogs.
    private var pendingCloseConfirmTabIds: Set<TabID> = []

    /// User-initiated close attempts, distinct from internal close/move flows.
    private var explicitUserCloseTabIds: Set<TabID> = []
    private var closeHistoryEligibleTabIds: Set<TabID> = []
    private var closeHistoryEligiblePanelIds: Set<UUID> = []
    private var suppressClosedPanelHistory = false
    /// Stable identities not re-adopted by the in-flight snapshot restore.
    let sessionRestoreIdentityExclusions = SessionRestoreIdentityExclusions()
    private var tabStripCloseButtonByTabId: [TabID: Bool] = [:]
    /// Deterministic tab selection to apply after a tab closes, keyed by closing tab ID.
    private var postCloseSelectTabId: [TabID: TabID] = [:]
    private var postCloseClearSplitZoomTabIds: Set<TabID> = []
    /// Panel IDs that were in a pane when a pane-close operation was approved.
    /// Bonsplit pane-close does not emit per-tab didClose callbacks.
    private var pendingPaneClosePanelIds: [UUID: [UUID]] = [:]
    private var pendingPaneCloseHistoryEntries: [UUID: [ClosedPanelHistoryEntry]] = [:]
    /// Re-entrancy guard for the tab-selection apply loop; stored in the
    /// surface-registry sub-model.
    private var isApplyingTabSelection: Bool {
        get { surfaceRegistry.isApplyingTabSelection }
        set { surfaceRegistry.isApplyingTabSelection = newValue }
    }
    /// The pending tab-selection request payload. Stays app-side (it carries
    /// AppKit hosted-view references); the surface-registry sub-model stores
    /// it opaquely as its `TabSelectionRequest` generic binding.
    struct PendingTabSelectionRequest {
        let tabId: TabID
        let pane: PaneID
        let reassertAppKitFocus: Bool
        let focusIntent: PanelFocusIntent?
        let resumeHibernatedAgent: Bool?
        let focusTransactionId: UUID?
        let previousTerminalHostedView: GhosttySurfaceScrollView?
    }
    /// The coalesced pending tab-selection request; stored in the
    /// surface-registry sub-model.
    private var pendingTabSelection: PendingTabSelectionRequest? {
        get { surfaceRegistry.pendingTabSelection }
        set { surfaceRegistry.pendingTabSelection = newValue }
    }
    private(set) var activeFocusTransactionId: UUID?
    private var isReconcilingFocusState = false
    private var focusReconcileScheduled = false
#if DEBUG
    private(set) var debugFocusReconcileScheduledDuringDetachCount: Int = 0
    private var debugLastDidMoveTabTimestamp: TimeInterval = 0
    private var debugDidMoveTabEventCount: UInt64 = 0
#endif
    private var layoutFollowUpObservers: [NSObjectProtocol] = []
    private var layoutFollowUpPanelsCancellable: AnyCancellable?
    private let layoutFollowUpTimeoutScheduler = MainActorDeferredActionScheduler()
    private let geometryNotificationScheduler = MainActorDeferredActionScheduler()
    private var layoutFollowUpReason: String?
    private var layoutFollowUpTerminalFocusPanelId: UUID?
    private var layoutFollowUpNeedsGeometryPass = false
    private var layoutFollowUpAttemptScheduled = false
    private var layoutFollowUpAttemptVersion: Int = 0
    private var layoutFollowUpStalledAttemptCount = 0
    private var pendingReparentFocusSuppressionViews: [ObjectIdentifier: GhosttySurfaceScrollView] = [:]
    private var portalRenderingEnabled = true
    var isPortalRenderingEnabled: Bool { portalRenderingEnabled }
    private var agentHibernationAutoResumePresentationVisible = true
    private var isAttemptingLayoutFollowUp = false
    private var isNormalizingPinnedTabOrder = false
    /// The pending non-focusing-split focus re-assert request (the value
    /// type now lives in CmuxWorkspaceCore); stored in the surface-registry
    /// sub-model.
    private var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert? {
        get { surfaceRegistry.pendingNonFocusSplitFocusReassert }
        set { surfaceRegistry.pendingNonFocusSplitFocusReassert = newValue }
    }
    /// Monotonic focus re-assert generation counter; stored in the
    /// surface-registry sub-model.
    private var nonFocusSplitFocusReassertGeneration: UInt64 {
        get { surfaceRegistry.nonFocusSplitFocusReassertGeneration }
        set { surfaceRegistry.nonFocusSplitFocusReassertGeneration = newValue }
    }
    /// Captured detach transfer payloads; stored in the split-layout
    /// sub-model. Mutations go through the model's detach-choreography
    /// verbs; this read-only view feeds the empty/count checks.
    private var pendingDetachedSurfaces: [TabID: DetachedSurfaceTransfer] {
        splitLayout.pendingDetachedSurfaces
    }
    /// Open detach-close transaction count; stored in the split-layout
    /// sub-model, mutated through its transaction verbs.
    private var activeDetachCloseTransactions: Int {
        splitLayout.activeDetachCloseTransactions
    }
    private var isDetachingCloseTransaction: Bool { splitLayout.isDetachingCloseTransaction }

#if DEBUG
    func debugElapsedMs(since start: TimeInterval) -> String {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.2f", ms)
    }
#endif

    func markExplicitClose(surfaceId: TabID) {
        explicitUserCloseTabIds.insert(surfaceId)
        closeHistoryEligibleTabIds.insert(surfaceId)
        if let panelId = panelIdFromSurfaceId(surfaceId) {
            closeHistoryEligiblePanelIds.insert(panelId)
        }
    }

    func markCloseHistoryEligible(panelId: UUID) {
        closeHistoryEligiblePanelIds.insert(panelId)
        if let surfaceId = surfaceIdFromPanelId(panelId) {
            closeHistoryEligibleTabIds.insert(surfaceId)
        }
    }

    @discardableResult
    func requestCloseTabRecordingHistory(_ tabId: TabID, force: Bool) -> Bool {
        let panelId = panelIdFromSurfaceId(tabId)
        if let panelId {
            markCloseHistoryEligible(panelId: panelId)
        }

        return requestCloseTab(tabId, force: force)
    }

    /// Non-interactive socket/API close path.
    @discardableResult
    func requestNonInteractiveCloseTabRecordingHistory(_ tabId: TabID) -> Bool {
        requestCloseTabRecordingHistory(tabId, force: true)
    }

    func withClosedPanelHistorySuppressed(_ body: () -> Void) {
        let previous = suppressClosedPanelHistory
        suppressClosedPanelHistory = true
        defer { suppressClosedPanelHistory = previous }
        body()
    }
    func markTabCloseButtonClose(surfaceId: TabID) {
        markExplicitClose(surfaceId: surfaceId)
        tabStripCloseButtonByTabId[surfaceId] = true
    }
    func markTabStripMiddleClickClose(surfaceId: TabID) {
        markExplicitClose(surfaceId: surfaceId)
        tabStripCloseButtonByTabId[surfaceId] = false
    }
    func configureNewTerminalPanel(
        _ terminalPanel: TerminalPanel,
        allowTextBoxFocusDefault: Bool = true
    ) {
        // Record the workspace env this freshly-created panel inherited, so a later
        // respawn (which reuses this panel even after a move to another workspace)
        // can drop it and re-apply the current workspace's env instead of leaking
        // the source workspace's (#5995). Only creation runs through here — attach
        // uses configureTerminalPanel — so it keeps reflecting the workspace the
        // surface's env was built from until the panel is respawned.
        terminalPanel.seededWorkspaceEnvironment = workspaceEnvironment
        if TerminalTextBoxInputSettings.focusOnNewTerminals(), allowTextBoxFocusDefault {
            terminalPanel.preferTextBoxInputWhenActivated()
        } else if TerminalTextBoxInputSettings.focusOnNewTerminals() {
            terminalPanel.showTextBoxInputWhenAvailable()
        } else if TerminalTextBoxInputSettings.showOnNewTerminals() {
            terminalPanel.showTextBoxInputWhenAvailable()
        }
        configureTerminalPanel(terminalPanel)
    }

    private func configureTerminalPanel(_ terminalPanel: TerminalPanel) {
        terminalPanel.surface.onFontSizeLineageChanged = { [weak self, weak terminalPanel] lineage in
            guard let self, let terminalPanel,
                  self.lastTerminalConfigInheritancePanelId == terminalPanel.id,
                  let mountedPanel = self.panels[terminalPanel.id] as? TerminalPanel,
                  mountedPanel === terminalPanel else {
                return
            }
            self.lastTerminalConfigInheritanceFontSizeLineage = lineage
        }
        installTerminalVisualBellRouting(for: terminalPanel)
        terminalPanel.onRequestWorkspacePaneFlash = { [weak self, weak terminalPanel] reason in
            guard let self, let terminalPanel else { return }
            let panelID = self.surfaceOwnershipTarget(for: terminalPanel.id)?.containerPanelID
                ?? terminalPanel.id
            self.triggerWorkspacePaneFlash(panelId: panelID, reason: reason)
        }
        terminalPanel.onRequestAgentHibernationResume = { [weak self, weak terminalPanel] focus in
            guard let self, let terminalPanel else { return false }
            return self.resumeAgentHibernation(panelId: terminalPanel.id, focus: focus)
        }
    }

    private func triggerWorkspacePaneFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        tmuxWorkspaceFlashPanelId = panelId
        tmuxWorkspaceFlashReason = reason
        tmuxWorkspaceFlashToken &+= 1
    }

    private func installMarkdownPanelSubscription(_ markdownPanel: MarkdownPanel) {
        let subscription = Publishers.CombineLatest(
            markdownPanel.$displayTitle.removeDuplicates(),
            markdownPanel.$isDirty.removeDuplicates()
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak markdownPanel] newTitle, isDirty in
                guard let self,
                      let markdownPanel,
                      let tabId = self.surfaceIdFromPanelId(markdownPanel.id) else { return }
                guard let existing = self.bonsplitController.tab(tabId) else { return }

                if self.panelTitles[markdownPanel.id] != newTitle {
                    self.panelTitles[markdownPanel.id] = newTitle
                }
                let resolvedTitle = self.resolvedPanelTitle(panelId: markdownPanel.id, fallback: newTitle)
                let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
                let dirtyUpdate: Bool? = existing.isDirty == isDirty ? nil : isDirty
                guard titleUpdate != nil || dirtyUpdate != nil else { return }
                self.bonsplitController.updateTab(
                    tabId,
                    title: titleUpdate,
                    hasCustomTitle: self.panelCustomTitles[markdownPanel.id] != nil,
                    isDirty: dirtyUpdate
                )
            }
        panelSubscriptions[markdownPanel.id] = subscription
    }

    /// Resolves the workspace tab currently owned by a file-preview panel.
    func filePreviewTabId(forPanelId panelId: UUID) -> TabID? {
        surfaceIdFromPanelId(panelId)
    }

    /// Preserves workspace custom-title policy while refreshing panel metadata.
    func filePreviewTabTitlePresentation(
        for metadata: FilePreviewTabMetadata,
        panelId: UUID,
        existingTab _: Bonsplit.Tab
    ) -> (title: String?, hasCustomTitle: Bool?) {
        if panelTitles[panelId] != metadata.title {
            panelTitles[panelId] = metadata.title
        }
        return (
            resolvedPanelTitle(panelId: panelId, fallback: metadata.title),
            panelCustomTitles[panelId] != nil
        )
    }

    private func installAgentSessionPanelSubscription(_ agentPanel: AgentSessionPanel) {
        agentPanel.onDisplayStateChanged = { [weak self, weak agentPanel] newTitle, isDirty in
            guard let self,
                  let agentPanel,
                  let tabId = self.surfaceIdFromPanelId(agentPanel.id) else { return }
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            if self.panelTitles[agentPanel.id] != newTitle {
                self.panelTitles[agentPanel.id] = newTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: agentPanel.id, fallback: newTitle)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let dirtyUpdate: Bool? = existing.isDirty == isDirty ? nil : isDirty
            guard titleUpdate != nil || dirtyUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                hasCustomTitle: self.panelCustomTitles[agentPanel.id] != nil,
                isDirty: dirtyUpdate
            )
        }
        agentSessionPanelCallbackIds.insert(agentPanel.id)
    }

    func discardAgentSessionPanelSubscription(panelId: UUID, panel: (any Panel)?) {
        if let agentPanel = panel as? AgentSessionPanel {
            agentPanel.onDisplayStateChanged = nil
        }
        agentSessionPanelCallbackIds.remove(panelId)
    }

    // MARK: - Panel Access

    func panel(for surfaceId: TabID) -> (any Panel)? {
        guard let panelId = panelIdFromSurfaceId(surfaceId) else { return nil }
        return panels[panelId]
    }

    func terminalPanel(for panelId: UUID) -> TerminalPanel? {
        panels[panelId] as? TerminalPanel
    }

    func markdownPanel(for panelId: UUID) -> MarkdownPanel? {
        panels[panelId] as? MarkdownPanel
    }

    func filePreviewPanel(for panelId: UUID) -> FilePreviewPanel? {
        panels[panelId] as? FilePreviewPanel
    }

    /// The working directory app-level actions (diff viewer, configured commands)
    /// should target for this workspace: the focused panel's tracked directory, then
    /// its terminal's requested directory, then the workspace's current directory.
    /// Returns `nil` when none is known so callers can apply their own fallback.
    ///
    /// This is the focused-panel case of ``configTrackingDirectory(for:)`` (the same
    /// three-tier order); the tiers are spelled out here so the public entry point is
    /// self-contained.
    func resolvedWorkingDirectory() -> String? {
        let candidates = [
            focusedPanelId.flatMap { panelDirectories[$0] },
            focusedPanelId.flatMap { terminalPanel(for: $0)?.requestedWorkingDirectory },
            currentDirectory,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    func resolvedPanelTitle(panelId: UUID, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedFallback.isEmpty ? "Tab" : trimmedFallback
        if let custom = panelCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return fallbackTitle
    }

    private func syncPinnedStateForTab(_ tabId: TabID, panelId: UUID) {
        let isPinned = pinnedPanelIds.contains(panelId)
        let kind = panels[panelId].map { surfaceKind(for: $0) }
        if let tab = bonsplitController.tab(tabId),
           tab.isPinned == isPinned,
           kind.map({ tab.kind == $0 }) ?? true {
            return
        }
        if let kind {
            bonsplitController.updateTab(tabId, kind: .some(kind), isPinned: isPinned)
        } else {
            bonsplitController.updateTab(tabId, isPinned: isPinned)
        }
    }

    private func hasVisibleNotificationIndicator(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasVisibleNotificationIndicator(forTabId: id, surfaceId: panelId) ?? false
    }

    private func attentionPersistentState() -> WorkspaceAttentionPersistentState {
        let notificationStore = AppDelegate.shared?.notificationStore
        let unreadPanelIDs = Set(
            panels.keys.filter {
                restoredUnreadPanelIds.contains($0) ||
                    (notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: $0) ?? false)
            }
        )
        return WorkspaceAttentionPersistentState(
            unreadPanelIDs: unreadPanelIDs,
            focusedReadPanelID: notificationStore?.focusedReadIndicatorSurfaceId(forTabId: id),
            manualUnreadPanelIDs: manualUnreadPanelIds
        )
    }

    func requestAttentionFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        let decision = WorkspaceAttentionCoordinator.decideFlash(
            targetPanelID: panelId,
            reason: reason,
            persistentState: attentionPersistentState()
        )
        guard decision.isAllowed else { return }
        panels[panelId]?.triggerFlash(reason: reason)
    }

    private func syncUnreadBadgeStateForPanel(_ panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let notificationStore = AppDelegate.shared?.notificationStore
        let shouldShowUnread = Self.shouldShowUnreadIndicator(
            hasUnreadNotification: hasVisibleNotificationIndicator(panelId: panelId),
            hasPanelUnreadIndicator: manualUnreadPanelIds.contains(panelId) || restoredUnreadPanelIds.contains(panelId),
            isWorkspaceManuallyUnread: notificationStore?.hasManualUnread(forTabId: id) ?? false,
            isWorkspaceManualUnreadRepresentative: representativePanelIdForWorkspaceManualUnread() == panelId
        )
        if let existing = bonsplitController.tab(tabId), existing.showsNotificationBadge == shouldShowUnread {
            return
        }
        bonsplitController.updateTab(tabId, showsNotificationBadge: shouldShowUnread)
    }

    private func syncUnreadBadgeStateForAllPanels() {
        for panelId in panels.keys {
            syncUnreadBadgeStateForPanel(panelId)
        }
    }

    func syncPanelDerivedWorkspaceUnread() {
        AppDelegate.shared?.notificationStore?.setPanelDerivedUnread(
            !manualUnreadPanelIds.isEmpty ||
                hasWorkspaceContributingRestoredUnreadIndicator,
            forTabId: id
        )
    }

    var hasWorkspaceContributingRestoredUnreadIndicator: Bool {
        restoredUnreadPanelIndicators.values.contains { $0.contributesToWorkspaceUnread }
    }

    @discardableResult
    private func normalizePinnedTabs(in paneId: PaneID) -> Bool {
        guard !isNormalizingPinnedTabOrder else { return true }
        isNormalizingPinnedTabOrder = true
        defer { isNormalizingPinnedTabOrder = false }

        let tabs = bonsplitController.tabs(inPane: paneId)
        let pinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
            return pinnedPanelIds.contains(panelId)
        }
        let unpinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return true }
            return !pinnedPanelIds.contains(panelId)
        }
        let desiredOrder = pinnedTabs + unpinnedTabs

        for (index, desiredTab) in desiredOrder.enumerated() {
            let currentTabs = bonsplitController.tabs(inPane: paneId)
            guard let currentIndex = currentTabs.firstIndex(where: { $0.id == desiredTab.id }) else { continue }
            if currentIndex != index {
                _ = bonsplitController.reorderTab(desiredTab.id, toIndex: index)
            }
        }
        return true
    }

    private func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if let panelId = panelIdFromSurfaceId(tab.id), pinnedPanelIds.contains(panelId) {
                count += 1
            }
        }
        let rawTarget = min(anchorIndex + 1, tabs.count)
        return max(rawTarget, pinnedCount)
    }

    func isPanelPinned(_ panelId: UUID) -> Bool {
        pinnedPanelIds.contains(panelId)
    }

    func panelKind(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        return surfaceKind(for: panel)
    }
    private var backgroundPrimeTerminalPanels: [TerminalPanel] {
        var seenPanelIds = Set<UUID>()
        return bonsplitController.allPaneIds.compactMap { paneId -> TerminalPanel? in
            guard let tabId = bonsplitController.selectedTab(inPane: paneId)?.id ?? bonsplitController.tabs(inPane: paneId).first?.id, let panelId = panelIdFromSurfaceId(tabId), seenPanelIds.insert(panelId).inserted else { return nil }
            return panels[panelId] as? TerminalPanel
        }
    }

    private func hasBackgroundSurfaceStartWork(for panel: TerminalPanel) -> Bool {
        // A surface that can never create a runtime (closing/closed panel,
        // agent-hibernation suspension) must not count as prime work: the
        // prime coordinator's timeout path deliberately keeps the workspace's
        // hidden mount retained, so a never-satisfiable surface would pin one
        // of the two global background-mount slots forever (#9769).
        guard panel.surface.surface != nil || panel.surface.canCreateRuntimeSurface else {
            return false
        }
        return panel.surface.hasDeferredStartupWorkForBackgroundStart() ||
            pendingTerminalInputObserversByPanelId[panel.id]?.isEmpty == false
    }

    private var backgroundPrimeTerminalPanelsNeedingSurfaceStart: [TerminalPanel] {
        backgroundPrimeTerminalPanels.filter { panel in
            panel.surface.surface == nil && hasBackgroundSurfaceStartWork(for: panel)
        }
    }

    func hasBackgroundPrimeTerminalSurfaceStartWork() -> Bool {
        backgroundPrimeTerminalPanels.contains {
            hasBackgroundSurfaceStartWork(for: $0)
        }
    }

    func requestBackgroundPrimeTerminalSurfaceStartIfNeeded() {
        backgroundPrimeTerminalPanelsNeedingSurfaceStart.forEach {
            $0.surface.requestBackgroundSurfaceStartIfNeeded()
        }
    }

    func hasLoadedBackgroundPrimeTerminalSurface() -> Bool {
        backgroundPrimeTerminalPanels.allSatisfy { panel in
            panel.surface.surface != nil || !hasBackgroundSurfaceStartWork(for: panel)
        }
    }

    @discardableResult
    func preloadTerminalPanelForDebugStress(
        tabId: TabID,
        inPane paneId: PaneID
    ) -> TerminalPanel? {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let terminalPanel = panels[panelId] as? TerminalPanel else {
            return nil
        }

        debugStressPreloadSelectionDepth += 1
        defer { debugStressPreloadSelectionDepth -= 1 }
        let isVisibleSelection =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == tabId &&
            terminalPanel.surface.isViewInWindow &&
            terminalPanel.hostedView.superview != nil

        if isVisibleSelection {
            terminalPanel.requestViewReattach()
            scheduleTerminalGeometryReconcile()
        }
        terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
        return terminalPanel
    }

    func scheduleDebugStressTerminalGeometryReconcile() {
        scheduleTerminalGeometryReconcile()
    }

    func panelTitle(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        let fallback = panelTitles[panelId] ?? panel.displayTitle
        return resolvedPanelTitle(panelId: panelId, fallback: fallback)
    }

    func setPanelPinned(panelId: UUID, pinned: Bool) {
        guard panels[panelId] != nil else { return }
        let wasPinned = pinnedPanelIds.contains(panelId)
        guard wasPinned != pinned else { return }
        let mutationToken = UUID()
        pinMutationTokensByPanelId[panelId] = mutationToken
        if pinned {
            pinnedPanelIds.insert(panelId)
        } else {
            pinnedPanelIds.remove(panelId)
        }

        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else {
            pinMutationTokensByPanelId.removeValue(forKey: panelId)
            return
        }
        bonsplitController.updateTab(tabId, isPinned: pinned)
        pinMutationTokensByPanelId.removeValue(forKey: panelId)
        normalizePinnedTabs(in: paneId)
    }

    func panelIsUnread(_ panelId: UUID) -> Bool {
        guard panels[panelId] != nil else { return false }
        return manualUnreadPanelIds.contains(panelId) ||
            restoredUnreadPanelIds.contains(panelId) ||
            hasUnreadNotification(panelId: panelId)
    }

    @discardableResult
    func togglePanelUnread(_ panelId: UUID) -> Bool {
        guard panels[panelId] != nil else { return false }
        if panelIsUnread(panelId) {
            markPanelRead(panelId)
        } else {
            markPanelUnread(panelId)
        }
        return true
    }

    func markPanelUnread(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        let didClearRestored = clearRestoredUnreadIndicatorState(panelId: panelId)
        let didInsertManual = manualUnreadPanelIds.insert(panelId).inserted
        guard didInsertManual || didClearRestored else { return }
        manualUnreadMarkedAt[panelId] = Date()
        syncUnreadBadgeStateForPanel(panelId)
    }

    func preferredUnreadPanelIdForJump() -> UUID? {
        let latestManualPanelId = manualUnreadMarkedAt
            .filter { manualUnreadPanelIds.contains($0.key) && panels[$0.key] != nil }
            .max { $0.value < $1.value }?
            .key
        if let latestManualPanelId {
            return latestManualPanelId
        }
        if let manualPanelId = manualUnreadPanelIds.first(where: { panels[$0] != nil }) {
            return manualPanelId
        }
        if let restoredPanelId = restoredUnreadPanelIds.first(where: { panels[$0] != nil }) {
            return restoredPanelId
        }
        return representativePanelIdForWorkspaceManualUnread()
    }

    func markPanelRead(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        let notificationStore = AppDelegate.shared?.notificationStore
        notificationStore?.markRead(forTabId: id, surfaceId: panelId)
        // An explicit user mark-read dismisses the focused-read indicator too.
        // The store's markRead deliberately does not: that indicator marks
        // notifications already read while the surface was focused, and only a
        // user dismissal like this one (or the workspace-level paths) ends it.
        notificationStore?.clearFocusedReadIndicator(forTabId: id, surfaceId: panelId)
        _ = clearManualUnreadState(panelId: panelId)
        let restoredIndicator = restoredUnreadPanelIndicators[panelId]
        let didClearRestored = clearRestoredUnreadIndicatorState(panelId: panelId)
        if didClearRestored,
           restoredIndicator?.contributesToWorkspaceUnread == true,
           !hasWorkspaceContributingRestoredUnreadIndicator {
            _ = notificationStore?.clearRestoredUnreadIndicator(forTabId: id)
        }
        syncUnreadBadgeStateForPanel(panelId)
    }

    func clearUnreadAfterJump(panelId: UUID?) {
        if let panelId,
           manualUnreadPanelIds.contains(panelId) || restoredUnreadPanelIds.contains(panelId) {
            markPanelRead(panelId)
            return
        }
        AppDelegate.shared?.notificationStore?.markRead(forTabId: id)
    }

    func clearManualUnread(panelId: UUID) {
        let didRemoveManual = clearManualUnreadState(panelId: panelId)
        let didRemoveRestored = clearRestoredUnreadIndicatorState(panelId: panelId)
        guard didRemoveManual || didRemoveRestored else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    @discardableResult
    func clearAllPanelUnreadIndicatorsForWorkspaceRead() -> Bool {
        let hadLocalUnreadIndicators = !manualUnreadPanelIds.isEmpty || !restoredUnreadPanelIds.isEmpty
        let affectedPanelIds = Set(panels.keys)
            .union(manualUnreadPanelIds)
            .union(restoredUnreadPanelIds)
        guard !affectedPanelIds.isEmpty else { return false }
        manualUnreadPanelIds.removeAll()
        restoredUnreadPanelIndicators.removeAll()
        manualUnreadMarkedAt.removeAll()
        for panelId in affectedPanelIds {
            syncUnreadBadgeStateForPanel(panelId)
        }
        return hadLocalUnreadIndicators
    }

    private func clearManualUnreadState(panelId: UUID) -> Bool {
        let didRemoveUnread = manualUnreadPanelIds.remove(panelId) != nil
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        return didRemoveUnread
    }

    func restorePanelUnreadIndicator(
        _ panelId: UUID,
        contributesToWorkspaceUnread: Bool = true
    ) {
        guard panels[panelId] != nil else { return }
        let nextIndicator = RestoredPanelUnreadIndicator(
            contributesToWorkspaceUnread: contributesToWorkspaceUnread
        )
        guard restoredUnreadPanelIndicators[panelId] != nextIndicator else { return }
        restoredUnreadPanelIndicators[panelId] = nextIndicator
        syncUnreadBadgeStateForPanel(panelId)
    }

    func clearRestoredUnreadIndicator(panelId: UUID) {
        let didRemoveUnread = clearRestoredUnreadIndicatorState(panelId: panelId)
        guard didRemoveUnread else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    func hasRestoredUnreadIndicator(panelId: UUID) -> Bool {
        restoredUnreadPanelIds.contains(panelId)
    }

    func restoredUnreadIndicatorContributesToWorkspace(panelId: UUID) -> Bool? {
        restoredUnreadPanelIndicators[panelId]?.contributesToWorkspaceUnread
    }

    private func clearRestoredUnreadIndicatorState(panelId: UUID) -> Bool {
        guard restoredUnreadPanelIndicators[panelId] != nil else { return false }
        restoredUnreadPanelIndicators.removeValue(forKey: panelId)
        return true
    }

    static func shouldShowUnreadIndicator(
        hasUnreadNotification: Bool,
        hasPanelUnreadIndicator: Bool,
        isWorkspaceManuallyUnread: Bool = false,
        isWorkspaceManualUnreadRepresentative: Bool = false
    ) -> Bool {
        hasUnreadNotification ||
            hasPanelUnreadIndicator ||
            (isWorkspaceManuallyUnread && isWorkspaceManualUnreadRepresentative)
    }

    // MARK: - Title Management
    // Title/description ownership lives in Workspace+TitleOwnership.swift.

    func setCustomColor(_ hex: String?) {
        if let hex {
            customColor = WorkspaceTabColorSettings.normalizedHex(hex)
        } else {
            customColor = nil
        }
    }

    func setTerminalScrollBarHidden(_ hidden: Bool) {
        guard terminalScrollBarHidden != hidden else { return }
        terminalScrollBarHidden = hidden
        NotificationCenter.default.post(
            name: Self.terminalScrollBarHiddenDidChangeNotification,
            object: self
        )
    }

    // MARK: - Directory Updates

    private func notifyPresentedCurrentDirectoryChanged(from previousDirectory: String?, force: Bool = false) {
        guard force || previousDirectory != presentedCurrentDirectory else { return }
        scheduleExtensionSidebarProjectRootRefresh(for: currentDirectory)
        NotificationCenter.default.post(
            name: .workspaceCurrentDirectoryDidChange,
            object: self,
            userInfo: [
                "workspaceId": id,
                "presentedDirectoryOnly": true,
            ]
        )
    }

    private enum PanelDirectoryUpdateSource {
        case liveReport
        case remoteReport
        case restoredSnapshotMetadata

        var isLiveReport: Bool {
            switch self {
            case .liveReport, .remoteReport:
                return true
            case .restoredSnapshotMetadata:
                return false
            }
        }

        var establishesRemoteProvenance: Bool {
            switch self {
            case .remoteReport:
                return true
            case .liveReport, .restoredSnapshotMetadata:
                return false
            }
        }

    }

    private func configTrackingDirectory(for panelId: UUID?) -> String? {
        // Remote workspace directories are remote-host paths; no local per-directory config can apply.
        if usesRemoteDirectoryProvenance { return nil }
        if let panelId {
            for candidate in [panelDirectories[panelId], terminalPanel(for: panelId)?.requestedWorkingDirectory] {
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty { return trimmed }
            }
        }
        let trimmedCurrentDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedCurrentDirectory.isEmpty ? nil : trimmedCurrentDirectory
    }

    @discardableResult
    func updatePanelDirectory(panelId: UUID, directory: String, displayLabel: String? = nil) -> Bool {
        updatePanelDirectory(panelId: panelId, directory: directory, displayLabel: displayLabel, source: .liveReport)
    }

    /// Records a directory report that came from the remote shell/PTY control path.
    @discardableResult
    func updateRemotePanelDirectory(panelId: UUID, directory: String, displayLabel: String? = nil) -> Bool {
        updatePanelDirectory(panelId: panelId, directory: directory, displayLabel: displayLabel, source: .remoteReport)
    }

    func discardRemoteDirectoryTrustState(panelId: UUID) {
        remoteDirectoryTrustRequiredPanelIds.remove(panelId); remoteDirectoryReportPanelIds.remove(panelId)
    }

    @discardableResult
    private func updatePanelDirectory(
        panelId: UUID,
        directory: String,
        displayLabel: String?,
        source: PanelDirectoryUpdateSource
    ) -> Bool {
        let reportedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reportedDirectory.isEmpty else { return false }
        let trimmed: String
        if source.isLiveReport {
            guard let acceptedDirectory = acceptedRestoredGuardedDirectoryReport(
                panelId: panelId,
                reportedDirectory: reportedDirectory
            ) else { return false }
            trimmed = acceptedDirectory
        } else {
            trimmed = reportedDirectory
        }
        let previousPresentedDirectory = presentedCurrentDirectory
        if source == .liveReport &&
                remoteDirectoryTrustRequiredPanelIds.contains(panelId) {
            return false
        }
        let routedRemoteReport = source == .remoteReport && !allowsLocalDirectoryFallback(panelId: panelId)
        let establishesRemoteProvenance = source.establishesRemoteProvenance &&
            (routedRemoteReport || remoteDirectoryTrustRequiredPanelIds.contains(panelId))
        let provenanceChanged = establishesRemoteProvenance && !remoteDirectoryReportPanelIds.contains(panelId)
        if provenanceChanged {
            remoteDirectoryReportPanelIds.insert(panelId); remoteDirectoryTrustRequiredPanelIds.insert(panelId)
        }
        let directoryChanged = panelDirectories[panelId] != trimmed
        if directoryChanged || provenanceChanged { panelDirectories[panelId] = trimmed }
        let trimmedDisplayLabel = displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedDisplayLabel.isEmpty {
            if panelDirectoryDisplayLabels[panelId] != trimmedDisplayLabel {
                panelDirectoryDisplayLabels[panelId] = trimmedDisplayLabel
            }
        } else if directoryChanged, panelDirectoryDisplayLabels[panelId] != nil {
            // A directory change without a label invalidates the previous label;
            // same-directory re-reports (e.g. git probe re-affirmation) keep it.
            panelDirectoryDisplayLabels.removeValue(forKey: panelId)
        }
        if panelId == focusedPanelId {
            let nextSurfaceTabBarDirectory = configTrackingDirectory(for: panelId)
            if surfaceTabBarDirectory != nextSurfaceTabBarDirectory { surfaceTabBarDirectory = nextSurfaceTabBarDirectory }
            if allowsLocalDirectoryFallback(panelId: panelId), currentDirectory != trimmed { currentDirectory = trimmed }
        }
        if usesRemoteDirectoryProvenance {
            notifyPresentedCurrentDirectoryChanged(from: previousPresentedDirectory, force: provenanceChanged)
        }
        return true
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        guard panels[panelId] != nil else { return }
        let previousState = panelShellActivityStates[panelId] ?? .unknown

        if previousState == state {
            if let terminalPanel = panels[panelId] as? TerminalPanel {
                terminalPanel.updateShellActivityState(state)
            }
            return
        }
        let pendingRestoredTitle = restoredPanelTitleAfterShellActivity(
            panelId: panelId,
            state: state
        )
        defer {
            if let pendingRestoredTitle {
                _ = updatePanelTitle(panelId: panelId, title: pendingRestoredTitle)
            }
        }
        panelShellActivityStates[panelId] = state
        if let terminalPanel = panels[panelId] as? TerminalPanel {
            terminalPanel.updateShellActivityState(state)
        }
        if let restoredAgent = restoredAgentSnapshotsByPanelId[panelId] {
            updateRestoredAgentResumeState(
                panelId: panelId,
                restoredAgent: restoredAgent,
                shellState: state
            )
        } else {
            updateBindingOnlyRestoredAgentResumeState(panelId: panelId, shellState: state)
        }
        if state == .promptIdle { _ = clearStaleAgentPIDs(panelId: panelId, refreshPorts: true) }
#if DEBUG
        cmuxDebugLog(
            "surface.shellState workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) from=\(previousState.rawValue) to=\(state.rawValue) " +
            "restore=\(restoredAgentResumeStatesByPanelId[panelId].map { String(describing: $0) } ?? "none") " +
            "awaitsInput=\(restoredAgentLifecycle.awaitsStartupInput(panelId: panelId) ? 1 : 0)"
        )
#endif
    }

    func restorableAgentForHibernation(
        panelId: UUID,
        index: RestorableAgentSessionIndex
    ) -> SessionRestorableAgentSnapshot? {
        let observation = index.entry(workspaceId: id, panelId: panelId)
        if let observation {
            reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
        }
        guard restoredAgentResumeStatesByPanelId[panelId] != .completedAgentExit,
              let snapshot = restoredAgentSnapshotsByPanelId[panelId] ?? observation?.snapshot,
              snapshot.resumeCommand != nil else {
            return nil
        }
        let fingerprint = TabManager.restorableAgentSnapshotFingerprint(snapshot)
        guard invalidatedRestoredAgentFingerprintsByPanelId[panelId] != fingerprint else {
            return nil
        }
        return snapshot
    }

    @discardableResult
    func enterAgentHibernation(
        panelId: UUID,
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date
    ) -> Bool {
        guard let terminalPanel = panels[panelId] as? TerminalPanel,
              !terminalPanel.isAgentHibernated ||
                terminalPanel.isAgentHibernationCommitPending else {
            return false
        }
        guard agent.resumeCommand != nil,
              terminalPanel.enterAgentHibernation(
                agent: agent,
                lastActivityAt: lastActivityAt
              ) else {
            return false
        }
        restoredAgentLifecycle.setSnapshot(agent, panelId: panelId)
        restoredAgentLifecycle.setResumeState(.manualResumeAvailable, panelId: panelId)
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        // Hibernation destroys the local PTY. Clear its derived badge and
        // reject any queued publication captured before that teardown.
        surfaceListeningPorts.removeValue(forKey: panelId)
        recomputeListeningPorts()
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        let keys = agentPIDKeysByPanelId[panelId] ?? []
        for key in keys {
            _ = clearAgentPID(key: key, panelId: panelId, clearStatus: false, refreshPorts: false)
        }
        if !keys.isEmpty {
            refreshTrackedAgentPorts()
        }
        return true
    }

    @discardableResult
    func resumeAgentHibernation(panelId: UUID, focus: Bool) -> Bool {
        guard let terminalPanel = panels[panelId] as? TerminalPanel,
              terminalPanel.isAgentHibernated else {
            return false
        }
        let preparation = terminalPanel.prepareAgentHibernationResume()
        guard preparation.didResume else { return false }
        if restoredAgentSnapshotsByPanelId[panelId] != nil {
            restoredAgentLifecycle.setResumeState(
                preparation.queuedStartupInput
                    ? .awaitingAutoResumeCommand
                    : .manualResumeAvailable,
                panelId: panelId
            )
            invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        }
        clearAgentLifecycleStates(panelId: panelId)
        AgentHibernationController.shared.recordTerminalFocus(workspaceId: id, panelId: panelId)
        if focus {
            focusPanel(panelId)
        }
        return true
    }

    @discardableResult
    func resumeVisibleAgentHibernationPanels(panelIds: Set<UUID>) -> Bool {
        var didResume = false
        for panelId in panelIds {
            guard let terminalPanel = panels[panelId] as? TerminalPanel,
                  terminalPanel.isAgentHibernated else {
                continue
            }
            didResume = resumeAgentHibernation(panelId: panelId, focus: false) || didResume
        }
        return didResume
    }

    @discardableResult
    func setSurfaceResumeBinding(_ binding: SurfaceResumeBindingSnapshot, panelId: UUID) -> Bool {
        guard terminalPanel(for: panelId) != nil,
              let startupInput = binding.inlineStartupInput(repairPortableAgentExecutable: false),
              !startupInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let activeRestoreClaim = surfaceResumeRestoreClaim(for: panelId)
        if let activeRestoreClaim {
            guard activeRestoreClaim.binding.acceptsRestoreBindingClaim(from: binding) else {
                return false
            }
        }
        // These checks and the assignment are one MainActor mutation, so
        // concurrent publications cannot downgrade a TUI or trusted same-session
        // binding between separate get/set socket calls.
        let existingBinding = surfaceResumeBindingsByPanelId[panelId]
        guard binding.allowsCodexAgentHookReplacement(of: existingBinding),
              !binding.downgradesTrustedAgentHookBinding(existingBinding) else {
            return false
        }
        if activeRestoreClaim != nil {
            surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
        }
        let previousRestorableAgent = restoredAgentSnapshotsByPanelId[panelId]
        invalidateRestoredAgentLifecycleIfBindingIsReplaced(
            by: binding,
            panelId: panelId
        )
        // This transient cwd belongs to the binding restored at launch. Let a
        // same-session hook refresh keep its cwd rescue, but never let it
        // override a replacement session's structured restore record.
        if let previous = surfaceResumeBindingsByPanelId[panelId],
           previous.kind != binding.kind
            || previous.checkpointId != binding.checkpointId
            || previous.cwd != binding.cwd
            || previous.launchCommand?.workingDirectory != binding.launchCommand?.workingDirectory
            || (previous.launchCommand == nil && binding.launchCommand == nil
                && previous.command != binding.command) {
            restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
        }
        if let restorableAgent = binding.managedRestorableAgentSnapshot(
            replacing: previousRestorableAgent
        ) {
            restoredAgentLifecycle.setSnapshot(restorableAgent, panelId: panelId)
            invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        }
        surfaceResumeBindingsByPanelId[panelId] = binding
        return true
    }

    /// Atomically claims the current binding generation for a CLI restore.
    ///
    /// The claim is consumed by the next same-session hook refresh and blocks a
    /// different checkpoint from replacing the binding during the handoff.
    @discardableResult
    func claimSurfaceResumeBinding(
        panelId: UUID,
        expectedCheckpointID: String,
        expectedSource: String,
        expectedUpdatedAt: TimeInterval
    ) -> Bool {
        guard let binding = surfaceResumeBindingsByPanelId[panelId],
              binding.isAgentHookBinding,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex",
              binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines)
                  == expectedCheckpointID.trimmingCharacters(in: .whitespacesAndNewlines),
              binding.source?.trimmingCharacters(in: .whitespacesAndNewlines)
                  == expectedSource.trimmingCharacters(in: .whitespacesAndNewlines),
              expectedUpdatedAt.isFinite,
              binding.updatedAt == expectedUpdatedAt else {
            return false
        }
        surfaceResumeRestoreClaimsByPanelId[panelId] = (
            binding: binding,
            claimedAt: Date.now
        )
        return true
    }

    /// Checks a non-socket binding writer against an in-flight restore claim.
    ///
    /// Hook publications use ``setSurfaceResumeBinding`` directly, while
    /// reconciliation and transfer paths historically wrote the dictionary
    /// inline. Those paths must share the same claim gate so no writer can
    /// replace the generation after the CLI has been authorized to exec it.
    @discardableResult
    func surfaceResumeBindingMutationAllowed(
        _ incoming: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        guard let claim = surfaceResumeRestoreClaim(for: panelId) else {
            return true
        }
        guard claim.binding.acceptsRestoreBindingClaim(from: incoming) else {
            return false
        }
        // Preserve the lease when a same-session writer refreshes metadata,
        // otherwise the current-generation check would discard the claim.
        surfaceResumeRestoreClaimsByPanelId[panelId] = (
            binding: incoming,
            claimedAt: claim.claimedAt
        )
        return true
    }

    /// Returns false while a claimed generation is still active.
    @discardableResult
    func surfaceResumeBindingRemovalAllowed(panelId: UUID) -> Bool {
        surfaceResumeRestoreClaim(for: panelId) == nil
    }

    private func surfaceResumeRestoreClaim(
        for panelId: UUID
    ) -> (binding: SurfaceResumeBindingSnapshot, claimedAt: Date)? {
        guard let claim = surfaceResumeRestoreClaimsByPanelId[panelId] else {
            return nil
        }
        guard let currentBinding = surfaceResumeBindingsByPanelId[panelId],
              currentBinding.checkpointId == claim.binding.checkpointId,
              currentBinding.source == claim.binding.source,
              currentBinding.updatedAt == claim.binding.updatedAt else {
            // A direct lifecycle mutation replaced the claimed generation
            // without going through the hook setter. Do not let that old claim
            // block a later, legitimate binding.
            surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
            return nil
        }
        guard Date.now.timeIntervalSince(claim.claimedAt) < SurfaceResumeBindingSnapshot.restoreClaimTTL else {
            surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
            return nil
        }
        return claim
    }

    @discardableResult
    func clearSurfaceResumeBinding(
        panelId: UUID,
        agentSessionEnded: Bool = false
    ) -> Bool {
        let removedBinding = surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: panelId)
        if let removedBinding,
           agentSessionEnded,
           removedBinding.isAgentHookBinding,
           let checkpointID = Self.normalizedResumeBindingValue(removedBinding.checkpointId),
           let restoredAgent = restoredAgentSnapshotsByPanelId[panelId],
           ManagedAgentSessionIdentity.sessionIDsMatch(
               kind: restoredAgent.kind.rawValue,
               lhs: checkpointID,
               rhs: restoredAgent.sessionId
           ),
           Self.restorableAgentForSessionRestore(
               restoredAgent,
               resumeBinding: removedBinding
           ) != nil {
            // A restore-time rejection is an authoritative end of the stale
            // checkpoint. Keep a completed tombstone so the old snapshot cannot
            // be auto-resumed on the next save, while the terminal's tracked cwd
            // remains available for the shell fallback.
            markRestoredAgentCompleted(panelId: panelId, snapshot: restoredAgent)
        }
        return removedBinding != nil
    }

    func surfaceResumeBinding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        surfaceResumeBindingsByPanelId[panelId]
    }

    func panelNeedsConfirmClose(panelId: UUID, fallbackNeedsConfirmClose: Bool) -> Bool {
        Self.resolveCloseConfirmation(
            shellActivityState: panelShellActivityStates[panelId],
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
    }

    func panelNeedsConfirmClose(panelId: UUID) -> Bool {
        guard let panel = panels[panelId] else { return false }
        if let terminalPanel = panel as? TerminalPanel {
            return panelNeedsConfirmClose(
                panelId: panelId,
                fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()
            )
        }
        return panel.isDirty
    }

    /// Applies sidebar Git branch state.
    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
        let state = SidebarGitBranchState(branch: branch, isDirty: isDirty)
        let existing = panelGitBranches[panelId]
        if existing?.branch != branch || existing?.isDirty != isDirty {
            panelGitBranches[panelId] = state
        }
        if panelId == focusedPanelId, gitBranch != state {
            gitBranch = state
        }
    }

    func clearPanelGitBranch(panelId: UUID) {
        if panelGitBranches[panelId] != nil {
            panelGitBranches.removeValue(forKey: panelId)
        }
        if panelId == focusedPanelId {
            if gitBranch != nil {
                gitBranch = nil
            }
        }
    }

    /// Removes all sidebar Git metadata.
    func clearSidebarGitMetadata() {
        if !panelGitBranches.isEmpty {
            panelGitBranches.removeAll()
        }
        if gitBranch != nil {
            gitBranch = nil
        }
    }

    /// Removes remote directory state and any metadata derived from it.
    func clearRemotePanelDirectory(panelId: UUID) {
        let previousPresentedDirectory = presentedCurrentDirectory
        panelDirectories.removeValue(forKey: panelId)
        panelDirectoryDisplayLabels.removeValue(forKey: panelId)
        discardRemoteDirectoryTrustState(panelId: panelId)
        clearPanelGitBranch(panelId: panelId)
        if usesRemoteDirectoryProvenance {
            notifyPresentedCurrentDirectoryChanged(from: previousPresentedDirectory, force: true)
        }
    }

    func resetSidebarContext(reason: String = "unspecified") {
        statusEntries.removeAll()
        clearAllAgentPIDs(refreshPorts: false)
        clearAllAgentLifecycleStates()
        agentListeningPorts.removeAll()
        latestConversationMessage = nil
        latestSubmittedMessage = nil
        latestSubmittedAt = nil
        logEntries.removeAll()
        progress = nil
        gitBranch = nil
        panelGitBranches.removeAll()
        surfaceListeningPorts.removeAll()
        listeningPorts.removeAll()
        metadataBlocks.removeAll()
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        for panelId in Array(pendingTerminalInputObserversByPanelId.keys) where !validSurfaceIds.contains(panelId) {
            removePendingTerminalInputObservers(forPanelId: panelId)
        }
        panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        panelDirectoryDisplayLabels = panelDirectoryDisplayLabels.filter { validSurfaceIds.contains($0.key) }
        remoteDirectoryTrustRequiredPanelIds = remoteDirectoryTrustRequiredPanelIds.filter { validSurfaceIds.contains($0) }
        remoteDirectoryReportPanelIds = remoteDirectoryReportPanelIds.filter { validSurfaceIds.contains($0) }
        panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        panelCustomTitles = panelCustomTitles.filter { validSurfaceIds.contains($0.key) }
        panelCustomTitleSources = panelCustomTitleSources.filter { validSurfaceIds.contains($0.key) }
        pinnedPanelIds = pinnedPanelIds.filter { validSurfaceIds.contains($0) }
        pinMutationTokensByPanelId = pinMutationTokensByPanelId.filter { validSurfaceIds.contains($0.key) }
        manualUnreadPanelIds = manualUnreadPanelIds.filter { validSurfaceIds.contains($0) }
        restoredUnreadPanelIndicators = restoredUnreadPanelIndicators.filter { validSurfaceIds.contains($0.key) }
        panelGitBranches = panelGitBranches.filter { validSurfaceIds.contains($0.key) }
        manualUnreadMarkedAt = manualUnreadMarkedAt.filter { validSurfaceIds.contains($0.key) }
        surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        surfaceTTYNames = surfaceTTYNames.filter { validSurfaceIds.contains($0.key) }
        restoredGuardedWorkingDirectoriesByPanelId = restoredGuardedWorkingDirectoriesByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        panelShellActivityStates = panelShellActivityStates.filter { validSurfaceIds.contains($0.key) }
        restoredPanelTitleBoundariesByPanelId = restoredPanelTitleBoundariesByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        let staleAgentPIDPanelIds = agentPIDKeysByPanelId.keys.filter { !validSurfaceIds.contains($0) }
        var didClearStaleAgentRuntime = false
        for panelId in staleAgentPIDPanelIds {
            let keys = agentPIDKeysByPanelId[panelId] ?? []
            for key in keys {
                if clearAgentPID(key: key, panelId: panelId, clearStatus: true, refreshPorts: false) {
                    didClearStaleAgentRuntime = true
                }
            }
        }
        if didClearStaleAgentRuntime {
            refreshTrackedAgentPorts()
        }
        surfaceResumeBindingsByPanelId = surfaceResumeBindingsByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        surfaceResumeRestoreClaimsByPanelId = surfaceResumeRestoreClaimsByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        for panelId in Array(deferredAgentResumeRestoresByPanelId.keys)
        where !validSurfaceIds.contains(panelId) {
            removeDeferredAgentResumeRestore(panelId: panelId)
        }
        for panelId in Array(deferredAgentResumeClaimsByPanelId.keys)
        where !validSurfaceIds.contains(panelId) {
            removeDeferredAgentResumeRestore(panelId: panelId)
        }
        restoredAgentLifecycle.retainSessionRestores(for: validSurfaceIds)
        restoredResumeSessionWorkingDirectoriesByPanelId = restoredResumeSessionWorkingDirectoriesByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        invalidatedRestoredAgentFingerprintsByPanelId = invalidatedRestoredAgentFingerprintsByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        recomputeListeningPorts()
    }

    func sidebarOrderedPanelIds() -> [UUID] {
        let paneTabs: [String: [UUID]] = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { paneId in
                let panelIds = bonsplitController
                    .tabs(inPane: paneId)
                    .compactMap { panelIdFromSurfaceId($0.id) }
                return (paneId.id.uuidString, panelIds)
            }
        )

        let fallbackPanelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
        let tree = bonsplitController.treeSnapshot()
        return tree.orderedPanelIds(
            paneTabs: paneTabs,
            fallbackPanelIds: fallbackPanelIds
        )
    }

    func sidebarFinderDirectory() -> String? {
        guard !usesRemoteDirectoryProvenance else { return nil }
        let panelIds = sidebarOrderedPanelIds()
        return sidebarFilesystemDirectoriesInDisplayOrder(
            orderedPanelIds: panelIds,
            includeFallback: true
        ).first
    }

    func sidebarStatusEntriesInDisplayOrder() -> [SidebarStatusEntry] {
        sidebarStatusEntriesVisibleForDisplay().sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    func sidebarMetadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        sidebarMetadata.metadataBlocksInDisplayOrder()
    }

    @discardableResult
    func recordConversationMessage(_ message: String?) -> Bool {
        guard let preview = Self.conversationMessagePreview(from: message) else { return false }
        guard latestConversationMessage != preview else { return false }
        latestConversationMessage = preview
        return true
    }

    @discardableResult
    func recordSubmittedMessage(_ message: String?) -> Bool {
        guard let preview = Self.conversationMessagePreview(from: message) else { return false }
        _ = recordConversationMessage(preview)
        latestSubmittedMessage = preview
        latestSubmittedAt = Date()
        return true
    }

    var isRestorableInSessionSnapshot: Bool {
        true
    }

    /// Normalizes a user-supplied workspace environment: trims keys and drops any entry with a
    /// blank key or blank value. Dropping blank values keeps behavior identical across the
    /// `additionalEnvironment` channel (which already skips empty values) and the
    /// `initialEnvironmentOverrides` channel (which would otherwise export a blank value on the
    /// initial shell only).
    ///
    /// Reserved `CMUX_*` variables are intentionally *not* stripped by name — they are protected
    /// at spawn time by `mergedStartupEnvironment(protectedKeys:)`, the single authority on which
    /// keys are managed. That protection is an exact Swift-string match, but the env eventually
    /// crosses the Swift→C boundary (`strdup` / Ghostty), where a key is truncated at its first
    /// NUL. A key like `"CMUX_SOCKET_PATH\0x"` would dodge the exact-match check yet collapse to
    /// `CMUX_SOCKET_PATH` in the spawned shell, so reject any key containing a NUL (and `=`,
    /// which is never a valid env var name) and any value containing a NUL. This is the single
    /// choke point for every entry point (CLI, cmux.json, session restore), so the guard cannot be bypassed.
    // `nonisolated` so the nonisolated socket workspace-create parsing path (`v2WorkspaceCreate`)
    // can call this pure helper without hopping to the main actor; `Workspace` is `@MainActor`,
    // so its statics are main-actor-isolated by default.
    nonisolated static func sanitizedWorkspaceEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  !pair.value.isEmpty,
                  !key.contains("\0"),
                  !key.contains("="),
                  !pair.value.contains("\0") else { return }
            result[key] = pair.value
        }
    }

    /// Pure merge core: overlays `explicit` on top of `workspaceEnvironment`.
    /// Managed `CMUX_*` / terminal-identity keys are protected downstream by
    /// `mergedStartupEnvironment(protectedKeys:)`; this only decides precedence
    /// among user-supplied values — explicit per-surface entries (layout `env`,
    /// scrollback replay) win over the workspace set. Static so the
    /// `init` path can call it before `self` is fully initialized.
    static func startupEnvironment(
        workspaceEnvironment: [String: String],
        overlaying explicit: [String: String]
    ) -> [String: String] {
        guard !workspaceEnvironment.isEmpty else { return explicit }
        var merged = workspaceEnvironment
        for (key, value) in explicit {
            merged[key] = value
        }
        return merged
    }

    /// Instance convenience over ``startupEnvironment(workspaceEnvironment:overlaying:)``
    /// for the post-init surface-creation paths.
    func startupEnvironmentMergingWorkspaceEnvironment(_ explicit: [String: String]) -> [String: String] {
        Self.startupEnvironment(workspaceEnvironment: workspaceEnvironment, overlaying: explicit)
    }

    // MARK: - Panel Operations

    func rememberTerminalConfigInheritanceSource(
        _ terminalPanel: TerminalPanel,
        magnificationPercent: Int? = nil
    ) {
        guard let mountedPanel = panels[terminalPanel.id] as? TerminalPanel,
              mountedPanel === terminalPanel else { return }
        lastTerminalConfigInheritancePanelId = terminalPanel.id
        lastTerminalConfigInheritanceFontSizeLineage =
            terminalPanel.surface.fontSizeLineageSnapshot(
                magnificationPercent: magnificationPercent
            )
    }

    func rememberTerminalFontSizeLineageForConfigInheritance(_ lineage: TerminalFontSizeLineage) {
        lastTerminalConfigInheritanceFontSizeLineage = lineage
    }

    func clearTerminalFontSizeLineageForConfigInheritance() {
        lastTerminalConfigInheritanceFontSizeLineage = nil
    }

    func lastRememberedTerminalPanelForConfigInheritance() -> TerminalPanel? {
        guard let panelId = lastTerminalConfigInheritancePanelId else { return nil }
        return terminalPanel(for: panelId)
    }

    func lastRememberedTerminalFontSizeLineageForConfigInheritance() -> TerminalFontSizeLineage? {
        lastTerminalConfigInheritanceFontSizeLineage
    }

    func removeTerminalConfigInheritanceSource(panelId: UUID) {
        guard lastTerminalConfigInheritancePanelId == panelId else { return }
        lastTerminalConfigInheritancePanelId = nil
        lastTerminalConfigInheritanceFontSizeLineage = nil

        if let replacement = terminalPanelForConfigInheritance() {
            rememberTerminalConfigInheritanceSource(replacement)
        }
    }

    func resolvedTerminalStartupWorkingDirectory(
        requestedWorkingDirectory: String?,
        sourcePanelId: UUID?
    ) -> String? {
        if let requested = TerminalWorkingDirectoryResolver.normalized(requestedWorkingDirectory) {
            return requested
        }
        if let rescued = sourcePanelId.flatMap({ resumedAgentPaneWorkingDirectoryRescue(panelId: $0) }) {
            return rescued
        }
        return TerminalWorkingDirectoryResolver.firstAvailable([
            sourcePanelId.flatMap { panelDirectories[$0] },
            sourcePanelId.flatMap { terminalPanel(for: $0)?.requestedWorkingDirectory },
            currentDirectory
        ])
    }

    /// The foreground-process cwd read consulted by
    /// ``resumedAgentPaneWorkingDirectoryRescue(panelId:)``. Nil selects the
    /// libproc-backed default, which requires a live foreground process on the
    /// pane's surface; injecting a substitute decouples callers from libproc.
    var foregroundProcessWorkingDirectoryProvider: ((UUID) -> String?)?

    /// Rescues split/new-tab cwd inheritance from a pane whose restored
    /// auto-resume command is still running (#7155).
    ///
    /// While the resumed agent holds the pane's foreground the shell never
    /// reaches a prompt, so the pane's tracked cwd cannot self-correct: the
    /// one-shot restore guard (#6617) swallows only the first spurious
    /// post-restore report, and any later stray report parks the tracked value
    /// on the surface default (home) for the rest of the run. While that state
    /// lasts, trust the tracked value only while it still equals the restored
    /// session directory; otherwise prefer the live foreground process's
    /// actual cwd (a resumed agent knows where it really is — e.g. Claude
    /// restores its own cwd on resume), then the recorded session directory.
    private func resumedAgentPaneWorkingDirectoryRescue(panelId: UUID) -> String? {
        guard restoredAgentResumeStatesByPanelId[panelId] == .autoResumeCommandRunning else { return nil }
        // No recorded session directory means the resume launcher targets no
        // directory of its own (e.g. a registration with a `.ignore` cwd
        // policy, whose resume command never cds) — the tracked cwd is
        // genuine, so there is nothing to rescue and the live foreground
        // process must not be consulted either.
        guard let sessionDirectory = TerminalWorkingDirectoryResolver.normalized(
            restoredResumeSessionWorkingDirectoriesByPanelId[panelId]
        ) else { return nil }
        let trackedDirectory = TerminalWorkingDirectoryResolver.normalized(panelDirectories[panelId])
        if trackedDirectory == sessionDirectory { return nil }
        for candidate in [liveForegroundProcessWorkingDirectory(panelId: panelId), sessionDirectory] {
            guard let candidate = TerminalWorkingDirectoryResolver.normalized(candidate) else { continue }
            if candidate == trackedDirectory {
                continue
            }
            var candidateIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &candidateIsDirectory),
               candidateIsDirectory.boolValue {
                return candidate
            }
            // A recorded directory on a temporarily unmounted volume is not
            // deleted: keep the rescue armed so it engages again after the
            // volume remounts (#5278). Only a genuinely deleted directory is
            // tombstoned.
            if candidate == sessionDirectory, Self.unmountedVolumeRoot(for: candidate) == nil {
                restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: panelId)
            }
        }
        return nil
    }

    private func liveForegroundProcessWorkingDirectory(panelId: UUID) -> String? {
        if let provider = foregroundProcessWorkingDirectoryProvider {
            return provider(panelId)
        }
        guard let pid = terminalPanel(for: panelId)?.surface.foregroundProcessID() else { return nil }
        return Self.processCurrentWorkingDirectory(pid: Int32(clamping: pid))
    }

    /// The current working directory of `pid` via
    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)`, or nil when the process is gone
    /// or unreadable.
    nonisolated static func processCurrentWorkingDirectory(pid: pid_t) -> String? {
        TerminalWorkingDirectoryResolver.processCurrentWorkingDirectory(pid: pid)
    }

    /// Candidate terminal panels used as the source when creating inherited Ghostty config.
    /// Preference order:
    /// 1) explicitly preferred terminal panel (when the caller has one),
    /// 2) selected terminal in the target pane,
    /// 3) currently focused terminal in the workspace,
    /// 4) last remembered terminal source,
    /// 5) first terminal tab in the target pane,
    /// 6) deterministic workspace fallback.
    private func terminalPanelConfigInheritanceCandidates(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> [TerminalPanel] {
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        if let preferredPanelId,
           let terminalPanel = terminalPanel(for: preferredPanelId) {
            appendCandidate(terminalPanel)
        }

        if let preferredPaneId,
           let selectedSurfaceId = bonsplitController.selectedTab(inPane: preferredPaneId)?.id,
           let selectedPanelId = panelIdFromSurfaceId(selectedSurfaceId),
           let selectedTerminalPanel = terminalPanel(for: selectedPanelId) {
            appendCandidate(selectedTerminalPanel)
        }

        if let focusedTerminalPanel {
            appendCandidate(focusedTerminalPanel)
        }

        if let rememberedTerminalPanel = lastRememberedTerminalPanelForConfigInheritance() {
            appendCandidate(rememberedTerminalPanel)
        }

        if let preferredPaneId {
            for tab in bonsplitController.tabs(inPane: preferredPaneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      let terminalPanel = terminalPanel(for: panelId) else { continue }
                appendCandidate(terminalPanel)
            }
        }

        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        return candidates
    }

    /// Picks the first terminal panel candidate used as the inheritance source.
    func terminalPanelForConfigInheritance(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> TerminalPanel? {
        terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ).first
    }

    func inheritedTerminalConfig(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> CmuxSurfaceConfigTemplate? {
#if DEBUG
        debugInheritedTerminalConfigInvocationCount += 1
#endif
        // Walk candidates in priority order and use the first panel that still exposes
        // a runtime surface pointer.
        for terminalPanel in terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ) {
            // Pin the panel and its TerminalSurface wrapper for the duration of
            // this iteration. The raw ghostty_surface_t extracted below is owned
            // by `surface` (the TerminalSurface) — ARC must not release it while
            // ghostty_surface_inherited_config or cmuxCurrentSurfaceFontSizePoints
            // is still reading through the pointer.
            let surface = terminalPanel.surface
            let inheritanceContext =
                activeTerminalFontSizeChangeInheritanceContext
            let transferProjection =
                terminalFontSizeChangeArbiter?
                    .transferInheritanceProjection(
                        for: terminalPanel
                    )
            let sourceFontSizeLineage:
                TerminalFontSizeLineage?
            if let transferProjection {
                sourceFontSizeLineage =
                    transferProjection.lineage
            } else if let inheritanceContext {
                sourceFontSizeLineage =
                    surface.fontSizeLineageForAdjustment(
                        fallbackRuntimePoints:
                            inheritanceContext
                                .configuredRuntimePoints,
                        magnificationPercent:
                            inheritanceContext
                                .magnificationPercent
                    )
            } else {
                sourceFontSizeLineage =
                    surface.fontSizeLineageSnapshot()
            }
            let inheritedFontSizeLineage: TerminalFontSizeLineage?
            if let inheritanceContext {
                inheritedFontSizeLineage =
                    inheritanceContext.inheritedLineage(
                        from: sourceFontSizeLineage,
                        alreadyIncludesChange:
                            surface.hasAppliedFontSizeChange(
                                token:
                                    inheritanceContext.token
                            )
                            || transferProjection?
                                .representedRequestTokens
                                .contains(
                                    inheritanceContext.token
                                ) == true
                    )
            } else {
                inheritedFontSizeLineage =
                    sourceFontSizeLineage
            }
            var fontSizeChangeTokens =
                surface.fontSizeChangeTokensForInheritance()
            fontSizeChangeTokens.formUnion(
                transferProjection?
                    .representedRequestTokens
                ?? []
            )
            // `liveSurfaceForGhosttyAccess` rather than `surface`: a non-nil wrapper pointer is
            // not proof the native surface is alive, and reading through a freed one gets the
            // process SIGKILLed for lock corruption rather than failing recoverably. It
            // quarantines a pointer the registry no longer owns, so a stale candidate is skipped
            // here exactly like a torn-down one.
            guard let sourceSurface = surface.liveSurfaceForGhosttyAccess(
                reason: "inheritedTerminalConfig"
            ) else {
                if let inheritedFontSizeLineage {
                    var config = CmuxSurfaceConfigTemplate()
                    config.fontSizeLineage = inheritedFontSizeLineage
                    config.fontSizeChangeToken = inheritanceContext?.token
                    config.fontSizeChangeTokens =
                        fontSizeChangeTokens
                    lastTerminalConfigInheritancePanelId = terminalPanel.id
                    lastTerminalConfigInheritanceFontSizeLineage =
                        inheritedFontSizeLineage
                    return config
                }
                continue
            }
            var config = cmuxInheritedSurfaceConfig(
                sourceSurface: sourceSurface,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
            if let inheritedFontSizeLineage {
                config.fontSizeLineage = inheritedFontSizeLineage
            }
            config.fontSizeChangeToken = inheritanceContext?.token
            config.fontSizeChangeTokens =
                fontSizeChangeTokens
            // Prevent ARC from releasing panel/surface before the C calls above complete.
            withExtendedLifetime((terminalPanel, surface)) {}
            rememberTerminalConfigInheritanceSource(terminalPanel)
            if let fontSizeLineage = config.fontSizeLineage {
                lastTerminalConfigInheritanceFontSizeLineage = fontSizeLineage
            }
            return config
        }

        if let fallbackFontSizeLineage =
                activeTerminalFontSizeChangeInheritanceContext?.fallbackLineage
                ?? lastTerminalConfigInheritanceFontSizeLineage {
            var config = CmuxSurfaceConfigTemplate()
            config.fontSizeLineage = fallbackFontSizeLineage
            config.fontSizeChangeToken =
                activeTerminalFontSizeChangeInheritanceContext?.token
#if DEBUG
            cmuxDebugLog(
                "zoom.inherit fallback=lastKnownFont context=split font=\(String(format: "%.2f", fallbackFontSizeLineage.basePoints))"
            )
#endif
            return config
        }

        return nil
    }

    /// Create a new split with a terminal panel
    @discardableResult
    func newTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true,
        workingDirectory: String? = nil,
        initialCommand: String? = nil, initialInput: String? = nil, tmuxStartCommand: String? = nil,
        startupEnvironment: [String: String] = [:],
        initialDividerPosition: CGFloat? = nil,
        allowTextBoxFocusDefault: Bool = true
    ) -> TerminalPanel? {
        return newTerminalSplitOutcome(
            from: panelId,
            orientation: orientation,
            insertFirst: insertFirst,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand, initialInput: initialInput,
            tmuxStartCommand: tmuxStartCommand,
            startupEnvironment: startupEnvironment,
            initialDividerPosition: initialDividerPosition,
            allowTextBoxFocusDefault: allowTextBoxFocusDefault
        ).panel
    }

    /// Like ``newTerminalSplit(from:orientation:insertFirst:focus:workingDirectory:initialCommand:initialInput:tmuxStartCommand:startupEnvironment:initialDividerPosition:allowTextBoxFocusDefault:)``
    /// but distinguishes a split routed to another machine from a genuine
    /// failure, so socket/CLI handlers can report the routed request as accepted.
    func newTerminalSplitOutcome(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true,
        workingDirectory: String? = nil,
        initialCommand: String? = nil, initialInput: String? = nil,
        tmuxStartCommand: String? = nil,
        startupEnvironment: [String: String] = [:],
        initialDividerPosition: CGFloat? = nil,
        allowTextBoxFocusDefault: Bool = true
    ) -> TerminalPanelCreationOutcome {
        guard !isRetiredFromOwningTabManager else { return .failed }
        guard let panel = newTerminalSplitLocal(
            from: panelId,
            orientation: orientation,
            insertFirst: insertFirst,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand, initialInput: initialInput,
            tmuxStartCommand: tmuxStartCommand,
            startupEnvironment: startupEnvironment,
            initialDividerPosition: initialDividerPosition,
            allowTextBoxFocusDefault: allowTextBoxFocusDefault
        ) else { return .failed }
        return .created(panel)
    }

    private func newTerminalSplitLocal(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool,
        workingDirectory: String?,
        initialCommand: String?, initialInput: String?,
        tmuxStartCommand: String?,
        startupEnvironment: [String: String],
        initialDividerPosition: CGFloat?,
        allowTextBoxFocusDefault: Bool
    ) -> TerminalPanel? {
#if DEBUG
        let splitTimingStart = ProcessInfo.processInfo.systemUptime
        let splitTransport = "local"
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=start elapsedMs=0.00"
        )
#endif
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }
        var inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)
        let requestedInitialCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitInitialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil
        let startupCommand = explicitInitialCommand
        let newPanelID = UUID()
        let effectiveStartupEnvironment = startupEnvironmentMergingWorkspaceEnvironment(startupEnvironment)
        // Hold the pane open after an explicit startup command exits so its output
        // stays readable instead of Ghostty silently respawning a login shell.
        if startupCommand != nil {
            var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            inheritedConfig = template
        }
#if DEBUG
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=command_resolved elapsedMs=\(debugElapsedMs(since: splitTimingStart))"
        )
#endif

        // Resolve cwd as explicit request, source reported cwd, source requested
        // startup cwd, then workspace currentDirectory.
        let splitWorkingDirectory = resolvedTerminalStartupWorkingDirectory(
            requestedWorkingDirectory: workingDirectory,
            sourcePanelId: panelId
        )
        let localWorkingDirectory = splitWorkingDirectory
#if DEBUG
        cmuxDebugLog(
            "split.cwd panelId=\(panelId.uuidString.prefix(5)) panelDir=\(panelDirectories[panelId] ?? "nil") requestedDir=\(terminalPanel(for: panelId)?.requestedWorkingDirectory ?? "nil") currentDir=\(currentDirectory) resolved=\(splitWorkingDirectory ?? "nil")"
        )
#endif

        // Create the new terminal panel.
        let newPanel = TerminalPanel(
            id: newPanelID,
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: localWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: startupCommand,
            tmuxStartCommand: tmuxStartCommand, initialInput: initialInput,
            additionalEnvironment: effectiveStartupEnvironment
        )
        configureNewTerminalPanel(
            newPanel,
            allowTextBoxFocusDefault: focus && allowTextBoxFocusDefault
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
#if DEBUG
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=panel_ready elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "newPanel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // Pre-generate the bonsplit tab ID so we can install the panel mapping before bonsplit
        // mutates layout state (avoids transient "Empty Panel" flashes during split).
        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: newPanel.isDirty,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: newPanel.id)
        let previousFocusedPanelId = focusedPanelId

        // Capture the source terminal's hosted view before bonsplit mutates focusedPaneId,
        // so we can hand it to focusPanel as the "move focus FROM" view.
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        // Create the split with the new tab already present in the new pane.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }
        applyInitialSplitDividerPosition(initialDividerPosition, sourcePaneId: paneId, newPaneId: newPaneId)
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: newPanel.id, kind: "terminal", origin: "terminal_split", focused: focus)

#if DEBUG
        cmuxDebugLog("split.created pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation)")
        cmuxDebugLog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=layout_committed elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "newPanel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // Suppress the old view's becomeFirstResponder side-effects during SwiftUI reparenting.
        // Without this, reparenting triggers onFocus + ghostty_surface_set_focus on the old view,
        // stealing focus from the new panel and creating model/surface divergence.
        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.terminalSplitReparent"
            )
            focusPanel(newPanel.id, previousHostedView: previousHostedView)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        }
        rememberTerminalConfigInheritanceSource(newPanel)
#if DEBUG
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=focus_scheduled elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "newPanel=\(newPanel.id.uuidString.prefix(5)) focus=\(focus ? 1 : 0)"
        )
#endif

        owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: id,
            panelId: newPanel.id,
            reason: "splitCreate"
        )

        return newPanel
    }

    /// Create a new surface (nested tab) in the specified pane with a terminal panel.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newTerminalSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        startupRestoreAgent: SessionRestorableAgentSnapshot? = nil,
        startupEnvironment: [String: String] = [:],
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate,
        autoRefreshMetadata: Bool = true,
        preserveFocusWhenUnfocused: Bool = true,
        restoredSurfaceId: UUID? = nil,
        terminalFontSizeCreationPolicy: TerminalFontSizeCreationPolicy = .inherit,
        inheritWorkingDirectoryFallback: Bool = false,
        workingDirectoryFallbackSourcePanelId: UUID? = nil,
        allowTextBoxFocusDefault: Bool = true
    ) -> TerminalPanel? {
        return newTerminalSurfaceOutcome(
            inPane: paneId,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            startupRestoreAgent: startupRestoreAgent,
            startupEnvironment: startupEnvironment,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            autoRefreshMetadata: autoRefreshMetadata,
            preserveFocusWhenUnfocused: preserveFocusWhenUnfocused,
            restoredSurfaceId: restoredSurfaceId,
            terminalFontSizeCreationPolicy: terminalFontSizeCreationPolicy,
            inheritWorkingDirectoryFallback: inheritWorkingDirectoryFallback,
            workingDirectoryFallbackSourcePanelId: workingDirectoryFallbackSourcePanelId,
            allowTextBoxFocusDefault: allowTextBoxFocusDefault
        ).panel
    }

    /// Like ``newTerminalSurface(inPane:focus:workingDirectory:initialCommand:tmuxStartCommand:initialInput:startupRestoreAgent:startupEnvironment:autoRefreshMetadata:preserveFocusWhenUnfocused:)``
    /// but distinguishes a request routed to another machine from a genuine
    /// failure, so socket/CLI handlers can report the routed request as accepted.
    func newTerminalSurfaceOutcome(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        startupRestoreAgent: SessionRestorableAgentSnapshot? = nil,
        startupEnvironment: [String: String] = [:],
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate,
        autoRefreshMetadata: Bool = true,
        preserveFocusWhenUnfocused: Bool = true,
        restoredSurfaceId: UUID? = nil,
        terminalFontSizeCreationPolicy: TerminalFontSizeCreationPolicy = .inherit,
        inheritWorkingDirectoryFallback: Bool = false,
        workingDirectoryFallbackSourcePanelId: UUID? = nil,
        allowTextBoxFocusDefault: Bool = true
    ) -> TerminalPanelCreationOutcome {
        guard !isRetiredFromOwningTabManager else { return .failed }
        guard let panel = newTerminalSurfaceLocal(
            inPane: paneId,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            startupRestoreAgent: startupRestoreAgent,
            startupEnvironment: startupEnvironment,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            autoRefreshMetadata: autoRefreshMetadata,
            preserveFocusWhenUnfocused: preserveFocusWhenUnfocused,
            restoredSurfaceId: restoredSurfaceId,
            terminalFontSizeCreationPolicy: terminalFontSizeCreationPolicy,
            inheritWorkingDirectoryFallback: inheritWorkingDirectoryFallback,
            workingDirectoryFallbackSourcePanelId: workingDirectoryFallbackSourcePanelId,
            allowTextBoxFocusDefault: allowTextBoxFocusDefault
        ) else { return .failed }
        return .created(panel)
    }

    private func newTerminalSurfaceLocal(
        inPane paneId: PaneID,
        focus: Bool?,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        initialInput: String?,
        startupRestoreAgent: SessionRestorableAgentSnapshot?,
        startupEnvironment: [String: String],
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy,
        autoRefreshMetadata: Bool,
        preserveFocusWhenUnfocused: Bool,
        restoredSurfaceId: UUID?,
        terminalFontSizeCreationPolicy: TerminalFontSizeCreationPolicy,
        inheritWorkingDirectoryFallback: Bool,
        workingDirectoryFallbackSourcePanelId: UUID?,
        allowTextBoxFocusDefault: Bool
    ) -> TerminalPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        var inheritedConfig = terminalFontSizeCreationPolicy.applying(
            to: inheritedTerminalConfig(inPane: paneId)
        )
        let requestedInitialCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitInitialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil
        let startupCommand = explicitInitialCommand
        let newPanelID = restoredSurfaceId ?? UUID()
        let effectiveStartupEnvironment = startupEnvironmentMergingWorkspaceEnvironment(startupEnvironment)
        // Hold the PTY open after an explicit startup command exits so its output
        // stays readable instead of a silently-respawned login shell.
        if startupCommand != nil {
            var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            inheritedConfig = template
        }
        let fallbackSourcePanelId = workingDirectoryFallbackSourcePanelId
            ?? bonsplitController.selectedTab(inPane: paneId).map(\.id).flatMap(panelIdFromSurfaceId)
        let localWorkingDirectory = inheritWorkingDirectoryFallback && startupCommand == nil
            ? resolvedTerminalStartupWorkingDirectory(
                requestedWorkingDirectory: workingDirectory,
                sourcePanelId: fallbackSourcePanelId
            )
            : workingDirectory

        // Create new terminal panel. A restored panel reuses its persisted
        // surface id (the panel/surface id IS the ghostty surface id, a
        // Swift-side UUID), so a session's terminal binding survives relaunch
        // and restore. The caller only passes an id it has verified is free.
        let newPanel = TerminalPanel(
            id: newPanelID,
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: localWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: startupCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            additionalEnvironment: effectiveStartupEnvironment,
            runtimeSpawnPolicy: terminalStartupRestoreCoordinator.runtimeSpawnPolicy(
                requestedPolicy: runtimeSpawnPolicy,
                willRunStartupCommand: false,
                willRunStartupInput: startupRestoreAgent != nil && initialInput != nil
            )
        )
        configureNewTerminalPanel(
            newPanel,
            allowTextBoxFocusDefault: shouldFocusNewTab && allowTextBoxFocusDefault
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        // Create tab in bonsplit
        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: newPanel.id)
        if let startupRestoreAgent {
            terminalStartupRestoreCoordinator.stage(
                panel: newPanel,
                snapshot: startupRestoreAgent,
                manualResumeAvailable: true,
                willRunStartupCommand: false,
                willRunStartupInput: initialInput != nil,
                resumeWorkingDirectory: startupRestoreAgent.workingDirectory
            )
            terminalStartupRestoreCoordinator.commitPendingRestores(panelIDs: [newPanel.id])
        }
        publishCmuxSurfaceCreated(newPanel.id, paneId: paneId, kind: "terminal", origin: "terminal_tab", focused: shouldFocusNewTab)

        // bonsplit's createTab may not reliably emit didSelectTab, and its internal selection
        // updates can be deferred. Force a deterministic selection + focus path so the new
        // surface becomes interactive immediately (no "frozen until pane switch" state).
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            newPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else if preserveFocusWhenUnfocused || owningTabManager?.selectedTabId == id {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        } else {
            clearNonFocusSplitFocusReassert()
        }
        terminalFontSizeChangeCoordinator?
            .terminalDidEnterWorkspace(
                newPanel,
                workspace: self
            )
        rememberTerminalConfigInheritanceSource(newPanel)

        if autoRefreshMetadata {
            owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: id,
                panelId: newPanel.id,
                reason: "surfaceCreate"
            )
        }
        return newPanel
    }

    /// Open the markdown viewer for `filePath`, reusing an existing
    /// `MarkdownPanel` in this workspace that already shows the same file.
    /// Paths are compared after symlink resolution so `./README.md` and a
    /// symlink pointing at the same file focus the same viewer.
    /// Returns `nil` when no existing viewer matches and split creation
    /// fails, so callers can fall back to the preferred editor / system opener.
    @discardableResult
    func openOrFocusMarkdownSplit(
        from panelId: UUID,
        filePath: String
    ) -> MarkdownPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let md = panel as? MarkdownPanel else { continue }
            if (md.filePath as NSString).resolvingSymlinksInPath == canonical {
                focusPanel(existingId)
                return md
            }
        }

        if let targetPane = preferredRightSideTargetPane(fromPanelId: panelId) {
            return newMarkdownSurface(inPane: targetPane, filePath: filePath, focus: true)
        }

        return newMarkdownSplit(
            from: panelId,
            orientation: .horizontal,
            insertFirst: false,
            filePath: filePath,
            focus: true
        )
    }

    func newMarkdownSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        filePath: String,
        focus: Bool = true,
        fontSize: Double? = nil
    ) -> MarkdownPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        let markdownPanel = MarkdownPanel(
            workspaceId: id,
            filePath: filePath,
            fontSize: fontSize,
            fileContentChangeCoordinator: fileContentChangeCoordinator
        )
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown.rawValue,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: markdownPanel.id)
        let previousFocusedPanelId = focusedPanelId

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            markdownPanel.close()
            removeSurfaceMapping(forSurfaceId: newTab.id)
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: markdownPanel.id, kind: "markdown", origin: "markdown_split", focused: focus)

        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView
        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.markdownSplitReparent"
            )
            focusPanel(markdownPanel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    @discardableResult
    func newMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> MarkdownPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        let markdownPanel = MarkdownPanel(
            workspaceId: id,
            filePath: filePath,
            fileContentChangeCoordinator: fileContentChangeCoordinator
        )
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown.rawValue,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            markdownPanel.close()
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: markdownPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(markdownPanel.id, paneId: paneId, kind: "markdown", origin: "markdown_tab", focused: shouldFocusNewTab)
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    @discardableResult
    func newProjectSurface(
        inPane paneId: PaneID,
        projectPath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> ProjectPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        guard !projectPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath).standardizedFileURL
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        let projectPanel = ProjectPanel(projectURL: url)
        panels[projectPanel.id] = projectPanel
        panelTitles[projectPanel.id] = projectPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: projectPanel.displayTitle,
            icon: projectPanel.displayIcon,
            kind: SurfaceKind.project.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: projectPanel.id)
            panelTitles.removeValue(forKey: projectPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: projectPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(projectPanel.id, paneId: paneId, kind: SurfaceKind.project.rawValue, origin: "project_tab", focused: shouldFocusNewTab)
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: projectPanel.id,
                previousHostedView: previousHostedView
            )
        }

        projectPanel.reload()
        return projectPanel
    }

    @discardableResult
    func openOrFocusMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool = true,
        duplicateWhenFocused: Bool = false
    ) -> MarkdownPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        let matches = panels.compactMap { existingId, panel -> (UUID, MarkdownPanel)? in
            guard let markdownPanel = panel as? MarkdownPanel,
                  (markdownPanel.filePath as NSString).resolvingSymlinksInPath == canonical else {
                return nil
            }
            return (existingId, markdownPanel)
        }
        if let (focusedId, focusedMatch) = matches.first(where: { $0.0 == focusedPanelId }) {
            // Reveal on the first activation; an activation while the panel is
            // already front-most asks for another occurrence (editor + preview
            // pairs of one file), so interactive entrypoints opt in via
            // `duplicateWhenFocused` while socket/CLI opens stay idempotent.
            guard duplicateWhenFocused, focus else {
                if focus {
                    focusPanel(focusedId)
                }
                return focusedMatch
            }
        } else if let (existingId, existingMatch) = matches.first {
            if focus {
                focusPanel(existingId)
            }
            return existingMatch
        }

        return newMarkdownSurface(inPane: paneId, filePath: filePath, focus: focus)
    }

    @discardableResult
    func splitPaneWithMarkdown(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> MarkdownPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let markdownPanel = MarkdownPanel(
            workspaceId: id,
            filePath: filePath,
            fileContentChangeCoordinator: fileContentChangeCoordinator
        )
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown.rawValue,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: markdownPanel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) != nil else {
            markdownPanel.close()
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }

        bonsplitController.selectTab(newTab.id)
        focusPanel(markdownPanel.id)
        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    @discardableResult
    func openOrFocusFilePreviewSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool = true,
        duplicateWhenFocused: Bool = false
    ) -> FilePreviewPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        let matches = panels.compactMap { existingId, panel -> (UUID, FilePreviewPanel)? in
            guard let preview = panel as? FilePreviewPanel,
                  (preview.filePath as NSString).resolvingSymlinksInPath == canonical else {
                return nil
            }
            return (existingId, preview)
        }
        if let (focusedId, focusedMatch) = matches.first(where: { $0.0 == focusedPanelId }) {
            // See openOrFocusMarkdownSurface: focused + duplicateWhenFocused
            // means the user asked for a second occurrence of this file.
            guard duplicateWhenFocused, focus else {
                if focus {
                    focusPanel(focusedId)
                }
                return focusedMatch
            }
        } else if let (existingId, existingMatch) = matches.first {
            if focus {
                focusPanel(existingId)
            }
            return existingMatch
        }

        return newFilePreviewSurface(inPane: paneId, filePath: filePath, focus: focus)
    }

    @discardableResult
    func openOrFocusFilePreviewSplit(
        from panelId: UUID,
        filePath: String
    ) -> FilePreviewPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let preview = panel as? FilePreviewPanel else { continue }
            if (preview.filePath as NSString).resolvingSymlinksInPath == canonical {
                focusPanel(existingId)
                return preview
            }
        }

        if let targetPane = preferredRightSideTargetPane(fromPanelId: panelId) {
            return newFilePreviewSurface(inPane: targetPane, filePath: filePath, focus: true)
        }

        guard let sourcePaneId = paneId(forPanelId: panelId) else { return nil }
        return splitPaneWithFilePreview(
            targetPane: sourcePaneId,
            orientation: .horizontal,
            insertFirst: false,
            filePath: filePath
        )
    }

    @discardableResult
    func newFilePreviewSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> FilePreviewPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        let filePreviewPanel = FilePreviewPanel(
            workspaceId: id,
            filePath: filePath,
            fileContentChangeCoordinator: fileContentChangeCoordinator
        )
        panels[filePreviewPanel.id] = filePreviewPanel
        panelTitles[filePreviewPanel.id] = filePreviewPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: filePreviewPanel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(filePreviewPanel.displayIcon),
            kind: SurfaceKind.filePreview.rawValue,
            isDirty: filePreviewPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            filePreviewPanel.close()
            panels.removeValue(forKey: filePreviewPanel.id)
            panelTitles.removeValue(forKey: filePreviewPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: filePreviewPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(filePreviewPanel.id, paneId: paneId, kind: "file_preview", origin: "file_preview_tab", focused: shouldFocusNewTab)
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            filePreviewPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: filePreviewPanel.id,
                previousHostedView: previousHostedView
            )
        }

        filePreviewPanel.bindTabMetadata(to: self)
        return filePreviewPanel
    }

    @discardableResult
    func openOrFocusRightSidebarToolSurface(
        inPane paneId: PaneID,
        mode: RightSidebarMode,
        focus: Bool = true
    ) -> RightSidebarToolPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        guard mode.canOpenAsPane, mode.isAvailable() else { return nil }
        for (existingId, panel) in panels {
            guard let toolPanel = panel as? RightSidebarToolPanel,
                  toolPanel.mode == mode else {
                continue
            }
            if focus {
                focusPanel(existingId)
            }
            return toolPanel
        }
        return newRightSidebarToolSurface(inPane: paneId, mode: mode, focus: focus)
    }

    @discardableResult
    func newRightSidebarToolSurface(
        inPane paneId: PaneID,
        mode: RightSidebarMode,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> RightSidebarToolPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        guard mode.canOpenAsPane, mode.isAvailable() else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        let toolPanel = RightSidebarToolPanel(workspace: self, mode: mode)
        panels[toolPanel.id] = toolPanel
        panelTitles[toolPanel.id] = toolPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: toolPanel.displayTitle,
            icon: toolPanel.displayIcon,
            kind: SurfaceKind.rightSidebarTool.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: toolPanel.id)
            panelTitles.removeValue(forKey: toolPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: toolPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(toolPanel.id, paneId: paneId, kind: "right_sidebar_tool", origin: "right_sidebar_tool_tab", focused: shouldFocusNewTab)

        if shouldFocusNewTab {
            focusPanel(toolPanel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: toolPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return toolPanel
    }

    @discardableResult
    func newAgentSessionSurface(
        inPane paneId: PaneID,
        providerID: AgentSessionProviderID = .codex,
        rendererKind: AgentSessionRendererKind,
        workingDirectory: String? = nil,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> AgentSessionPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView
        let directory: String? = {
            if let workingDirectory { return workingDirectory }
            return usesRemoteDirectoryProvenance ? presentedCurrentDirectory : currentDirectory
        }()
        let focusedPanelUsesRemoteFallback = focusedPanelId.map { reportedPanelDirectory(panelId: $0) == nil && terminalPanel(for: $0) == nil } ?? true
        let trustsAgentDirectory = workingDirectory == nil &&
            (focusedPanelId.map { remoteDirectoryReportPanelIds.contains($0) } == true ||
                (usesRemoteDirectoryProvenance && focusedPanelUsesRemoteFallback && directory != nil))

        let agentPanel = AgentSessionPanel(
            workspaceId: id,
            rendererKind: rendererKind,
            initialProviderID: providerID,
            workingDirectory: directory
        )
        panels[agentPanel.id] = agentPanel
        panelTitles[agentPanel.id] = agentPanel.displayTitle
        if let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panelDirectories[agentPanel.id] = directory
            if trustsAgentDirectory { remoteDirectoryReportPanelIds.insert(agentPanel.id); remoteDirectoryTrustRequiredPanelIds.insert(agentPanel.id) }
        }

        guard let newTabId = bonsplitController.createTab(
            title: agentPanel.displayTitle,
            icon: agentPanel.displayIcon,
            kind: SurfaceKind.agentSession.rawValue,
            isDirty: agentPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: agentPanel.id)
            panelTitles.removeValue(forKey: agentPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: agentPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            agentPanel.id,
            paneId: paneId,
            kind: "agent_session",
            origin: "agent_session_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            agentPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: agentPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installAgentSessionPanelSubscription(agentPanel)

        return agentPanel
    }

    @discardableResult
    func splitPaneWithFilePreview(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> FilePreviewPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let filePreviewPanel = FilePreviewPanel(
            workspaceId: id,
            filePath: filePath,
            fileContentChangeCoordinator: fileContentChangeCoordinator
        )
        panels[filePreviewPanel.id] = filePreviewPanel
        panelTitles[filePreviewPanel.id] = filePreviewPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: filePreviewPanel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(filePreviewPanel.displayIcon),
            kind: SurfaceKind.filePreview.rawValue,
            isDirty: filePreviewPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: filePreviewPanel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            filePreviewPanel.close()
            panels.removeValue(forKey: filePreviewPanel.id)
            panelTitles.removeValue(forKey: filePreviewPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: filePreviewPanel.id, kind: "file_preview", origin: "file_preview_split", focused: true)

        bonsplitController.selectTab(newTab.id)
        filePreviewPanel.focus()
        filePreviewPanel.bindTabMetadata(to: self)
        return filePreviewPanel
    }

    /// Permanently retires this workspace before releasing its runtime resources.
    func retireFromOwningTabManager() {
        guard !isRetiredFromOwningTabManager else { return }
        isRetiredFromOwningTabManager = true
        if let sharedLiveAgentIndexObserver {
            NotificationCenter.default.removeObserver(sharedLiveAgentIndexObserver)
            self.sharedLiveAgentIndexObserver = nil
        }
        if let featureFlagsObserver {
            NotificationCenter.default.removeObserver(featureFlagsObserver)
            self.featureFlagsObserver = nil
        }
        teardownAllPanels(retireDock: true)
        owningTabManager = nil
    }

    /// Tears down all panels while keeping the workspace-owned Dock reusable.
    ///
    /// A workspace can remain as a manager's final tab during account cleanup,
    /// so panel teardown must not permanently retire its lazily-created Dock.
    /// ``retireFromOwningTabManager()`` passes `retireDock: true` at the
    /// authoritative workspace-removal boundary.
    func teardownAllPanels(retireDock: Bool = false) {
        SurfaceCatalog.shared.withProjectionEndReason(for: Array(panels.keys), reason: .workspaceTeardown) {
            teardownPanelResources(retireDock: retireDock)
        }
    }
    private func teardownPanelResources(retireDock: Bool) {
        portalRenderingEnabled = false
        clearLayoutFollowUp()
        hideAllTerminalPortalViews()
        if retireDock {
            // Retire the right-sidebar Dock before closing any main-area panel
            // so callbacks triggered by final teardown cannot reuse it.
            _dockSplit?.retire()
        } else {
            // Account cleanup may leave this workspace alive as the manager's
            // final tab; close its panels without invalidating the Dock store.
            _dockSplit?.closeAllPanels()
        }
        let panelEntries = Array(panels)
        for (panelId, panel) in panelEntries {
            discardClosedPanelLifecycleState(
                panelId: panelId,
                tabId: surfaceIdFromPanelId(panelId),
                paneId: paneId(forPanelId: panelId),
                panel: panel,
                origin: "workspace_teardown",
                closePanel: true,
                publishSurfaceClosedEvent: true,
                clearSurfaceNotifications: true,
                discardAgentHibernationTracking: true,
                cleanupControllerSurfaceState: true
            )
        }
        clearAllAgentPIDs(refreshPorts: false)
        pruneSurfaceMetadata(validSurfaceIds: [])
        recomputeListeningPorts()
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.removeAll(keepingCapacity: false)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeAll(keepingCapacity: false)
#endif
        pendingTerminalInputObserversByPanelId.removeAll(keepingCapacity: false)
        lastTerminalConfigInheritancePanelId = nil
        lastTerminalConfigInheritanceFontSizeLineage = nil
    }

    /// Close a panel.
    /// Returns true when a bonsplit tab close request was issued.
    func closePanel(_ panelId: UUID, force: Bool = false) -> Bool {
        if let tabId = surfaceIdFromPanelId(panelId) {
            // Close the tab in bonsplit (this triggers delegate callback)
            return requestCloseTab(tabId, force: force)
        }

        // Mapping can transiently drift during split-tree mutations. If the target panel is
        // currently focused (or is the active terminal first responder), close whichever tab
        // bonsplit marks selected in that focused pane.
        let firstResponderPanelId = (NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder)
            .cmuxStrictOwningGhosttyView()?.terminalSurface?.id
        let targetIsActive = focusedPanelId == panelId || firstResponderPanelId == panelId
        guard targetIsActive,
              let focusedPane = bonsplitController.focusedPaneId,
              let selected = bonsplitController.selectedTab(inPane: focusedPane) else {
#if DEBUG
            cmuxDebugLog(
                "surface.close.fallback.skip panel=\(panelId.uuidString.prefix(5)) " +
                "focusedPanel=\(focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                "firstResponderPanel=\(firstResponderPanelId?.uuidString.prefix(5) ?? "nil") " +
                "focusedPane=\(bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil")"
            )
#endif
            return false
        }

        let closed = requestCloseTab(selected.id, force: force)
#if DEBUG
        cmuxDebugLog(
            "surface.close.fallback panel=\(panelId.uuidString.prefix(5)) " +
            "selectedTab=\(String(describing: selected.id).prefix(5)) " +
            "closed=\(closed ? 1 : 0)"
        )
#endif
        return closed
    }

    func requestCloseTab(_ tabId: TabID, force: Bool) -> Bool {
        if force { forceCloseTabIds.insert(tabId) }
        let closed = bonsplitController.closeTab(tabId); if force && !closed { forceCloseTabIds.remove(tabId) }
        return closed
    }

    /// Returns the nearest right-side sibling pane for markdown/file-preview placement.
    /// The search is local to the source pane's ancestry in the split tree:
    /// use the closest horizontal ancestor where the source is in the first (left) branch.
    func preferredRightSideTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        guard let sourcePane = paneId(forPanelId: panelId) else { return nil }
        return BrowserRightSidePaneResolver().preferredPane(
            from: sourcePane,
            in: bonsplitController
        )
    }

    private func browserCollectPaneNodes(node: ExternalTreeNode, into output: inout [ExternalPaneNode]) {
        switch node {
        case .pane(let paneNode):
            output.append(paneNode)
        case .split(let splitNode):
            browserCollectPaneNodes(node: splitNode.first, into: &output)
            browserCollectPaneNodes(node: splitNode.second, into: &output)
        }
    }

    private struct BrowserCloseFallbackPlan {
        let orientation: SplitOrientation
        let insertFirst: Bool
        let anchorPaneId: UUID?
    }

    private func browserCloseFallbackPlan(
        forPaneId targetPaneId: String,
        in node: ExternalTreeNode
    ) -> BrowserCloseFallbackPlan? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            if case .pane(let firstPane) = splitNode.first, firstPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: true,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.second,
                        targetCenter: browserPaneCenter(firstPane)
                    )
                )
            }

            if case .pane(let secondPane) = splitNode.second, secondPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: false,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.first,
                        targetCenter: browserPaneCenter(secondPane)
                    )
                )
            }

            if let nested = browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.first) {
                return nested
            }
            return browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.second)
        }
    }

    private func browserPaneCenter(_ pane: ExternalPaneNode) -> (x: Double, y: Double) {
        (
            x: pane.frame.x + (pane.frame.width * 0.5),
            y: pane.frame.y + (pane.frame.height * 0.5)
        )
    }

    private func browserNearestPaneId(
        in node: ExternalTreeNode,
        targetCenter: (x: Double, y: Double)?
    ) -> UUID? {
        var panes: [ExternalPaneNode] = []
        browserCollectPaneNodes(node: node, into: &panes)
        guard !panes.isEmpty else { return nil }

        let bestPane: ExternalPaneNode?
        if let targetCenter {
            bestPane = panes.min { lhs, rhs in
                let lhsCenter = browserPaneCenter(lhs)
                let rhsCenter = browserPaneCenter(rhs)
                let lhsDistance = pow(lhsCenter.x - targetCenter.x, 2) + pow(lhsCenter.y - targetCenter.y, 2)
                let rhsDistance = pow(rhsCenter.x - targetCenter.x, 2) + pow(rhsCenter.y - targetCenter.y, 2)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.id < rhs.id
            }
        } else {
            bestPane = panes.first
        }

        guard let bestPane else { return nil }
        return UUID(uuidString: bestPane.id)
    }

    @discardableResult
    func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.allPaneIds.contains(paneId) else { return false }
        guard bonsplitController.moveTab(tabId, toPane: paneId, atIndex: index) else { return false }

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            focusPanel(panelId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    func detachSurface(panelId: UUID) -> DetachedSurfaceTransfer? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        guard let sourcePanel = panels[panelId] else { return nil }
        let surfaceMachine = machineOwningSurface(panelId)
        surfaceTransferringPanelIds.insert(panelId)
        defer { surfaceTransferringPanelIds.remove(panelId) }
        if let terminalPanel = sourcePanel as? TerminalPanel {
            terminalFontSizeChangeCoordinator?
                .terminalWillLeaveWorkspace(
                    terminalPanel,
                    workspace: self
                )
        }
        let sourcePaneId = paneId(forPanelId: panelId)
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
        cmuxDebugLog(
            "split.detach.begin ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) activeDetachTxn=\(activeDetachCloseTransactions) " +
            "pendingDetached=\(pendingDetachedSurfaces.count)"
        )
#endif

        splitLayout.markDetaching(tabId)
        forceCloseTabIds.insert(tabId)
        splitLayout.openDetachCloseTransaction()
        defer { splitLayout.closeDetachCloseTransaction() }
        guard bonsplitController.closeTab(tabId) else {
            splitLayout.cancelDetach(tabId)
            forceCloseTabIds.remove(tabId)
#if DEBUG
            cmuxDebugLog(
                "split.detach.fail ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
                "tab=\(tabId.uuid.uuidString.prefix(5)) reason=closeTabRejected elapsedMs=\(debugElapsedMs(since: detachStart))"
            )
#endif
            return nil
        }

        var detached = splitLayout.takeDetachedTransfer(tabId)
        detached?.surfaceMachine = surfaceMachine
        detached?.origin = .workspace(id)
        if detached == nil {
            (sourcePanel as? any FileContentChangeObservingPanel)?.stopWatchingForFileChanges()
            AgentHibernationController.shared.discardTrackingStateForClosedPanel(
                workspaceId: id,
                panelId: panelId
            )
        }
        publishCmuxSurfaceClosed(panelId, paneId: sourcePaneId, panel: sourcePanel, origin: detached == nil ? "detach_lost" : "detach")
#if DEBUG
        cmuxDebugLog(
            "split.detach.end ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) transfer=\(detached != nil ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: detachStart))"
        )
#endif
        return detached
    }

    @discardableResult
    func attachDetachedSurface(
        _ detached: DetachedSurfaceTransfer,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true,
        focusIntent: PanelFocusIntent? = nil
    ) -> UUID? {
        guard !isRetiredFromOwningTabManager, acceptsDetachedSurface(detached) else { return nil }
#if DEBUG
        let attachStart = ProcessInfo.processInfo.systemUptime
        cmuxDebugLog(
            "split.attach.begin ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0)"
        )
#endif
        guard bonsplitController.allPaneIds.contains(paneId) else {
#if DEBUG
            cmuxDebugLog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=invalidPane elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }
        guard panels[detached.panelId] == nil else {
#if DEBUG
            cmuxDebugLog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=panelExists elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        if let directory = detached.directory {
            panelDirectories[detached.panelId] = directory
        }
        if let directoryDisplayLabel = detached.directoryDisplayLabel {
            panelDirectoryDisplayLabels[detached.panelId] = directoryDisplayLabel
        } else {
            panelDirectoryDisplayLabels.removeValue(forKey: detached.panelId)
        }
        adoptTransferredSurfaceTTYName(from: detached)
        if let cachedTitle = detached.cachedTitle {
            panelTitles[detached.panelId] = cachedTitle
        }
        if let customTitle = detached.customTitle {
            panelCustomTitles[detached.panelId] = customTitle
            panelCustomTitleSources[detached.panelId] = detached.customTitleSource ?? .user
        }
        if detached.isPinned {
            pinnedPanelIds.insert(detached.panelId)
        } else {
            pinnedPanelIds.remove(detached.panelId)
        }
        if detached.manuallyUnread {
            manualUnreadPanelIds.insert(detached.panelId)
            manualUnreadMarkedAt[detached.panelId] = .distantPast
        } else {
            manualUnreadPanelIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
        }
        if let restoredUnreadIndicator = detached.restoredUnreadIndicator {
            restoredUnreadPanelIndicators[detached.panelId] = restoredUnreadIndicator
        } else {
            restoredUnreadPanelIndicators.removeValue(forKey: detached.panelId)
        }
        let detachedIconImageData = detached.panel is TerminalPanel ? nil : detached.iconImageData
        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            hasCustomTitle: detached.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            icon: detached.icon,
            iconImageData: detachedIconImageData,
            kind: detached.kind,
            isDirty: detached.panel.isDirty,
            isLoading: detached.isLoading,
            isPinned: detached.isPinned,
            inPane: paneId
        ) else {
            (detached.panel as? any FileContentChangeObservingPanel)?.stopWatchingForFileChanges()
            panels.removeValue(forKey: detached.panelId)
            panelDirectories.removeValue(forKey: detached.panelId)
            panelDirectoryDisplayLabels.removeValue(forKey: detached.panelId)
            surfaceTTYNames.removeValue(forKey: detached.panelId)
            if surfaceResumeBindingRemovalAllowed(panelId: detached.panelId) {
                surfaceResumeBindingsByPanelId.removeValue(forKey: detached.panelId)
                surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: detached.panelId)
            }
            restoredResumeSessionWorkingDirectoriesByPanelId.removeValue(forKey: detached.panelId)
            panelTitles.removeValue(forKey: detached.panelId)
            panelCustomTitles.removeValue(forKey: detached.panelId)
            panelCustomTitleSources.removeValue(forKey: detached.panelId)
            pinnedPanelIds.remove(detached.panelId)
            manualUnreadPanelIds.remove(detached.panelId)
            restoredUnreadPanelIndicators.removeValue(forKey: detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
            panelSubscriptions.removeValue(forKey: detached.panelId)
            if let agentPanel = detached.panel as? AgentSessionPanel {
                agentPanel.onDisplayStateChanged = nil
                agentSessionPanelCallbackIds.remove(detached.panelId)
            }
#if DEBUG
            cmuxDebugLog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=createTabFailed elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        bindSurface(newTabId, toPanelId: detached.panelId)
        detached.panel.retainTransferredSurfaceMachine(detached.surfaceMachine)
        panels[detached.panelId] = detached.panel
        if let restoredPanelTitleBoundary = detached.restoredPanelTitleBoundary {
            restoredPanelTitleBoundariesByPanelId[detached.panelId] = restoredPanelTitleBoundary
        } else {
            restoredPanelTitleBoundariesByPanelId.removeValue(forKey: detached.panelId)
        }
        if let terminalPanel = detached.panel as? TerminalPanel {
            terminalPanel.updateWorkspaceId(id)
            configureTerminalPanel(terminalPanel)
            terminalPanel.fontSizePanelTransfer?.attach(
                to: self
            )
            terminalFontSizeChangeCoordinator?
                .terminalDidEnterWorkspace(
                    terminalPanel,
                    workspace: self
                )
        } else if let filePreviewPanel = detached.panel as? FilePreviewPanel {
            filePreviewPanel.updateWorkspaceId(
                id,
                fileContentChangeCoordinator: fileContentChangeCoordinator
            )
        } else if let rightSidebarToolPanel = detached.panel as? RightSidebarToolPanel {
            rightSidebarToolPanel.reattach(to: self)
        } else if let customSidebarPanel = detached.panel as? CustomSidebarPanel {
            customSidebarPanel.reattach(to: self)
        }
        AgentHibernationController.shared.transferTrackingStateForMovedPanel(
            panelId: detached.panelId,
            from: detached.sourceWorkspaceId,
            to: id
        )
        AppDelegate.shared?.notificationStore?.rebindSurfaceNotifications(
            fromTabId: detached.sourceWorkspaceId,
            toTabId: id,
            surfaceId: detached.panelId
        )
        let transferredResumeBinding: SurfaceResumeBindingSnapshot? = {
            if let resumeBinding = detached.resumeBinding,
               !resumeBinding.isProcessDetected {
                return resumeBinding
            }
            return detached.resolvedManagedAgentResumeBinding
        }()
        if let transferredResumeBinding {
            if surfaceResumeBindingMutationAllowed(
                transferredResumeBinding,
                panelId: detached.panelId
            ) {
                surfaceResumeBindingsByPanelId[detached.panelId] = transferredResumeBinding
            }
        } else {
            if surfaceResumeBindingRemovalAllowed(panelId: detached.panelId) {
                surfaceResumeBindingsByPanelId.removeValue(forKey: detached.panelId)
                surfaceResumeRestoreClaimsByPanelId.removeValue(forKey: detached.panelId)
            }
        }
        adoptDetachedAgentRuntimeState(detached.agentRuntime)
        if let markdownPanel = detached.panel as? MarkdownPanel {
            markdownPanel.updateWorkspaceId(
                id,
                fileContentChangeCoordinator: fileContentChangeCoordinator
            )
            if panelSubscriptions[markdownPanel.id] == nil {
                installMarkdownPanelSubscription(markdownPanel)
            }
        }
        if let filePreviewPanel = detached.panel as? FilePreviewPanel {
            filePreviewPanel.bindTabMetadata(to: self)
        }
        if let agentPanel = detached.panel as? AgentSessionPanel {
            agentPanel.updateWorkspaceId(id)
            if !agentSessionPanelCallbackIds.contains(agentPanel.id) {
                installAgentSessionPanelSubscription(agentPanel)
            }
        }
        // Seed deferred restore work only after the destination binding is in
        // place. The resolver starts an asynchronous ownership scan.
        seedDetachedRestoredAgentState(from: detached)
        restoreTransferredSurfaceTTYRuntimeProofIfNeeded(from: detached)
        if let index {
            _ = bonsplitController.reorderTab(newTabId, toIndex: index)
        }
        syncPinnedStateForTab(newTabId, panelId: detached.panelId)
        syncUnreadBadgeStateForPanel(detached.panelId)
        normalizePinnedTabs(in: paneId)
        publishCmuxSurfaceCreated(detached.panelId, paneId: paneId, kind: Self.cmuxEventSurfaceKind(detached.panel), origin: "detach_attach", focused: focus)

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId, focusIntent: focusIntent)
            applyFocusedPanelTitle(panelId: detached.panelId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()

#if DEBUG
        cmuxDebugLog(
            "split.attach.end ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "tab=\(newTabId.uuid.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5)) " +
            "index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: attachStart))"
        )
#endif
        return detached.panelId
    }

    // MARK: - Focus Management

    func preserveFocusAfterNonFocusSplit(
        preferredPanelId: UUID?,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?
    ) {
        guard let preferredPanelId, panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert()
            scheduleFocusReconcile()
            return
        }

        let generation = beginNonFocusSplitFocusReassert(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )

        // Bonsplit splitPane focuses the newly created pane and may emit one delayed
        // didSelect/didFocus callback. Re-assert focus over multiple turns so model
        // focus and AppKit first responder stay aligned with non-focus-intent splits.
        reassertFocusAfterNonFocusSplit(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId,
            previousHostedView: previousHostedView,
            allowPreviousHostedView: true
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reassertFocusAfterNonFocusSplit(
                generation: generation,
                preferredPanelId: preferredPanelId,
                splitPanelId: splitPanelId,
                previousHostedView: previousHostedView,
                allowPreviousHostedView: false
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reassertFocusAfterNonFocusSplit(
                    generation: generation,
                    preferredPanelId: preferredPanelId,
                    splitPanelId: splitPanelId,
                    previousHostedView: previousHostedView,
                    allowPreviousHostedView: false
                )
                self.scheduleFocusReconcile()
                self.clearNonFocusSplitFocusReassert(generation: generation)
            }
        }
    }

    private func reassertFocusAfterNonFocusSplit(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?,
        allowPreviousHostedView: Bool
    ) {
        guard matchesPendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        ) else {
            return
        }

        guard panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert(generation: generation)
            return
        }

        if focusedPanelId == splitPanelId {
            focusPanel(
                preferredPanelId,
                previousHostedView: allowPreviousHostedView ? previousHostedView : nil
            )
            return
        }

        guard focusedPanelId == preferredPanelId,
              let terminalPanel = terminalPanel(for: preferredPanelId) else {
            return
        }
        terminalPanel.hostedView.ensureFocus(for: id, surfaceId: preferredPanelId)
    }

    func focusPanel(
        _ panelId: UUID,
        previousHostedView: GhosttySurfaceScrollView? = nil,
        trigger: FocusPanelTrigger = .standard,
        focusIntent: PanelFocusIntent? = nil,
        focusTransactionId: UUID? = nil
    ) {
        let effectiveFocusTransactionId = focusTransactionId ?? activeFocusTransactionId
        markExplicitFocusIntent(on: panelId)
#if DEBUG
        let pane = bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let triggerLabel = trigger == .terminalFirstResponder ? "firstResponder" : "standard"
        let transactionLabel = effectiveFocusTransactionId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog("focus.panel panel=\(panelId.uuidString.prefix(5)) pane=\(pane) trigger=\(triggerLabel) tx=\(transactionLabel)")
        AppDelegate.shared?.focusLog.append(
            "Workspace.focusPanel panelId=\(panelId.uuidString) focusedPane=\(pane) trigger=\(triggerLabel) transactionId=\(transactionLabel)"
        )
#endif
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        // In canvas mode, focusing a panel also brings it forward as its
        // pane's selected tab so focus and visibility never diverge.
        if layoutMode == .canvas {
            canvasModel.selectPanel(panelId)
        }
        let currentlyFocusedPanelId = focusedPanelId

        // Capture the currently focused terminal view so we can explicitly move AppKit first
        // responder when focusing another terminal (helps avoid "highlighted but typing goes to
        // another pane" after heavy split/tab mutations).
        // When a caller passes an explicit previousHostedView (e.g. during split creation where
        // bonsplit has already mutated focusedPaneId), prefer it over the derived value.
        let previousTerminalHostedView = previousHostedView
            ?? focusedTerminalInputTarget()?.panel.hostedView

        // `selectTab` does not necessarily move bonsplit's focused pane. For programmatic focus
        // (socket API, notification click, etc.), ensure the target tab's pane becomes focused
        // so `focusedPanelId` and follow-on focus logic are coherent.
        let targetPaneId = bonsplitController.allPaneIds.first(where: { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        })
        let selectionAlreadyConverged: Bool = {
            guard let targetPaneId else { return false }
            return bonsplitController.focusedPaneId == targetPaneId &&
                bonsplitController.selectedTab(inPane: targetPaneId)?.id == tabId
        }()
        let targetHostedView = terminalPanel(for: panelId)?.hostedView
        let targetHasPendingReparentSuppression = targetHostedView.map { hostedView in
            hostedView.isSuppressingReparentFocusForLayoutFollowUp() ||
                pendingReparentFocusSuppressionViews.values.contains { $0 === hostedView }
        } ?? false
        let shouldSuppressReentrantRefocus =
            trigger == .terminalFirstResponder &&
            selectionAlreadyConverged &&
            targetHasPendingReparentSuppression
#if DEBUG
        let targetPaneShort = targetPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let focusedPaneShort = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabShort = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        let currentPanelShort = currentlyFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "focus.panel.begin workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) trigger=\(String(describing: trigger)) " +
            "targetPane=\(targetPaneShort) focusedPane=\(focusedPaneShort) selectedTab=\(selectedTabShort) " +
            "converged=\(selectionAlreadyConverged ? 1 : 0) " +
            "currentPanel=\(currentPanelShort)"
        )
#endif
        if shouldSuppressReentrantRefocus, currentlyFocusedPanelId == panelId {
            if let targetPaneId, let panel = panels[panelId] {
                let activationIntent = focusIntent ?? panel.preferredFocusIntentForActivation()
                applyTabSelection(
                    tabId: tabId,
                    inPane: targetPaneId,
                    reassertAppKitFocus: false,
                    focusIntent: activationIntent,
                    focusTransactionId: effectiveFocusTransactionId,
                    previousTerminalHostedView: previousTerminalHostedView
                )
            }
            beginEventDrivenLayoutFollowUp(
                reason: "workspace.focusPanel.terminal",
                terminalFocusPanelId: panelId
            )
            return
        }

        if let targetPaneId, !selectionAlreadyConverged {
#if DEBUG
            cmuxDebugLog(
                "focus.panel.focusPane workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) pane=\(targetPaneId.id.uuidString.prefix(5))"
            )
#endif
            bonsplitController.focusPane(targetPaneId)
        }

        if !selectionAlreadyConverged {
#if DEBUG
            cmuxDebugLog(
                "focus.panel.selectTab workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) tab=\(tabId.uuid.uuidString.prefix(5))"
            )
#endif
            bonsplitController.selectTab(tabId)
        }

        if let targetPaneId {
            let activationIntent = focusIntent ?? panels[panelId]?.preferredFocusIntentForActivation()
            applyTabSelection(
                tabId: tabId,
                inPane: targetPaneId,
                reassertAppKitFocus: !shouldSuppressReentrantRefocus,
                focusIntent: activationIntent,
                resumeHibernatedAgent: true,
                focusTransactionId: effectiveFocusTransactionId,
                previousTerminalHostedView: previousTerminalHostedView
            )
        }
        if currentlyFocusedPanelId != panelId {
            syncUnreadBadgeStateForAllPanels()
        }

        if trigger == .terminalFirstResponder,
           panels[panelId] is TerminalPanel {
            beginEventDrivenLayoutFollowUp(
                reason: "workspace.focusPanel.terminal",
                terminalFocusPanelId: panelId
            )
        }
    }

    /// Create a new terminal surface in the currently focused pane
    @discardableResult
    func newTerminalSurfaceInFocusedPane(focus: Bool? = nil, initialInput: String? = nil) -> TerminalPanel? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        // In canvas mode, Cmd+T means "new tab in the focused canvas pane":
        // remember the anchor panel so the new one joins its pane instead of
        // floating as a separate canvas pane.
        let canvasAnchorPanelId = layoutMode == .canvas ? focusedPanelId : nil
        let panel = newTerminalSurface(
            inPane: focusedPaneId,
            focus: focus,
            initialInput: initialInput,
            inheritWorkingDirectoryFallback: true
        )
        if let panel, let anchor = canvasAnchorPanelId {
            joinNewPanelIntoCanvasPane(panel.id, anchor: anchor)
        }
        return panel
    }

    @discardableResult
    func clearSplitZoom() -> Bool {
        bonsplitController.clearPaneZoom()
    }

    @discardableResult
    func toggleSplitZoom(panelId: UUID) -> Bool {
        guard let paneId = paneId(forPanelId: panelId) else { return false }
        guard bonsplitController.togglePaneZoom(inPane: paneId) else { return false }
        focusPanel(panelId)
        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.toggleSplitZoom",
            includeGeometry: true
        )
        return true
    }

    // MARK: - Context Menu Shortcuts

    static func buildContextMenuShortcuts() -> [TabContextAction: KeyboardShortcut] {
        var shortcuts: [TabContextAction: KeyboardShortcut] = [:]
        let mappings: [(TabContextAction, KeyboardShortcutSettings.Action)] = [
            (.rename, .renameTab),
            (.toggleZoom, .toggleSplitZoom),
            (.newTerminalToRight, .newSurface),
        ]
        for (contextAction, settingsAction) in mappings {
            let stored = KeyboardShortcutSettings.shortcut(for: settingsAction)
            if let key = stored.keyEquivalent {
                shortcuts[contextAction] = KeyboardShortcut(key, modifiers: stored.eventModifiers)
            }
        }
        return shortcuts
    }

    private func copyIdentifiersToPasteboard(surfaceId: UUID) {
        let paneId = paneId(forPanelId: surfaceId)?.id
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                workspaceId: id,
                paneId: paneId,
                surfaceId: surfaceId,
                includeRefs: true
            )
        )
    }

    // MARK: - Portal Lifecycle

    /// Hide all terminal portal views for this workspace.
    /// Called before the workspace is unmounted to prevent portal-hosted terminal
    /// views from covering panes in the newly selected workspace.
    func hideAllTerminalPortalViews() {
        for panelID in panels.keys {
            for terminal in terminalPanels(projectedFromPanelID: panelID) {
                terminal.hostedView.setVisibleInUI(false)
                TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
            }
        }
    }

    func setPortalRenderingEnabled(_ enabled: Bool, reason: String) {
        let changed = portalRenderingEnabled != enabled
        portalRenderingEnabled = enabled
        if enabled {
            if changed {
                beginEventDrivenLayoutFollowUp(
                    reason: reason,
                    includeGeometry: true
                )
            }
        } else {
            clearLayoutFollowUp()
            hideAllTerminalPortalViews()
            TerminalWindowPortalRegistry.hideHostedViews(forWorkspaceID: id)
        }
    }

    func setAgentHibernationAutoResumePresentationVisible(_ isVisible: Bool) {
        guard agentHibernationAutoResumePresentationVisible != isVisible else { return }
        agentHibernationAutoResumePresentationVisible = isVisible
        guard isVisible else { return }
        _ = resumeVisibleAgentHibernationPanels(panelIds: agentHibernationVisiblePanelIdsForCurrentLayout())
    }

    /// Create a new terminal panel (used when replacing the last panel)
    @discardableResult
    func createReplacementTerminalPanel() -> TerminalPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let replacementConfig = inheritedTerminalConfig(
            preferredPanelId: focusedPanelId,
            inPane: bonsplitController.focusedPaneId
        )
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: replacementConfig,
            portOrdinal: portOrdinal,
            initialCommand: nil,
            additionalEnvironment: startupEnvironmentMergingWorkspaceEnvironment([:])
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle

        // Create tab in bonsplit
        if let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: newPanel.isDirty,
            isPinned: false
        ) {
            bindSurface(newTabId, toPanelId: newPanel.id)
            rememberTerminalConfigInheritanceSource(newPanel)
        }

        return newPanel
    }

    /// Check if any panel needs close confirmation
    func needsConfirmClose() -> Bool {
        for (panelId, _) in panels {
            if panelNeedsConfirmClose(panelId: panelId) {
                return true
            }
        }
        if _dockSplit?.needsConfirmClose() == true { return true }
        return false
    }

    private func reconcileFocusState() {
        guard portalRenderingEnabled else { return }
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = bonsplitController.focusedPaneId,
           let focusedTab = bonsplitController.selectedTab(inPane: focusedPane),
           let mappedPanelId = panelIdFromSurfaceId(focusedTab.id),
           panels[mappedPanelId] != nil {
            targetPanelId = mappedPanelId
        } else {
            for pane in bonsplitController.allPaneIds {
                guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
                      let mappedPanelId = panelIdFromSurfaceId(selectedTab.id),
                      panels[mappedPanelId] != nil else { continue }
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(selectedTab.id)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = panels.keys.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = surfaceIdFromPanelId(fallbackPanelId),
               let fallbackPane = bonsplitController.allPaneIds.first(where: { paneId in
                   bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == fallbackTabId })
               }) {
                bonsplitController.focusPane(fallbackPane)
                bonsplitController.selectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, let targetPanel = panels[targetPanelId] else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }

        targetPanel.focus()
        if let terminalPanel = targetPanel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: targetPanelId)
        }
        if let dir = panelDirectories[targetPanelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[targetPanelId]
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    func scheduleFocusReconcile() {
        if sessionRestoreLayoutSuppressionDepth > 0 {
            sessionRestoreLayoutFollowUpRequested = true
            return
        }
        guard portalRenderingEnabled else { return }
#if DEBUG
        if isDetachingCloseTransaction {
            debugFocusReconcileScheduledDuringDetachCount += 1
        }
#endif
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.sessionRestoreLayoutSuppressionDepth == 0 else {
                self.focusReconcileScheduled = false
                self.sessionRestoreLayoutFollowUpRequested = true
                return
            }
            guard self.portalRenderingEnabled else {
                self.focusReconcileScheduled = false
                return
            }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    private func beginEventDrivenLayoutFollowUp(
        reason: String,
        terminalFocusPanelId: UUID? = nil,
        includeGeometry: Bool = false
    ) {
        if sessionRestoreLayoutSuppressionDepth > 0 {
            // Bonsplit emits geometry/focus callbacks while its restore tree is
            // still being assembled. Remember one follow-up instead of flushing
            // AppKit/SwiftUI from the middle of that mutation burst.
            sessionRestoreLayoutFollowUpRequested = true
            return
        }
        guard portalRenderingEnabled else { return }
        layoutFollowUpReason = reason
        if let terminalFocusPanelId {
            layoutFollowUpTerminalFocusPanelId = terminalFocusPanelId
        }
        layoutFollowUpNeedsGeometryPass = layoutFollowUpNeedsGeometryPass || includeGeometry
        layoutFollowUpStalledAttemptCount = 0
        // Invalidate any pending retry whose delay was computed from a stale stall count.
        // Incrementing the version causes old closures to exit early; clearing the flag
        // allows scheduleLayoutFollowUpAttempt() below to enqueue a fresh asyncAfter(0).
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false

        if !layoutFollowUpTimeoutScheduler.isScheduled {
            installLayoutFollowUpObservers()
        }
        refreshLayoutFollowUpTimeout()
        // Use async scheduling instead of a synchronous call here. beginEventDrivenLayoutFollowUp
        // is often invoked from splitTabBar(_:didChangeGeometry:), which fires from inside
        // SwiftUI's .onChange(of: geometry) during an active layout pass. Calling
        // attemptEventDrivenLayoutFollowUp() synchronously in that context causes
        // flushWorkspaceWindowLayouts() → displayIfNeeded() to be called re-entrantly,
        // incrementing AppKit's per-window constraint-pass counter on every display cycle
        // until it exceeds the limit and crashes with NSGenericException.
        // scheduleLayoutFollowUpAttempt() defers via asyncAfter(0) so the flush always
        // happens after the current layout pass completes.
        scheduleLayoutFollowUpAttempt()
    }

    func suppressReparentFocusUntilLayoutFollowUp(
        _ hostedView: GhosttySurfaceScrollView?,
        reason: String,
        terminalFocusPanelId: UUID? = nil
    ) {
        guard hostedView != nil || terminalFocusPanelId != nil else { return }
        if let hostedView {
            hostedView.suppressReparentFocus()
            pendingReparentFocusSuppressionViews[ObjectIdentifier(hostedView)] = hostedView
#if DEBUG
            cmuxDebugLog("focus.reparent.suppressPending reason=\(reason) count=\(pendingReparentFocusSuppressionViews.count)")
#endif
        }

        guard portalRenderingEnabled else {
            clearPendingReparentFocusSuppressions(reason: "\(reason).portalDisabled")
            return
        }

        beginEventDrivenLayoutFollowUp(
            reason: reason,
            terminalFocusPanelId: terminalFocusPanelId,
            includeGeometry: true
        )
    }

    private func clearPendingReparentFocusSuppressions(reason: String) {
        guard !pendingReparentFocusSuppressionViews.isEmpty else { return }
        let hostedViews = Array(pendingReparentFocusSuppressionViews.values)
        pendingReparentFocusSuppressionViews.removeAll()
#if DEBUG
        cmuxDebugLog("focus.reparent.clearPending reason=\(reason) count=\(hostedViews.count)")
#endif
        for hostedView in hostedViews {
            hostedView.clearSuppressReparentFocus()
        }
    }

    private func clearReadyPendingReparentFocusSuppressions(reason: String) {
        guard !pendingReparentFocusSuppressionViews.isEmpty else { return }
        let readyKeys = pendingReparentFocusSuppressionViews.compactMap { key, hostedView in
            hostedView.canClearPendingReparentFocusSuppressionAfterLayoutAttempt() ? key : nil
        }
        guard !readyKeys.isEmpty else { return }
        let hostedViews = readyKeys.compactMap { pendingReparentFocusSuppressionViews[$0] }
        for key in readyKeys {
            pendingReparentFocusSuppressionViews.removeValue(forKey: key)
        }
#if DEBUG
        cmuxDebugLog("focus.reparent.clearReady reason=\(reason) count=\(hostedViews.count)")
#endif
        for hostedView in hostedViews {
            hostedView.clearSuppressReparentFocus()
        }
    }

#if DEBUG
    func debugBeginReparentFocusSuppressionForTesting(_ hostedView: GhosttySurfaceScrollView, reason: String) {
        suppressReparentFocusUntilLayoutFollowUp(hostedView, reason: reason)
    }

    func debugAttemptEventDrivenLayoutFollowUpForTesting() {
        attemptEventDrivenLayoutFollowUp()
    }

    func debugHasPendingReparentFocusSuppressionsForTesting() -> Bool {
        !pendingReparentFocusSuppressionViews.isEmpty
    }
#endif

    private func installLayoutFollowUpObservers() {
        guard !layoutFollowUpTimeoutScheduler.isScheduled else { return }

        let enqueueAttempt: () -> Void = { [weak self] in
            self?.wakeLayoutFollowUpForStructuralEvent()
        }

        // Intentionally NOT observing NSWindow.didUpdateNotification: AppKit posts
        // it on every event-loop tick during tracking (scroll, drag), which pumped
        // flushWorkspaceWindowLayouts() per scroll tick while a session was open.
        // Convergence comes from the self-rescheduling attempt loop plus the
        // structural observers below (https://github.com/manaflow-ai/cmux/issues/6790).
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpPanelsCancellable = panelsPublisher
            .map { _ in () }
            .sink { _ in
                enqueueAttempt()
            }
    }

    private func refreshLayoutFollowUpTimeout() {
        layoutFollowUpTimeoutScheduler.schedule(after: .seconds(2)) { [weak self] in
            self?.clearLayoutFollowUp()
        }
    }

    private func clearLayoutFollowUp() {
        clearPendingReparentFocusSuppressions(reason: "workspace.layoutFollowUpEnd")
        layoutFollowUpTimeoutScheduler.cancel()
        layoutFollowUpObservers.forEach { NotificationCenter.default.removeObserver($0) }
        layoutFollowUpObservers.removeAll()
        layoutFollowUpPanelsCancellable?.cancel()
        layoutFollowUpPanelsCancellable = nil
        layoutFollowUpReason = nil
        layoutFollowUpTerminalFocusPanelId = nil
        layoutFollowUpNeedsGeometryPass = false
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false
        layoutFollowUpStalledAttemptCount = 0
    }

    /// Structural events (surface ready, hosted view moved, portal visibility,
    /// first responder, panels change) are edge-triggered, so they preempt a
    /// pending stall-backoff retry instead of being dropped by the
    /// already-scheduled guard (worst case: a retry scheduled past the 2s
    /// timeout never ran). Mirrors the reset in beginEventDrivenLayoutFollowUp.
    private func wakeLayoutFollowUpForStructuralEvent() {
        guard sessionRestoreLayoutSuppressionDepth == 0 else {
            sessionRestoreLayoutFollowUpRequested = true
            return
        }
        guard layoutFollowUpTimeoutScheduler.isScheduled else { return }
        layoutFollowUpStalledAttemptCount = 0
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false
        scheduleLayoutFollowUpAttempt()
    }

    private func scheduleLayoutFollowUpAttempt() {
        guard portalRenderingEnabled else { return }
        guard layoutFollowUpTimeoutScheduler.isScheduled else { return }
        guard !layoutFollowUpAttemptScheduled else { return }

        layoutFollowUpAttemptScheduled = true
        let delay = layoutFollowUpBackoffDelay()
        let version = layoutFollowUpAttemptVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.layoutFollowUpAttemptVersion == version else { return }
            guard self.sessionRestoreLayoutSuppressionDepth == 0 else {
                self.layoutFollowUpAttemptScheduled = false
                self.sessionRestoreLayoutFollowUpRequested = true
                return
            }
            guard self.portalRenderingEnabled else {
                self.layoutFollowUpAttemptScheduled = false
                self.clearLayoutFollowUp()
                return
            }
            self.layoutFollowUpAttemptScheduled = false
            self.attemptEventDrivenLayoutFollowUp()
        }
    }

    private func layoutFollowUpBackoffDelay() -> TimeInterval {
        guard layoutFollowUpStalledAttemptCount > 0 else { return 0 }
        let baseDelay: TimeInterval = 0.01
        let exponent = min(layoutFollowUpStalledAttemptCount - 1, 5)
        return min(0.25, baseDelay * pow(2.0, Double(exponent)))
    }

    private func flushWorkspaceWindowLayouts() {
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func terminalFocusNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpTerminalFocusPanelId,
              let terminalPanel = terminalPanel(for: panelId) else {
            return false
        }
        return focusedPanelId != panelId || !terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    private func attemptEventDrivenLayoutFollowUp() {
        guard layoutFollowUpTimeoutScheduler.isScheduled, !isAttemptingLayoutFollowUp else { return }
        guard portalRenderingEnabled else {
            clearLayoutFollowUp()
            hideAllTerminalPortalViews()
            return
        }
        isAttemptingLayoutFollowUp = true
        defer { isAttemptingLayoutFollowUp = false }

        flushWorkspaceWindowLayouts()

        let geometryPendingBefore = layoutFollowUpNeedsGeometryPass
        let terminalPortalPendingBefore = terminalPortalVisibilityNeedsFollowUp()
        let terminalFocusPendingBefore = terminalFocusNeedsFollowUp()
        let reparentFocusPendingBefore = !pendingReparentFocusSuppressionViews.isEmpty

        if layoutFollowUpNeedsGeometryPass {
            layoutFollowUpNeedsGeometryPass = reconcileTerminalGeometryPass()
        }

        if let terminalFocusPanelId = layoutFollowUpTerminalFocusPanelId {
            if let terminalPanel = terminalPanel(for: terminalFocusPanelId),
               focusedPanelId == terminalFocusPanelId {
                terminalPanel.hostedView.ensureFocus(for: id, surfaceId: terminalFocusPanelId)
                if terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    layoutFollowUpTerminalFocusPanelId = nil
                }
            } else if terminalPanel(for: terminalFocusPanelId) == nil {
                layoutFollowUpTerminalFocusPanelId = nil
            }
        }

        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        let terminalPortalPending = terminalPortalVisibilityNeedsFollowUp()
        clearReadyPendingReparentFocusSuppressions(reason: "workspace.layoutAttempt")
        let reparentFocusPending = !pendingReparentFocusSuppressionViews.isEmpty

        let terminalFocusPending = terminalFocusNeedsFollowUp()
        let needsMoreWork =
            layoutFollowUpNeedsGeometryPass ||
            terminalPortalPending ||
            terminalFocusPending ||
            reparentFocusPending

        if !needsMoreWork {
            clearLayoutFollowUp()
            return
        }

        let didMakeProgress =
            (geometryPendingBefore && !layoutFollowUpNeedsGeometryPass) ||
            (terminalPortalPendingBefore && !terminalPortalPending) ||
            (terminalFocusPendingBefore && !terminalFocusPending) ||
            (reparentFocusPendingBefore && !reparentFocusPending)

        if didMakeProgress {
            layoutFollowUpStalledAttemptCount = 0
        } else {
            layoutFollowUpStalledAttemptCount += 1
        }
        // Keep retrying while work remains, including on stall (backoff capped
        // 0.25s, bounded by the follow-up timeout). Stalled repairs previously
        // relied on the per-tick NSWindow.didUpdate wake removed above.
        // Structural events preempt the backoff via
        // wakeLayoutFollowUpForStructuralEvent.
        scheduleLayoutFollowUpAttempt()
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    private func reconcileTerminalGeometryPass() -> Bool {
        var needsFollowUpPass = false
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        // Flush pending AppKit layout first so terminal-host bounds reflect latest split topology.
        for window in NSApp.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
        }

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            guard visiblePanelIds.contains(terminalPanel.id) else { continue }
            let hostedView = terminalPanel.hostedView
            let hasUsableBounds = hostedView.bounds.width > 1 && hostedView.bounds.height > 1
            let hasSurface = terminalPanel.surface.surface != nil
            let isAttached = terminalPanel.surface.isViewInWindow && hostedView.superview != nil

            // Split close/reparent churn can transiently detach a surviving terminal view.
            // Force one SwiftUI representable update so the portal binding reattaches it.
            if !isAttached || !hasUsableBounds || !hasSurface {
                terminalPanel.requestViewReattach()
                needsFollowUpPass = true
            }

            hostedView.reconcileGeometryNow()
            // Re-check surface after reconcileGeometryNow() which can trigger AppKit
            // layout and view lifecycle changes that free surfaces (#432).
            if terminalPanel.surface.surface != nil {
                terminalPanel.surface.forceRefresh()
            }
            if terminalPanel.surface.surface == nil, isAttached && hasUsableBounds {
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                needsFollowUpPass = true
            }
        }

        return needsFollowUpPass
    }

#if DEBUG
    func setRestoredAgentSnapshotForTesting(_ snapshot: SessionRestorableAgentSnapshot, panelId: UUID) {
        restoredAgentLifecycle.setSnapshot(snapshot, panelId: panelId)
        invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
    }

    func restoredAgentSnapshotForTesting(panelId: UUID) -> SessionRestorableAgentSnapshot? {
        restoredAgentSnapshotsByPanelId[panelId]
    }

    func setRestoredAgentAutoResumePendingForTesting(_ isPending: Bool, panelId: UUID) {
        if isPending {
            restoredAgentLifecycle.setResumeState(.awaitingAutoResumeCommand, panelId: panelId)
        } else {
            restoredAgentLifecycle.setResumeState(nil, panelId: panelId)
        }
    }

    func restoredAgentAutoResumePendingForTesting(panelId: UUID) -> Bool {
        restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand
    }
#endif

    func scheduleTerminalGeometryReconcile() {
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.geometry",
            includeGeometry: true
        )
    }

    private func renderedVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        guard portalRenderingEnabled else { return [] }
        // Canvas mode renders one panel per canvas pane — its selected tab.
        // Background tabs are unmounted, so reporting them as rendered makes
        // the terminal window portal float them at stale frames (chromeless
        // slivers). Offscreen clipping of the selected tabs is the canvas
        // viewport's job.
        if layoutMode == .canvas {
            return Set(canvasModel.layout.panes.map(\.selectedPanelId.rawValue))
        }
        let renderedPaneIds = bonsplitController.zoomedPaneId.map { [$0] } ?? bonsplitController.allPaneIds
        var visiblePanelIds: Set<UUID> = []
        let focusedPanelForFallback = focusedPanelId.flatMap { panelId in
            panels[panelId] == nil ? nil : panelId
        }
        let focusedPanelPaneId = focusedPanelForFallback.flatMap { paneId(forPanelId: $0)?.id }

        for paneId in renderedPaneIds {
            let selectedPanelId = bonsplitController
                .selectedTab(inPane: paneId)
                .flatMap { panelIdFromSurfaceId($0.id) }
                .flatMap { panels[$0] == nil ? nil : $0 }
            let firstPanelId = bonsplitController
                .tabs(inPane: paneId)
                .compactMap { tab -> UUID? in
                    guard let panelId = panelIdFromSurfaceId(tab.id),
                          panels[panelId] != nil else {
                        return nil
                    }
                    return panelId
                }
                .first
            if let panelId = WorkspacePanelVisibilityPolicy.visiblePanelIdForRenderedPane(
                paneId: paneId.id,
                selectedPanelId: selectedPanelId,
                firstPanelId: firstPanelId,
                focusedPanelId: focusedPanelForFallback,
                focusedPanelPaneId: focusedPanelPaneId
            ) {
                visiblePanelIds.insert(panelId)
            }
        }

        return visiblePanelIds
    }

    func agentHibernationVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        guard agentHibernationAutoResumePresentationVisible else { return [] }
        return renderedVisiblePanelIdsForCurrentLayout()
    }

    @discardableResult
    func reconcileTerminalPortalVisibilityForCurrentRenderedLayout() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        // Focus-exclusivity: when the right sidebar (Dock) owns input focus in this
        // window, no main terminal should be (re)marked active even if it is still
        // this workspace's focused panel — mirroring the SwiftUI `isFocused` gate so
        // a layout reconcile cannot steal focus back from the sidebar.
        let rightSidebarOwnsFocus = AppDelegate.shared?.rightSidebarOwnsInputFocus(for: self) ?? false
        var didChange = agentHibernationAutoResumePresentationVisible
            ? resumeVisibleAgentHibernationPanels(panelIds: visiblePanelIds)
            : false

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalPanel.id)
            if terminalPanel.hostedView.debugPortalVisibleInUI != shouldBeVisible {
                terminalPanel.hostedView.setVisibleInUI(shouldBeVisible)
                didChange = true
            }
            let shouldBeActive = shouldBeVisible && focusedPanelId == terminalPanel.id && !rightSidebarOwnsFocus
            if terminalPanel.hostedView.debugPortalActive != shouldBeActive {
                terminalPanel.hostedView.setActive(shouldBeActive)
                didChange = true
            }
            TerminalWindowPortalRegistry.updateEntryVisibility(
                for: terminalPanel.hostedView,
                visibleInUI: shouldBeVisible
            )
        }

        return didChange
    }

    private func terminalPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalPanel.id)
            let hostedView = terminalPanel.hostedView

            if shouldBeVisible {
                if hostedView.isHidden || !terminalPanel.surface.isViewInWindow || hostedView.superview == nil {
                    return true
                }
            } else if !hostedView.isHidden {
                return true
            }
        }

        return false
    }

#if DEBUG
    @discardableResult
    func debugReconcileTerminalPortalVisibilityForTesting() -> Bool {
        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
    }
#endif

    private func scheduleMovedTerminalRefresh(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }

        // Force an NSViewRepresentable update after drag/move reparenting. This keeps
        // portal host binding current when a pane auto-closes during tab moves.
        terminalPanel(for: panelId)?.requestViewReattach()

        let runRefreshPass: (TimeInterval) -> Void = { [weak self] delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self, let panel = self.terminalPanel(for: panelId) else { return }
                panel.hostedView.reconcileGeometryNow()
                if panel.surface.surface != nil {
                    panel.surface.forceRefresh()
                }
                if panel.surface.surface == nil {
                    panel.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
        }

        // Run once immediately and once on the next turn so rapid split close/reparent
        // sequences still get a post-layout redraw.
        runRefreshPass(0)
        runRefreshPass(0.03)
    }

    private func closeTabs(_ tabIds: [TabID], skipPinned: Bool = true) { closeTabsFromContextMenu(tabIds, skipPinned: skipPinned) }

    private func tabIdsToLeft(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        surfaceList.surfaceIdsToLeft(of: anchorTabId.uuid, inPaneId: paneId.id).map { TabID(uuid: $0) }
    }

    private func tabIdsToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        surfaceList.surfaceIdsToRight(of: anchorTabId.uuid, inPaneId: paneId.id).map { TabID(uuid: $0) }
    }

    private func tabIdsToCloseOthers(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        surfaceList.surfaceIdsToCloseOthers(of: anchorTabId.uuid, inPaneId: paneId.id).map { TabID(uuid: $0) }
    }

    private func createTerminalToRight(of anchorTabId: TabID, inPane paneId: PaneID) {
        let sourcePanelId = panelIdFromSurfaceId(anchorTabId)
        guard let newPanel = newTerminalSurface(
            inPane: paneId,
            focus: true,
            inheritWorkingDirectoryFallback: true,
            workingDirectoryFallbackSourcePanelId: sourcePanelId
        ) else { return }
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func promptRenamePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameTab.title", defaultValue: "Rename Tab")
        alert.informativeText = String(localized: "alert.renameTab.message", defaultValue: "Enter a custom name for this tab.")
        let currentTitle = panelCustomTitles[panelId] ?? panelTitles[panelId] ?? panel.displayTitle
        let input = NSTextField(string: currentTitle)
        input.placeholderString = String(localized: "alert.renameTab.placeholder", defaultValue: "Tab name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameTab.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        let response = alert.runCmuxModal(
            presentingWindow: AppDelegate.shared?.mainWindowContainingWorkspace(id)
        ) { _ in
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        guard response == .alertFirstButtonReturn else { return }
        setPanelCustomTitle(panelId: panelId, title: input.stringValue)
    }

    private static let bonsplitMoveNewWorkspaceDestinationId = "new-workspace"
    private static let bonsplitMoveExistingWorkspacePrefix = "workspace:"

    private func bonsplitTabMoveDestinations(for tabId: TabID) -> [TabContextMoveDestination] {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let app = AppDelegate.shared else { return [] }

        let workspaceTargets = app.workspaceMoveTargets(forBonsplitTab: tabId.uuid)
        var destinations: [TabContextMoveDestination] = []
        if app.canMoveSurfaceToNewWorkspace(panelId: panelId) {
            destinations.append(TabContextMoveDestination(
                id: Self.bonsplitMoveNewWorkspaceDestinationId,
                title: String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")
            ))
        }
        destinations.append(contentsOf: workspaceTargets.map { target in
            TabContextMoveDestination(
                id: Self.bonsplitMoveExistingWorkspacePrefix + target.workspaceId.uuidString,
                title: target.label
            )
        })
        return destinations
    }

    @discardableResult
    private func moveBonsplitTab(_ tabId: TabID, toMoveDestination destinationId: String) -> Bool {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let app = AppDelegate.shared else { return false }

        let moved: Bool
        if destinationId == Self.bonsplitMoveNewWorkspaceDestinationId {
            moved = app.moveSurfaceToNewWorkspace(
                panelId: panelId,
                focus: true,
                focusWindow: false
            ) != nil
        } else if destinationId.hasPrefix(Self.bonsplitMoveExistingWorkspacePrefix) {
            let rawWorkspaceId = destinationId.dropFirst(Self.bonsplitMoveExistingWorkspacePrefix.count)
            guard let workspaceId = UUID(uuidString: String(rawWorkspaceId)) else { return false }
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspaceId,
                focus: true,
                focusWindow: true
            )
        } else {
            moved = false
        }

        if !moved {
            showMoveTabFailureAlert()
        }
        return moved
    }

    private func showMoveTabFailureAlert() {
        let failure = NSAlert()
        failure.alertStyle = .warning
        failure.messageText = String(localized: "alert.moveTab.failed.title", defaultValue: "Move Failed")
        failure.informativeText = String(localized: "alert.moveTab.failed.message", defaultValue: "cmux could not move this tab to the selected destination.")
        failure.addButton(withTitle: String(localized: "alert.ok", defaultValue: "OK"))
        _ = failure.runModal()
    }

    func handleSessionDrop(
        entry: SessionEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        guard let launch = entry.resumeLaunch else { return false }
        switch destination {
        case .insert(let paneId, _):
            let panel = newTerminalSurface(
                inPane: paneId,
                focus: true,
                workingDirectory: launch.workingDirectory,
                initialInput: launch.initialInput,
                startupRestoreAgent: launch.startupRestoreAgent
            )
            return panel != nil
        case .split(let paneId, let orientation, let insertFirst):
            let panel = splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                workingDirectory: launch.workingDirectory,
                initialInput: launch.initialInput,
                startupRestoreAgent: launch.startupRestoreAgent
            )
            return panel != nil
        }
    }

    func handleFilePreviewDrop(
        entry: FilePreviewDragEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        switch destination {
        case .insert(let paneId, let index):
            return !openFileSurfaces(
                inPane: paneId,
                filePaths: [entry.filePath],
                focus: true,
                targetIndex: index
            ).isEmpty
        case .split(let paneId, let orientation, let insertFirst):
            guard let panel = splitPaneWithFileSurface(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: entry.filePath
            ) else {
                return false
            }
            handKeyboardFocusFromRightSidebarAfterFileOpen(to: panel)
            return true
        }
    }

    func handleExternalFileDrop(_ request: BonsplitController.ExternalFileDropRequest) -> Bool {
        let entries = request.urls
            .filter(\.isFileURL)
            .map {
                FilePreviewDragEntry(
                    filePath: $0.path,
                    displayTitle: $0.lastPathComponent
                )
            }
        guard !entries.isEmpty else { return false }

        switch request.destination {
        case .insert(let paneId, let index):
            // openFileSurfaces(focus: true) performs the sidebar focus
            // handoff itself.
            return !openFileSurfaces(
                inPane: paneId,
                filePaths: entries.map(\.filePath),
                focus: true,
                targetIndex: index
            ).isEmpty

        case .split(let sourcePaneId, let orientation, let insertFirst):
            guard let first = entries.first,
                  let firstPanel = splitPaneWithFileSurface(
                    targetPane: sourcePaneId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    filePath: first.filePath
                  ) else {
                return false
            }

            let targetPane = paneId(forPanelId: firstPanel.id) ?? sourcePaneId
            _ = openFileSurfaces(
                inPane: targetPane,
                filePaths: entries.dropFirst().map(\.filePath),
                focus: true
            )
            handKeyboardFocusFromRightSidebarAfterFileOpen(to: firstPanel)
            return true
        }
    }

    /// A sidebar-initiated open (click on a file row, or a drag whose
    /// mouse-down made the sidebar first responder) never resigns the
    /// sidebar's keyboard focus by itself, and a freshly created panel's
    /// view may not be mounted yet when activation asks it to take first
    /// responder. Without this handoff the find/shortcut router keeps
    /// targeting the sidebar (Cmd+F lands in its file search instead of the
    /// just-opened document). Hand keyboard focus to the opened panel the
    /// same way the text-drop path does; the call is a no-op when the
    /// sidebar does not own focus (opens from Finder, the CLI, or between
    /// panes).
    func handKeyboardFocusFromRightSidebarAfterFileOpen(to panel: any Panel) {
        _ = AppDelegate.shared?.restoreMainPanelKeyboardFocusFromRightSidebar(
            in: activationWindow(for: panel)
        )
    }

    @discardableResult
    private func splitPaneWithFileSurface(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> (any Panel)? {
        if MarkdownPanelFileLinkResolver.isMarkdownPathLike(filePath) {
            return splitPaneWithMarkdown(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: filePath
            )
        }
        return splitPaneWithFilePreview(
            targetPane: paneId,
            orientation: orientation,
            insertFirst: insertFirst,
            filePath: filePath
        )
    }

    /// Split `paneId` and place a brand-new terminal in the resulting pane.
    /// Used by the session-index drop path; mirrors `newTerminalSplit(from:...)` but
    /// targets a destination pane directly rather than inheriting from a source panel.
    @discardableResult
    func splitPaneWithNewTerminal(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        workingDirectory: String?,
        initialInput: String?,
        startupRestoreAgent: SessionRestorableAgentSnapshot? = nil
    ) -> TerminalPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let inheritedConfig = inheritedTerminalConfig(inPane: paneId)
        let effectiveStartupEnvironment = startupEnvironmentMergingWorkspaceEnvironment([:])

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: nil,
            initialInput: initialInput,
            additionalEnvironment: effectiveStartupEnvironment,
            runtimeSpawnPolicy: terminalStartupRestoreCoordinator.runtimeSpawnPolicy(
                requestedPolicy: .immediate,
                willRunStartupCommand: false,
                willRunStartupInput: startupRestoreAgent != nil && initialInput != nil
            )
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: newPanel.isDirty,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: newPanel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }
        if let startupRestoreAgent {
            terminalStartupRestoreCoordinator.stage(
                panel: newPanel,
                snapshot: startupRestoreAgent,
                manualResumeAvailable: true,
                willRunStartupCommand: false,
                willRunStartupInput: initialInput != nil,
                resumeWorkingDirectory: startupRestoreAgent.workingDirectory
            )
            terminalStartupRestoreCoordinator.commitPendingRestores(panelIDs: [newPanel.id])
        }
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: newPanel.id, kind: "terminal", origin: "terminal_split", focused: true)

        bonsplitController.selectTab(newTab.id)
        newPanel.focus()
        rememberTerminalConfigInheritanceSource(newPanel)
        return newPanel
    }

    struct AgentConversationForkWorkspaceLaunch {
        var workingDirectory: String?
        var terminalWorkingDirectory: String?
        var initialTerminalInput: String
        var startupRestoreAgent: SessionRestorableAgentSnapshot?
    }

    func forkAgentWorkspaceLaunch(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> AgentConversationForkWorkspaceLaunch? {
        let workingDirectory = forkAgentWorkingDirectory(fromPanelId: panelId, snapshot: snapshot)
        let launchSnapshot = snapshot.retargetingForkWorkingDirectory(workingDirectory)
        guard panels[panelId] is TerminalPanel,
              let startupInput = forkStartupInput(
                  snapshot: launchSnapshot,
                  panelId: panelId,
                  useLocalForkVerb: true,
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  allowLauncherScript: true,
                  dialect: .loginShell
              ) else {
            return nil
        }
        return AgentConversationForkWorkspaceLaunch(
            workingDirectory: workingDirectory,
            terminalWorkingDirectory: workingDirectory,
            initialTerminalInput: startupInput,
            startupRestoreAgent: launchSnapshot
        )
    }
    @discardableResult
    func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        direction: SplitDirection,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> TerminalPanel? {
        let workingDirectory = forkAgentWorkingDirectory(fromPanelId: panelId, snapshot: snapshot)
        let launchSnapshot = snapshot.retargetingForkWorkingDirectory(workingDirectory)
        guard panels[panelId] is TerminalPanel,
              let paneId = paneId(forPanelId: panelId),
              let startupInput = forkStartupInput(
                  snapshot: launchSnapshot,
                  panelId: panelId,
                  useLocalForkVerb: true,
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  allowLauncherScript: true,
                  dialect: .loginShell
              ) else {
            return nil
        }
        let zoomedPaneId = bonsplitController.zoomedPaneId
        if zoomedPaneId != nil {
            clearSplitZoom()
        }
        let forkedPanel = splitPaneWithNewTerminal(
            targetPane: paneId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            workingDirectory: workingDirectory,
            initialInput: startupInput,
            startupRestoreAgent: launchSnapshot
        )
        if forkedPanel == nil, let zoomedPaneId {
            _ = bonsplitController.togglePaneZoom(inPane: zoomedPaneId)
        }
        return forkedPanel
    }

    func forkAgentWorkingDirectory(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) -> String? {
        Self.firstNonEmptyPath([
            snapshot.workingDirectory,
            panelDirectories[panelId],
            terminalPanel(for: panelId)?.requestedWorkingDirectory,
            currentDirectory
        ])
    }

    /// Synchronous availability check used by right-click entry points. Probe-required
    /// sessions remain unavailable while their shared validation refresh is in flight.
    func canForkAgentConversationFromPanel(_ panelId: UUID) -> Bool {
        forkAgentConversationContextMenuPresentationAvailability(forPanelId: panelId).isAvailable
    }

    /// Fork the panel's agent conversation into a brand-new sibling tab placed immediately
    /// to the right of `anchorTabId` in `paneId`, using the structured `cmux fork` selector.
    @discardableResult
    func forkAgentConversationToNewTab(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        anchorTabId: TabID,
        paneId: PaneID,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> TerminalPanel? {
        let workingDirectory = forkAgentWorkingDirectory(fromPanelId: panelId, snapshot: snapshot)
        let launchSnapshot = snapshot.retargetingForkWorkingDirectory(workingDirectory)
        guard panels[panelId] is TerminalPanel,
              let startupInput = forkStartupInput(
                  snapshot: launchSnapshot,
                  panelId: panelId,
                  useLocalForkVerb: true,
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  allowLauncherScript: true,
                  dialect: .loginShell
              ) else {
            return nil
        }
        let zoomedPaneId = bonsplitController.zoomedPaneId
        if zoomedPaneId != nil {
            clearSplitZoom()
        }

        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        let forkedPanel = newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: workingDirectory,
            initialInput: startupInput,
            startupRestoreAgent: launchSnapshot
        )
        if let forkedPanel {
            _ = reorderSurface(panelId: forkedPanel.id, toIndex: targetIndex)
        } else if let zoomedPaneId {
            _ = bonsplitController.togglePaneZoom(inPane: zoomedPaneId)
        }
        return forkedPanel
    }

    private static func firstNonEmptyPath(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }


}

// MARK: - BonsplitDelegate
// MARK: - PaneTreeHosting (legacy @Published observer hooks)

extension Workspace: PaneTreeHosting {
    /// Legacy `@Published panels` willSet: re-emits objectWillChange and the
    /// Combine bridge at the exact timing `@Published` used.
    func panelsWillChange(to newValue: [UUID: any Panel]) {
        surfaceCatalogPanelsWillChange(to: newValue)
        objectWillChange.send()
        panelsPublisher.send(newValue)
    }

    /// Legacy `@Published paneLayoutVersion` willSet; same contract.
    func paneLayoutVersionWillChange(to newValue: Int) {
        objectWillChange.send()
        paneLayoutVersionPublisher.send(newValue)
    }
}

extension Workspace: BonsplitDelegate {
    @MainActor
    private func shouldCloseWorkspaceOnLastSurface(for tabId: TabID, tabStripClose: Bool) -> Bool { lastSurfaceClosePreference(for: tabId).map { tabStripClose ? $0 : true } ?? false }

    private func lastSurfaceClosePreference(for tabId: TabID) -> Bool? {
        let manager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id) ?? AppDelegate.shared?.tabManager
        guard panels.count <= 1, panelIdFromSurfaceId(tabId) != nil, let manager,
              manager.tabs.contains(where: { $0.id == id }) else {
            return nil
        }
        return manager.closeWorkspaceOnLastSurfacePreferenceEnabled()
    }

    @MainActor
    private func confirmClosePanel(for tabId: TabID) async -> Bool {
        let title = String(localized: "dialog.closeTab.title", defaultValue: "Close tab?")
        let panelName: String? = {
            guard let panelId = panelIdFromSurfaceId(tabId) else { return nil }
            if let custom = panelCustomTitles[panelId], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return custom
            }
            if let title = panelTitles[panelId], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
            if let dir = panelDirectories[panelId], !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (dir as NSString).lastPathComponent
            }
            return nil
        }()

        let message: String
        if let panelName {
            message = String(localized: "dialog.closeTab.messageNamed", defaultValue: "This will close \"\(panelName)\".")
        } else {
            message = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
        }

        if let confirmCloseHandler = (
            owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: id)
            ?? AppDelegate.shared?.tabManager
        )?.confirmCloseHandler {
            return confirmCloseHandler(title, message, false)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        let content = CmuxAlertContent(informativeText: message)
        // Prefer a sheet if we can find a window, otherwise fall back to modal.
        if let window = NSApp.cmuxMainWindowForModalPresentation(),
           window.attachedSheet == nil {
            content.apply(to: alert, presentingWindow: window)
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }

        content.apply(to: alert, presentingWindow: nil)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Apply the side-effects of selecting a tab (unfocus others, focus this panel, update state).
    /// bonsplit doesn't always emit didSelectTab for programmatic selection paths (e.g. createTab).
    func applyTabSelection(
        tabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool = true,
        focusIntent: PanelFocusIntent? = nil,
        resumeHibernatedAgent: Bool? = nil,
        focusTransactionId: UUID? = nil,
        previousTerminalHostedView: GhosttySurfaceScrollView? = nil
    ) {
        let effectiveFocusTransactionId = focusTransactionId ?? activeFocusTransactionId
        pendingTabSelection = PendingTabSelectionRequest(
            tabId: tabId,
            pane: pane,
            reassertAppKitFocus: reassertAppKitFocus,
            focusIntent: focusIntent,
            resumeHibernatedAgent: resumeHibernatedAgent,
            focusTransactionId: effectiveFocusTransactionId,
            previousTerminalHostedView: previousTerminalHostedView
        )
        guard !isApplyingTabSelection else { return }
        isApplyingTabSelection = true
        defer {
            isApplyingTabSelection = false
            pendingTabSelection = nil
        }

        var iterations = 0
        while let request = pendingTabSelection {
            pendingTabSelection = nil
            iterations += 1
            if iterations > 8 { break }
            applyTabSelectionNow(
                tabId: request.tabId,
                inPane: request.pane,
                reassertAppKitFocus: request.reassertAppKitFocus,
                focusIntent: request.focusIntent,
                resumeHibernatedAgent: request.resumeHibernatedAgent,
                focusTransactionId: request.focusTransactionId,
                previousTerminalHostedView: request.previousTerminalHostedView
            )
        }
    }


    private func applyTabSelectionNow(
        tabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool,
        focusIntent: PanelFocusIntent?,
        resumeHibernatedAgent: Bool?,
        focusTransactionId: UUID?,
        previousTerminalHostedView: GhosttySurfaceScrollView?
    ) {
        let transactionId = focusTransactionId ?? UUID()
        let previousActiveFocusTransactionId = activeFocusTransactionId
        activeFocusTransactionId = transactionId
        defer {
            activeFocusTransactionId = previousActiveFocusTransactionId
        }
        let previousFocusedPanelId = focusedPanelId
        let previousPresentedDirectory = presentedCurrentDirectory
        let previousCurrentDirectory = currentDirectory
#if DEBUG
        let focusedPaneBefore = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabBefore = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "focus.split.apply.begin workspace=\(id.uuidString.prefix(5)) " +
            "pane=\(pane.id.uuidString.prefix(5)) tab=\(tabId.uuid.uuidString.prefix(5)) " +
            "focusedPane=\(focusedPaneBefore) selectedTab=\(selectedTabBefore) " +
            "reassert=\(reassertAppKitFocus ? 1 : 0)"
        )
#endif
        if bonsplitController.allPaneIds.contains(pane) {
            if bonsplitController.focusedPaneId != pane {
                bonsplitController.focusPane(pane)
            }
            if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }),
               bonsplitController.selectedTab(inPane: pane)?.id != tabId {
                bonsplitController.selectTab(tabId)
            }
        }

        let focusedPane: PaneID
        let selectedTabId: TabID
        if let currentPane = bonsplitController.focusedPaneId,
           let currentTabId = bonsplitController.selectedTab(inPane: currentPane)?.id {
            focusedPane = currentPane
            selectedTabId = currentTabId
        } else if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }) {
            focusedPane = pane
            selectedTabId = tabId
            bonsplitController.focusPane(focusedPane)
            bonsplitController.selectTab(selectedTabId)
        } else {
            return
        }

        // Focus the selected panel, but keep the previously focused terminal active while a
        // newly created split terminal is still unattached.
        guard let selectedPanelId = panelIdFromSurfaceId(selectedTabId) else {
            return
        }
        let effectiveFocusedPanelId = effectiveSelectedPanelId(inPane: focusedPane) ?? selectedPanelId
        guard let panel = panels[effectiveFocusedPanelId] else { return }
        guard let activationPanel = controlSurfaceProjection(
            forContainerPanelID: effectiveFocusedPanelId
        )?.panel else { return }

        if debugStressPreloadSelectionDepth > 0 {
            if let terminalPanel = panel as? TerminalPanel {
                terminalPanel.requestViewReattach()
                scheduleTerminalGeometryReconcile()
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            }
            return
        }

        let explicitFocusIntent = shouldTreatCurrentEventAsExplicitFocusIntent()
        if explicitFocusIntent {
            markExplicitFocusIntent(on: effectiveFocusedPanelId)
        }
        // Selecting a hibernated tab means the user is visiting it again. Resume by
        // default so sidebar/tab selection behaves the same as pressing Resume.
        let shouldResumeHibernatedAgent = resumeHibernatedAgent ?? true
        let activationIntent = focusIntent ?? activationPanel.preferredFocusIntentForActivation()
        activationPanel.prepareFocusIntentForActivation(activationIntent)
        let panelId = effectiveFocusedPanelId
        if let terminalPanel = panel as? TerminalPanel {
            if terminalPanel.isAgentHibernated, shouldResumeHibernatedAgent {
                _ = resumeAgentHibernation(panelId: panelId, focus: false)
            }
            AgentHibernationController.shared.recordTerminalFocus(workspaceId: id, panelId: panelId)
        }

        syncPinnedStateForTab(selectedTabId, panelId: selectedPanelId)
        if previousFocusedPanelId != panelId {
            syncUnreadBadgeStateForAllPanels()
        } else {
            syncUnreadBadgeStateForPanel(selectedPanelId)
        }

        // Unfocus all other panels
        for (id, p) in panels where id != effectiveFocusedPanelId {
            p.unfocus()
        }
        if activationPanel.id != panel.id { panel.unfocus() }

        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()

        if let focusWindow = activationWindow(for: activationPanel) {
            yieldForeignOwnedFocusIfNeeded(
                in: focusWindow,
                targetPanelId: activationPanel.id,
                targetIntent: activationIntent
            )
        }

        activatePanel(
            activationPanel,
            focusIntent: activationIntent,
            reassertAppKitFocus: reassertAppKitFocus,
            focusTransactionId: transactionId
        )
        if let terminalPanel = activationPanel as? TerminalPanel {
            rememberTerminalConfigInheritanceSource(terminalPanel)
        }

        // Converge AppKit first responder with bonsplit's selected tab in the focused pane.
        // Without this, keyboard input can remain on a different terminal than the blue tab indicator.
        if reassertAppKitFocus, let terminalPanel = activationPanel as? TerminalPanel {
            if shouldMoveTerminalSurfaceFocus(for: activationIntent) {
                if !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
#if DEBUG
                    let previousExists = previousTerminalHostedView != nil ? 1 : 0
                    cmuxDebugLog(
                        "focus.split.moveFocus workspace=\(id.uuidString.prefix(5)) " +
                        "panel=\(panelId.uuidString.prefix(5)) previousExists=\(previousExists) " +
                        "to=\(activationPanel.id.uuidString.prefix(5))"
                    )
#endif
                    terminalPanel.hostedView.moveFocus(
                        from: previousTerminalHostedView,
                        respectForeignFirstResponder: true,
                        focusTransactionId: transactionId
                    )
                }
#if DEBUG
                cmuxDebugLog(
                    "focus.split.ensureFocus workspace=\(id.uuidString.prefix(5)) " +
                    "panel=\(activationPanel.id.uuidString.prefix(5)) pane=\(focusedPane.id.uuidString.prefix(5)) " +
                    "tab=\(selectedTabId.uuid.uuidString.prefix(5)) intent=\(String(describing: activationIntent))"
                )
#endif
                terminalPanel.hostedView.ensureFocus(
                    for: id,
                    surfaceId: activationPanel.id,
                    focusTransactionId: transactionId
                )
            }
        }

        if shouldRestoreFocusIntentAfterActivation(activationIntent) {
            _ = activationPanel.restoreFocusIntent(activationIntent)
        }

        surfaceTabBarDirectory = configTrackingDirectory(for: panelId)

        // Update current directory if this is a terminal
        if let dir = panelDirectories[panelId] {
            currentDirectory = dir
        }
        if usesRemoteDirectoryProvenance, previousCurrentDirectory == currentDirectory {
            notifyPresentedCurrentDirectoryChanged(from: previousPresentedDirectory)
        }
        gitBranch = panelGitBranches[panelId]

        // Broadcast the focus change. This is deferred + coalesced (not posted
        // synchronously) so the `@Published` mutations above settle before any
        // observer runs, and so a notification-driven focus cycle (command-palette
        // restore + cross-workspace handoff) cannot synchronously re-enter
        // applyTabSelectionNow and hang the main thread. See issue #8843.
        FocusSurfaceBroadcaster.shared.emit(
            FocusSurfaceBroadcaster.FocusSurfacePayload(
                workspaceId: self.id,
                panelId: panelId,
                explicitFocusIntent: explicitFocusIntent,
                transactionId: transactionId
            )
        )
        publishCmuxFocusedSelection(paneId: focusedPane, surfaceId: panelId, origin: "bonsplit_selection")
#if DEBUG
        let prevPanelShort = previousFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "focus.split.apply.end workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) type=\(String(describing: type(of: panel))) " +
            "focusedPane=\(focusedPane.id.uuidString.prefix(5)) selectedTab=\(selectedTabId.uuid.uuidString.prefix(5)) " +
            "prevPanel=\(prevPanelShort)"
        )
#endif
    }

    private func activatePanel(
        _ panel: any Panel,
        focusIntent: PanelFocusIntent,
        reassertAppKitFocus: Bool,
        focusTransactionId: UUID? = nil
    ) {
        if let terminalPanel = panel as? TerminalPanel {
            let shouldFocusTerminalSurface = shouldMoveTerminalSurfaceFocus(for: focusIntent)
            terminalPanel.surface.setFocus(shouldFocusTerminalSurface)
            terminalPanel.hostedView.setActive(true)
            if reassertAppKitFocus && shouldFocusTerminalSurface {
                terminalPanel.focus(focusTransactionId: focusTransactionId)
            }
            return
        }

        if reassertAppKitFocus {
            panel.focus()
        }
    }

    private func activationWindow(for panel: any Panel) -> NSWindow? {
        if let terminalPanel = panel as? TerminalPanel {
            return terminalPanel.surface.uiWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func yieldForeignOwnedFocusIfNeeded(
        in window: NSWindow,
        targetPanelId: UUID,
        targetIntent: PanelFocusIntent
    ) {
        guard let firstResponder = window.firstResponder else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            guard let ownedIntent = panel.ownedFocusIntent(for: firstResponder, in: window) else { continue }
#if DEBUG
            cmuxDebugLog(
                "focus.handoff.begin workspace=\(id.uuidString.prefix(5)) " +
                "fromPanel=\(panelId.uuidString.prefix(5)) toPanel=\(targetPanelId.uuidString.prefix(5)) " +
                "fromIntent=\(String(describing: ownedIntent)) toIntent=\(String(describing: targetIntent))"
            )
#endif
            _ = panel.yieldFocusIntent(ownedIntent, in: window)
            return
        }
    }

    private func shouldMoveTerminalSurfaceFocus(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .terminal(.findField), .terminal(.textBoxInput):
            return false
        default:
            return true
        }
    }

    private func shouldRestoreFocusIntentAfterActivation(_ intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .terminal(.findField), .terminal(.textBoxInput):
            return true
        case .panel, .terminal(.surface), .filePreview, .project:
            return false
        }
    }

    private func beginNonFocusSplitFocusReassert(
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> UInt64 {
        nonFocusSplitFocusReassertGeneration &+= 1
        let generation = nonFocusSplitFocusReassertGeneration
        pendingNonFocusSplitFocusReassert = PendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )
        return generation
    }

    private func matchesPendingNonFocusSplitFocusReassert(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> Bool {
        guard let pending = pendingNonFocusSplitFocusReassert else { return false }
        return pending.generation == generation &&
            pending.preferredPanelId == preferredPanelId &&
            pending.splitPanelId == splitPanelId
    }

    private func clearNonFocusSplitFocusReassert(generation: UInt64? = nil) {
        guard let pending = pendingNonFocusSplitFocusReassert else { return }
        if let generation, pending.generation != generation { return }
        pendingNonFocusSplitFocusReassert = nil
    }

    private func shouldTreatCurrentEventAsExplicitFocusIntent() -> Bool {
        guard let eventType = NSApp.currentEvent?.type else { return false }
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .scrollWheel,
             .gesture, .magnify, .rotate, .swipe:
            return true
        default:
            return false
        }
    }

    private func markExplicitFocusIntent(on panelId: UUID) {
        guard let pending = pendingNonFocusSplitFocusReassert,
              pending.splitPanelId == panelId else {
            return
        }
        pendingNonFocusSplitFocusReassert = nil
    }

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        func recordPostCloseState() {
            if controller.zoomedPaneId == pane,
               controller.selectedTab(inPane: pane)?.id == tab.id {
                postCloseClearSplitZoomTabIds.insert(tab.id)
            } else {
                postCloseClearSplitZoomTabIds.remove(tab.id)
            }

            let tabs = controller.tabs(inPane: pane)
            guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
                return
            }

            let target: TabID? = {
                if idx + 1 < tabs.count { return tabs[idx + 1].id }
                if idx > 0 { return tabs[idx - 1].id }
                return nil
            }()

            if let target {
                postCloseSelectTabId[tab.id] = target
            } else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
            }
        }

        let tabCloseButtonClose = tabStripCloseButtonByTabId.removeValue(forKey: tab.id)
        let tabStripClose = tabCloseButtonClose != nil
        let explicitUserClose = explicitUserCloseTabIds.remove(tab.id) != nil || tabStripClose

        if forceCloseTabIds.contains(tab.id) {
            _ = pushClosedPanelHistoryIfEligible(for: tab, inPane: pane)
            recordPostCloseState()
            return true
        }

        let closeConfirmationManager = owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: id)
            ?? AppDelegate.shared?.tabManager
        if let closeConfirmationManager, closeConfirmationManager.isCloseConfirmationInFlight {
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }
            clearCloseHistoryEligibility(tabId: tab.id)
            return false
        }

        if let panelId = panelIdFromSurfaceId(tab.id),
           pinnedPanelIds.contains(panelId) {
            clearCloseHistoryEligibility(tabId: tab.id, panelId: panelId)
            NSSound.beep()
            return false
        }

        if explicitUserClose && shouldCloseWorkspaceOnLastSurface(for: tab.id, tabStripClose: tabStripClose) {
            clearCloseHistoryEligibility(tabId: tab.id)
            if tabCloseButtonClose == true {
                owningTabManager?.closeWorkspaceFromTabCloseButton(self)
            } else {
                owningTabManager?.closeWorkspaceFromCloseTabGesture(self)
            }
            return false
        }

        // Check if the panel needs close confirmation
        guard let panelId = panelIdFromSurfaceId(tab.id) else {
            recordPostCloseState()
            return true
        }

        // If confirmation is required, Bonsplit will call into this delegate and we must return false.
        // Show an app-level confirmation, then re-attempt the close with forceCloseTabIds to bypass
        // this gating on the second pass.
        let confirmationSource: CloseTabCloseSource = tabCloseButtonClose == true ? .tabCloseButton : .shortcut
        if CloseTabWarningStore(defaults: closeTabWarningDefaults).shouldConfirmClose(
            requiresConfirmation: panelNeedsConfirmClose(panelId: panelId),
            source: confirmationSource
        ) {
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }

            let confirmationManager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id) ?? AppDelegate.shared?.tabManager
            if let confirmationManager, !confirmationManager.beginCloseConfirmationSession() {
                return false
            }

            pendingCloseConfirmTabIds.insert(tab.id)
            let tabId = tab.id
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    confirmationManager?.endCloseConfirmationSession()
                    return
                }
                Task { @MainActor in
                    defer {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        confirmationManager?.endCloseConfirmationSession()
                    }

                    // If the tab disappeared while we were scheduling, do nothing.
                    guard self.panelIdFromSurfaceId(tabId) != nil else { return }

                    let confirmed = await self.confirmClosePanel(for: tabId)
                    guard confirmed else {
                        self.clearCloseHistoryEligibility(tabId: tabId)
                        return
                    }

                    self.forceCloseTabIds.insert(tabId)
                    self.bonsplitController.closeTab(tabId)
                }
            }

            return false
        }

        _ = pushClosedPanelHistoryIfEligible(for: tab, inPane: pane)
        recordPostCloseState()
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        forceCloseTabIds.remove(tabId)
        tabStripCloseButtonByTabId.removeValue(forKey: tabId)
        let selectTabId = postCloseSelectTabId.removeValue(forKey: tabId)
        let shouldClearSplitZoom = postCloseClearSplitZoomTabIds.remove(tabId) != nil
        let isDetaching = splitLayout.consumeDetachingMark(tabId)
        if shouldClearSplitZoom {
            clearSplitZoom()
        }

        // Clean up our panel
        guard let panelId = panelIdFromSurfaceId(tabId) else {
            #if DEBUG
            NSLog("[Workspace] didCloseTab: no panelId for tabId")
            #endif
            scheduleTerminalGeometryReconcile()
            if !isDetaching {
                scheduleFocusReconcile()
            }
            return
        }

        #if DEBUG
        NSLog("[Workspace] didCloseTab panelId=\(panelId) remainingPanels=\(panels.count - 1) remainingPanes=\(controller.allPaneIds.count)")
        #endif

        let panel = panels[panelId]
        _ = consumeCloseHistoryEligibility(tabId: tabId, panelId: panelId)
        let preservesSurfaceForDetach = isDetaching && panel != nil
        if isDetaching, let panel {
            owningTabManager?.flushPendingPanelTitleUpdatesForWorkspaceSnapshot()
            let cachedTitle = panelTitles[panelId]
            let transferFallbackTitle = cachedTitle ?? panel.displayTitle
            let restorableAgent = restoredAgentSnapshotsByPanelId[panelId]
            let restorableAgentResumeState = restoredAgentResumeStatesByPanelId[panelId]
            let resumeBinding = effectiveSurfaceResumeBinding(
                panelId: panelId,
                surfaceResumeBindingIndex: nil
            )
            let agentRuntime = agentRuntimeState(forPanelId: panelId)
            let panelDirectory = panelDirectories[panelId]
            splitLayout.storeDetachedTransfer(DetachedSurfaceTransfer(
                sourceWorkspaceId: id,
                sessionRestoreSourceWorkspaceId: id,
                panelId: panelId,
                panel: panel,
                title: resolvedPanelTitle(panelId: panelId, fallback: transferFallbackTitle),
                icon: panel.displayIcon,
                iconImageData: nil,
                kind: surfaceKind(for: panel),
                isLoading: false,
                isPinned: pinnedPanelIds.contains(panelId),
                directory: panelDirectory,
                directoryDisplayLabel: panelDirectoryDisplayLabels[panelId],
                ttyName: surfaceTTYNames[panelId],
                ttyNameWasReportedByCurrentRuntime: surfaceRegistry.runtimeReportedTTYSurfaceIDs.contains(panelId),
                ttyReportRuntimeSurfaceGeneration:
                    surfaceRegistry.runtimeReportedTTYSurfaceGenerations[panelId],
                cachedTitle: cachedTitle,
                customTitle: panelCustomTitles[panelId],
                customTitleSource: panelCustomTitles[panelId] != nil
                    ? (panelCustomTitleSources[panelId] ?? .user)
                    : nil,
                manuallyUnread: manualUnreadPanelIds.contains(panelId),
                restoredUnreadIndicator: restoredUnreadPanelIndicators[panelId],
                restorableAgent: restorableAgent,
                restorableAgentResumeState: restorableAgentResumeState,
                restoredAgentCompletedGeneration: restoredAgentLifecycle.completedGeneration(panelId: panelId),
                shellActivityState: panelShellActivityStates[panelId],
                restoredPanelTitleBoundary: restoredPanelTitleBoundariesByPanelId[panelId],
                restoredResumeSessionWorkingDirectory: restoredResumeSessionWorkingDirectoriesByPanelId[panelId],
                restoredStartupInput: restoredAgentLifecycle.startupInput(panelId: panelId),
                resumeBinding: resumeBinding,
                deferredAgentResumeRestore: deferredAgentResumeRestoresByPanelId.removeValue(
                    forKey: panelId
                ),
                managedAgentResumeBinding: resumeBinding.flatMap {
                    $0.hasCompleteManagedSessionIdentity ? $0 : nil
                },
                agentRuntime: agentRuntime
            ), for: tabId)
        }

        discardClosedPanelLifecycleState(
            panelId: panelId,
            tabId: tabId,
            paneId: pane,
            panel: panel,
            origin: "tab_close",
            closePanel: !isDetaching,
            publishSurfaceClosedEvent: !isDetaching,
            clearSurfaceNotifications: !preservesSurfaceForDetach,
            discardAgentHibernationTracking: !isDetaching,
            cleanupControllerSurfaceState: !isDetaching,
            preservesTerminalForTransfer: isDetaching
        )
        if !isDetaching {
            owningTabManager?.invalidateFocusHistoryTarget(workspaceId: id, panelId: panelId)
        }
        recomputeListeningPorts()

        if panels.isEmpty {
            if isDetaching {
                scheduleTerminalGeometryReconcile()
                return
            }

            let replacement = createReplacementTerminalPanel()
            if let replacement,
               let replacementTabId = surfaceIdFromPanelId(replacement.id),
               let replacementPane = bonsplitController.allPaneIds.first {
                bonsplitController.focusPane(replacementPane)
                bonsplitController.selectTab(replacementTabId)
                applyTabSelection(tabId: replacementTabId, inPane: replacementPane)
            }
            scheduleTerminalGeometryReconcile()
            scheduleFocusReconcile()
            return
        }

        if let selectTabId,
           bonsplitController.allPaneIds.contains(pane),
           bonsplitController.tabs(inPane: pane).contains(where: { $0.id == selectTabId }),
           bonsplitController.focusedPaneId == pane {
            bonsplitController.selectTab(selectTabId)
            applyTabSelection(tabId: selectTabId, inPane: pane)
        } else if let focusedPane = bonsplitController.focusedPaneId,
                  let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
            applyTabSelection(tabId: focusedTabId, inPane: focusedPane)
        }

        if bonsplitController.allPaneIds.contains(pane) {
            normalizePinnedTabs(in: pane)
        }
        scheduleTerminalGeometryReconcile()
        if !isDetaching {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard !preservesFocusDuringMovingTabSplit else { return }
        applyTabSelection(tabId: tab.id, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool {
        guard !isRetiredFromOwningTabManager else { return false }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {
#if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let sincePrev: String
        if debugLastDidMoveTabTimestamp > 0 {
            sincePrev = String(format: "%.2f", (now - debugLastDidMoveTabTimestamp) * 1000)
        } else {
            sincePrev = "first"
        }
        debugLastDidMoveTabTimestamp = now
        debugDidMoveTabEventCount += 1
        let movedPanelId = panelIdFromSurfaceId(tab.id)
        let movedPanel = movedPanelId?.uuidString.prefix(5) ?? "unknown"
        let selectedBefore = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneBefore = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        cmuxDebugLog(
            "split.moveTab idx=\(debugDidMoveTabEventCount) dtSincePrevMs=\(sincePrev) panel=\(movedPanel) " +
            "from=\(source.id.uuidString.prefix(5)) to=\(destination.id.uuidString.prefix(5)) " +
            "sourceTabs=\(controller.tabs(inPane: source).count) destTabs=\(controller.tabs(inPane: destination).count)"
        )
        cmuxDebugLog(
            "split.moveTab.state.before idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedBefore) focusedPane=\(focusedPaneBefore) focusedPanel=\(focusedPanelBefore)"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: destination)
#if DEBUG
        let movedPanelIdAfter = panelIdFromSurfaceId(tab.id)
#endif
        if let movedPanelId = panelIdFromSurfaceId(tab.id) {
            scheduleMovedTerminalRefresh(panelId: movedPanelId)
        }
#if DEBUG
        let selectedAfter = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneAfter = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        let movedPanelFocused = (movedPanelIdAfter != nil && movedPanelIdAfter == focusedPanelId) ? 1 : 0
        cmuxDebugLog(
            "split.moveTab.state.after idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedAfter) focusedPane=\(focusedPaneAfter) focusedPanel=\(focusedPanelAfter) " +
            "movedFocused=\(movedPanelFocused)"
        )
#endif
        normalizePinnedTabs(in: source)
        normalizePinnedTabs(in: destination)
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        guard !preservesFocusDuringMovingTabSplit else { return }
        // When a pane is focused, focus its selected tab's panel
        guard let tab = controller.selectedTab(inPane: pane) else { return }
#if DEBUG
        AppDelegate.shared?.focusLog.append(
            "Workspace.didFocusPane paneId=\(pane.id.uuidString) tabId=\(tab.id) focusedPane=\(controller.focusedPaneId?.id.uuidString ?? "nil")"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: pane)

        // Apply window background for terminal
        if let panelId = panelIdFromSurfaceId(tab.id),
           let terminalPanel = panels[panelId] as? TerminalPanel {
            terminalPanel.applyWindowBackgroundIfActive()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        let closedPanelIds = pendingPaneClosePanelIds.removeValue(forKey: paneId.id) ?? []
        let closedHistoryEntries = pendingPaneCloseHistoryEntries.removeValue(forKey: paneId.id) ?? []
        let shouldScheduleFocusReconcile = !isDetachingCloseTransaction

        publishCmuxPaneClosed(paneId, closedPanelIds: closedPanelIds, origin: "pane_close")
        if !closedPanelIds.isEmpty {
            if !isDetachingCloseTransaction && !suppressClosedPanelHistory {
                for entry in closedHistoryEntries {
                    ClosedItemHistoryStore.shared.push(.panel(entry))
                }
            }

            for panelId in closedPanelIds {
                let panel = panels[panelId]
                discardClosedPanelLifecycleState(
                    panelId: panelId,
                    tabId: surfaceIdFromPanelId(panelId),
                    paneId: paneId,
                    panel: panel,
                    origin: "pane_close",
                    closePanel: true,
                    publishSurfaceClosedEvent: true,
                    clearSurfaceNotifications: true,
                    discardAgentHibernationTracking: !isDetachingCloseTransaction,
                    cleanupControllerSurfaceState: !isDetachingCloseTransaction,
                    preservesTerminalForTransfer: isDetachingCloseTransaction
                )
                if !isDetachingCloseTransaction {
                    owningTabManager?.invalidateFocusHistoryTarget(workspaceId: id, panelId: panelId)
                }
            }

            recomputeListeningPorts()

            if let focusedPane = bonsplitController.focusedPaneId,
               let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
                applyTabSelection(tabId: focusedTabId, inPane: focusedPane)
            } else if shouldScheduleFocusReconcile {
                scheduleFocusReconcile()
            }
        }

        scheduleTerminalGeometryReconcile()
        if shouldScheduleFocusReconcile {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        // Check if any panel in this pane needs close confirmation
        let tabs = controller.tabs(inPane: pane)
        for tab in tabs {
            if forceCloseTabIds.contains(tab.id) { continue }
            if let panelId = panelIdFromSurfaceId(tab.id),
               CloseTabWarningStore(defaults: closeTabWarningDefaults).shouldConfirmClose(
                   requiresConfirmation: panelNeedsConfirmClose(panelId: panelId),
                   source: .shortcut
               ) {
                pendingPaneClosePanelIds.removeValue(forKey: pane.id)
                pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)
                return false
            }
        }
        let panelIds = tabs.compactMap { panelIdFromSurfaceId($0.id) }
        pendingPaneClosePanelIds[pane.id] = panelIds
        if suppressClosedPanelHistory || isDetachingCloseTransaction {
            pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)
        } else {
            let historyEntries = tabs.compactMap { tab -> ClosedPanelHistoryEntry? in
                guard let panelId = panelIdFromSurfaceId(tab.id) else { return nil }
                return closedPanelHistoryEntry(panelId: panelId, tabId: tab.id, pane: pane)
            }
            if historyEntries.isEmpty {
                pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)
            } else {
                pendingPaneCloseHistoryEntries[pane.id] = historyEntries
            }
        }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
        guard !isRetiredFromOwningTabManager else { return }
#if DEBUG
        let panelKindForTab: (TabID) -> String = { tabId in
            guard let panelId = self.panelIdFromSurfaceId(tabId),
                  let panel = self.panels[panelId] else { return "placeholder" }
            if panel is TerminalPanel { return "terminal" }
            return String(describing: type(of: panel))
        }
        let paneKindSummary: (PaneID) -> String = { paneId in
            let tabs = controller.tabs(inPane: paneId)
            guard !tabs.isEmpty else { return "-" }
            return tabs.map { tab in
                String(panelKindForTab(tab.id).prefix(1))
            }.joined(separator: ",")
        }
        let originalSelectedKind = controller.selectedTab(inPane: originalPane).map { panelKindForTab($0.id) } ?? "none"
        let newSelectedKind = controller.selectedTab(inPane: newPane).map { panelKindForTab($0.id) } ?? "none"
        cmuxDebugLog(
            "split.didSplit original=\(originalPane.id.uuidString.prefix(5)) new=\(newPane.id.uuidString.prefix(5)) " +
            "orientation=\(orientation) programmatic=\(isProgrammaticSplit ? 1 : 0) " +
            "originalTabs=\(controller.tabs(inPane: originalPane).count) newTabs=\(controller.tabs(inPane: newPane).count) " +
            "originalSelected=\(originalSelectedKind) newSelected=\(newSelectedKind) " +
            "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
        )
#endif
        // Only auto-create a terminal if the split came from bonsplit UI.
        // Programmatic splits via newTerminalSplit() set isProgrammaticSplit and handle their own panels.
        guard !isProgrammaticSplit else {
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // If the new pane already has a tab, this split moved an existing tab (drag-to-split).
        //
        // In the "drag the only tab to split edge" case, bonsplit inserts a placeholder "Empty"
        // tab in the source pane to avoid leaving it tabless. In cmux, this is undesirable:
        // it creates a pane with no real surfaces and leaves an "Empty" tab in the tab bar.
        //
        // Replace placeholder-only source panes with a real terminal surface, then drop the
        // placeholder tabs so the UI stays consistent and pane lists don't contain empties.
        if !controller.tabs(inPane: newPane).isEmpty {
            let originalTabs = controller.tabs(inPane: originalPane)
            let hasRealSurface = originalTabs.contains { panelIdFromSurfaceId($0.id) != nil }
#if DEBUG
            cmuxDebugLog(
                "split.didSplit.drag original=\(originalPane.id.uuidString.prefix(5)) " +
                "new=\(newPane.id.uuidString.prefix(5)) originalTabs=\(originalTabs.count) " +
                "newTabs=\(controller.tabs(inPane: newPane).count) hasRealSurface=\(hasRealSurface ? 1 : 0) " +
                "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
            )
#endif
            if !hasRealSurface {
                let placeholderTabs = originalTabs.filter { panelIdFromSurfaceId($0.id) == nil }
#if DEBUG
                cmuxDebugLog(
                    "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                    "action=reusePlaceholder placeholderCount=\(placeholderTabs.count)"
                )
#endif
                if let replacementTab = placeholderTabs.first {
                    // Keep the existing placeholder tab identity and replace only the panel mapping.
                    // This avoids an extra create+close tab churn that can transiently render an
                    // empty pane during drag-to-split of a single-tab pane.
                    let inheritedConfig = inheritedTerminalConfig(inPane: originalPane)

                    let replacementPanel = TerminalPanel(
                        workspaceId: id,
                        context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                        configTemplate: inheritedConfig,
                        portOrdinal: portOrdinal,
                        additionalEnvironment: startupEnvironmentMergingWorkspaceEnvironment([:])
                    )
                    configureNewTerminalPanel(replacementPanel)
                    panels[replacementPanel.id] = replacementPanel
                    panelTitles[replacementPanel.id] = replacementPanel.displayTitle
                    bindSurface(replacementTab.id, toPanelId: replacementPanel.id)

                    bonsplitController.updateTab(
                        replacementTab.id,
                        title: replacementPanel.displayTitle,
                        icon: .some(replacementPanel.displayIcon),
                        iconImageData: .some(nil),
                        kind: .some(SurfaceKind.terminal.rawValue),
                        hasCustomTitle: false,
                        isDirty: replacementPanel.isDirty,
                        showsNotificationBadge: false,
                        isLoading: false,
                        isPinned: false
                    )
                    rememberTerminalConfigInheritanceSource(replacementPanel)
                    publishCmuxSurfaceCreated(replacementPanel.id, paneId: originalPane, kind: "terminal", origin: "placeholder_repair", focused: false)

                    for extraPlaceholder in placeholderTabs.dropFirst() {
                        bonsplitController.closeTab(extraPlaceholder.id)
                    }
                } else {
#if DEBUG
                    cmuxDebugLog(
                        "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                        "fallback=createTerminalAndDropPlaceholders"
                    )
#endif
                    _ = newTerminalSurface(inPane: originalPane, focus: false)
                    for tab in controller.tabs(inPane: originalPane) {
                        if panelIdFromSurfaceId(tab.id) == nil {
                            bonsplitController.closeTab(tab.id)
                        }
                    }
                }
            }
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            // Moving a tab into a new split does not emit didMoveTab or didSelectTab.
            // Interactive moves activate the selected destination through Workspace's
            // focus owner; explicit non-focus transactions leave activation untouched.
            if !preservesFocusDuringMovingTabSplit,
               let movedTab = controller.selectedTab(inPane: newPane) {
                activateMovedTabAfterSplit(movedTab.id, inPane: newPane)
            }
            scheduleTerminalGeometryReconcile()
            return
        }

        // Mirror Cmd+D behavior: split buttons should always seed a terminal in the new pane.
        // When the focused source is not a terminal, inherit terminal config from nearby terminals
        // (or fall back to defaults) instead of leaving an empty selector pane.
        let sourceTabId = controller.selectedTab(inPane: originalPane)?.id
        let sourcePanelId = sourceTabId.flatMap { panelIdFromSurfaceId($0) }

#if DEBUG
        cmuxDebugLog(
            "split.didSplit.autoCreate pane=\(newPane.id.uuidString.prefix(5)) " +
            "fromPane=\(originalPane.id.uuidString.prefix(5)) sourcePanel=\(sourcePanelId.map { String($0.uuidString.prefix(5)) } ?? "none")"
        )
#endif

        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: sourcePanelId,
            inPane: originalPane
        )

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal,
            additionalEnvironment: startupEnvironmentMergingWorkspaceEnvironment([:])
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal.rawValue,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: newPane
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            return
        }

        bindSurface(newTabId, toPanelId: newPanel.id)
        rememberTerminalConfigInheritanceSource(newPanel)
        normalizePinnedTabs(in: newPane)
        publishCmuxSplitCreated(newPane, sourcePaneId: originalPane, orientation: orientation, surfaceId: newPanel.id, kind: "terminal", origin: "ui_split", focused: true)
#if DEBUG
        cmuxDebugLog(
            "split.didSplit.autoCreate.done pane=\(newPane.id.uuidString.prefix(5)) " +
            "panel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // `createTab` selects the new tab but does not emit didSelectTab; schedule an explicit
        // selection so our focus/unfocus logic runs after this delegate callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.bonsplitController.focusedPaneId == newPane {
                self.bonsplitController.selectTab(newTabId)
            }
            self.scheduleTerminalGeometryReconcile()
            self.scheduleFocusReconcile()
        }
    }

    private func selectedTerminalPanel(inPane pane: PaneID) -> TerminalPanel? {
        guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
              let panelId = panelIdFromSurfaceId(selectedTab.id) else {
            return nil
        }
        return terminalPanel(for: panelId)
    }

    private func executeSurfaceTabBarCommandButton(identifier: String, inPane pane: PaneID) {
        guard let executable = surfaceTabBarCommandButtons[identifier] else {
            return
        }
        let presentingWindow = selectedTerminalPanel(inPane: pane)?.surface.uiWindow
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow

        if let builtInAction = executable.builtInAction {
            switch builtInAction {
            case .newWorkspace:
                owningTabManager?.addWorkspaceIfActive()
            case .newAgentChat: performSurfaceTabBarNewAgentChatAction(presentingWindow: presentingWindow)
            case .newSimulator:
                _ = newSimulatorSurface(inPane: pane, focus: true)
            case .newTerminal, .splitRight, .splitDown:
                break
            }
            return
        }

        guard let globalConfigPath = surfaceTabBarButtonGlobalConfigPath else {
            return
        }

        let inlineWorkspaceCommand = executable.button.inlineWorkspaceSyntheticCommand
        if executable.workspaceCommand != nil || inlineWorkspaceCommand != nil {
            bonsplitController.focusPane(pane)
            if let selectedTab = bonsplitController.selectedTab(inPane: pane) {
                applyTabSelection(tabId: selectedTab.id, inPane: pane)
            }

            let paneDirectory = selectedTerminalPanel(inPane: pane).flatMap { terminal -> String? in
                for candidate in [panelDirectories[terminal.id], terminal.requestedWorkingDirectory] {
                    let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let trimmed, !trimmed.isEmpty {
                        return trimmed
                    }
                }
                return nil
            }
            let rawCwd = paneDirectory ?? currentDirectory
            let trimmedCwd = rawCwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseCwd = trimmedCwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : trimmedCwd
            guard let tabManager = owningTabManager else { return }
            let command: CmuxCommandDefinition
            let configSourcePath: String?
            if let workspaceCommand = executable.workspaceCommand {
                command = workspaceCommand.command
                configSourcePath = workspaceCommand.sourcePath
            } else if let inlineWorkspaceCommand {
                command = inlineWorkspaceCommand
                configSourcePath = executable.button.actionSourcePath ?? surfaceTabBarButtonSourcePath
            } else {
                return
            }
            _ = CmuxConfigExecutor.execute(
                command: command,
                tabManager: tabManager,
                baseCwd: baseCwd,
                configSourcePath: configSourcePath,
                globalConfigPath: globalConfigPath,
                displayTitle: executable.button.title ?? executable.button.tooltip ?? command.name,
                actionID: executable.button.id,
                icon: executable.button.icon ?? executable.button.action.defaultButtonIcon,
                iconSourcePath: executable.button.iconSourcePath,
                presentingWindow: presentingWindow
            )
            return
        }

        guard let command = executable.button.terminalCommand else { return }
        let target = executable.button.resolvedTerminalCommandTarget
        let didExecute = CmuxConfigExecutor.prepareShellInputIfAuthorized(
            command,
            confirm: executable.button.confirm ?? false,
            actionID: executable.button.id,
            target: target,
            configSourcePath: executable.terminalCommandSourcePath ?? surfaceTabBarButtonSourcePath,
            globalConfigPath: globalConfigPath,
            displayTitle: executable.button.title ?? executable.button.tooltip,
            icon: executable.button.icon ?? executable.button.action.defaultButtonIcon,
            iconSourcePath: executable.button.iconSourcePath,
            presentingWindow: presentingWindow
        ) { [weak self] shellInput in
            guard let self else { return }
            self.bonsplitController.focusPane(pane)
            switch target {
            case .currentTerminal:
                self.selectedTerminalPanel(inPane: pane)?.sendInput(shellInput)
            case .newTabInCurrentPane:
                _ = self.newTerminalSurface(
                    inPane: pane,
                    focus: true,
                    initialInput: shellInput,
                    inheritWorkingDirectoryFallback: true
                )
            }
        }
        guard didExecute else {
            return
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        switch kind {
        case "terminal":
            _ = newTerminalSurface(inPane: pane, inheritWorkingDirectoryFallback: true)
        default:
            _ = newTerminalSurface(inPane: pane, inheritWorkingDirectoryFallback: true)
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestCustomAction identifier: String, inPane pane: PaneID) {
#if DEBUG
        cmuxDebugLog(
            "split.customAction.request workspace=\(id.uuidString.prefix(5)) " +
            "pane=\(pane.id.uuidString.prefix(5)) identifier=\(identifier)"
        )
#endif
        executeSurfaceTabBarCommandButton(identifier: identifier, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        switch action {
        case .rename:
            promptRenamePanel(tabId: tab.id)
        case .clearName:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            setPanelCustomTitle(panelId: panelId, title: nil)
        case .copyIdentifiers:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            copyIdentifiersToPasteboard(surfaceId: panelId)
        case .closeToLeft:
            closeTabs(tabIdsToLeft(of: tab.id, inPane: pane))
        case .closeToRight:
            closeTabs(tabIdsToRight(of: tab.id, inPane: pane))
        case .closeOthers:
            closeTabs(tabIdsToCloseOthers(of: tab.id, inPane: pane))
        case .move:
            if let destination = bonsplitTabMoveDestinations(for: tab.id).first {
                _ = moveBonsplitTab(tab.id, toMoveDestination: destination.id)
            }
        case .moveToNewWorkspace:
            _ = AppDelegate.shared?.moveBonsplitTabToNewWorkspace(tabId: tab.id.uuid, focus: true, focusWindow: false)
        case .moveToLeftPane:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            _ = moveSurface(panelId: panelId, to: .left)
        case .moveToRightPane:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            _ = moveSurface(panelId: panelId, to: .right)
        case .newTerminalToRight:
            createTerminalToRight(of: tab.id, inPane: pane)
        case .newBrowserToRight, .reload, .toggleAudioMute, .duplicate:
            // Bonsplit (vendored) still declares these browser-tab context actions;
            // there is no browser panel any more, so they are inert.
            break
        case .togglePin:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            let shouldPin = !pinnedPanelIds.contains(panelId)
            setPanelPinned(panelId: panelId, pinned: shouldPin)
        case .markAsRead:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            markPanelRead(panelId)
        case .markAsUnread:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            markPanelUnread(panelId)
        case .toggleZoom:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            toggleSplitZoom(panelId: panelId)
        case .toggleFullWidthTab:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            toggleFullWidthTabMode(panelId: panelId)
        case .disconnectRemote:
            // No remote sessions exist in this build; the Bonsplit action is inert.
            break
        case .forkConversation,
             .forkConversationRight,
             .forkConversationLeft,
             .forkConversationTop,
             .forkConversationBottom,
             .forkConversationNewTab,
             .forkConversationNewWorkspace:
            handleForkConversationContextAction(action, for: tab, inPane: pane)
        @unknown default:
            break
        }
    }

    private func handleForkConversationContextAction(_ action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let panelId = panelIdFromSurfaceId(tab.id) else {
            NSSound.beep()
            return
        }

        let destination = action == .forkConversation
            ? AgentConversationForkDefaultSettings.current()
            : AgentConversationForkDestination(tabContextAction: action)
        Task { @MainActor in
            guard await forkAgentConversationFromContextMenu(fromPanelId: panelId, destination: destination) else {
                NSSound.beep()
                return
            }
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabMoveToDestination destinationId: String, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        _ = moveBonsplitTab(tab.id, toMoveDestination: destinationId)
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        geometryNotificationScheduler.schedule(zeroDelayPolicy: .yieldOnce) { [weak self] in
            guard let self else { return }
            self.tmuxLayoutSnapshot = snapshot
            _ = self.surfaceList.registerGeometryChange()
            let topologyChanged = self.surfaceList.lastGeometryChangeChangedMembership
            NotificationCenter.default.post(
                name: .workspacePaneGeometryDidChange,
                object: self,
                userInfo: [
                    GhosttyNotificationKey.tabId: self.id,
                    GhosttyNotificationKey.topologyChanged: topologyChanged,
                ]
            )
            self.scheduleTerminalGeometryReconcile()
        }
        if !isDetachingCloseTransaction { scheduleFocusReconcile() }
    }

    // No post-close polling refresh loop: we rely on view invariants and Ghostty's wakeups.
}
