import SwiftUI
import Bonsplit
import CmuxAppKitSupportUI
import CmuxSettingsUI

/// SwiftUI fallback content for canvas panes whose panel kind is not yet
/// direct-hosted (markdown, file preview, agent session, ...).
///
/// Reuses the exact split-mode panel views so behavior stays shared; the
/// known v1 caveat is that window-portal content inside these views clips by
/// resizing at the viewport edge instead of cropping.
struct CanvasHostedPanelContentView: View {
    @Bindable var presentation: CanvasHostedPanelPresentation
    let panel: any Panel
    let workspaceId: UUID
    let paneId: PaneID
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot
    let settingsRuntime: SettingsRuntime?
    let customSidebarTabManager: TabManager?
    let onRequestPanelFocus: () -> Void

    var body: some View {
        PanelContentView(
            panel: panel,
            workspaceId: workspaceId,
            paneId: paneId,
            isFocused: presentation.isFocused,
            isSelectedInPane: true,
            isVisibleInUI: isVisibleInUI,
            allowsPointerInput: presentation.allowsPointerInput,
            pointerEntryEventFilter: presentation.acceptsPointerEntryEvent,
            portalPriority: portalPriority,
            isSplit: false,
            appearance: appearance,
            windowAppearance: windowAppearance,
            customSidebarTabManager: customSidebarTabManager,
            hasUnreadNotification: false,
            terminalAgentContext: "",
            onFocus: onRequestPanelFocus,
            onRequestPanelFocus: onRequestPanelFocus,
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {}
        )
        .environment(\.settingsRuntime, settingsRuntime)
        .environment(\.workspaceAttentionColor, presentation.workspaceAttentionColor)
        // Window-portal content (webviews) floats above the pane's layer
        // border; this inset keeps the focus ring visible around it.
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}
