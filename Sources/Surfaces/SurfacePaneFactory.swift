import Bonsplit
import CmuxControlSocket
import Foundation

/// The one place that turns a ``SurfaceDestination`` into a pane. Providers call it to
/// materialize a projection; it maps the destination onto the same `surface.split` /
/// `surface.create` machinery the CLI uses, so a drop from the sidebar lands exactly where a
/// drop of a Vault session or a file would.
///
/// Focus policy (`cmux-socket-policy`): `focus: false` never activates the app, raises a
/// window, or moves selection; the pane is created quietly behind the current focus.
@MainActor
enum SurfacePaneFactory {
    enum FactoryError: Error, LocalizedError {
        case workspaceNotFound(UUID)
        case paneNotFound(String)
        case creationFailed(String)

        var errorDescription: String? {
            switch self {
            case .workspaceNotFound(let id): return "Workspace \(id.uuidString) was not found."
            case .paneNotFound(let id): return "Pane \(id) was not found."
            case .creationFailed(let detail): return "Could not create the pane: \(detail)"
            }
        }
    }

    /// A terminal pane running `initialCommand` (nil → the login shell) at the destination.
    static func makeTerminalPane(
        initialCommand: String?,
        workingDirectory: String?,
        at destination: SurfaceDestination,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        try create(typeRaw: "terminal", url: nil, initialCommand: initialCommand, workingDirectory: workingDirectory, at: destination, focus: focus)
    }

    /// Selects the workspace and focuses the pane, the way `surface.focus` does — an explicit
    /// focus-intent operation that still never activates the app.
    static func focus(panelID: UUID, in workspaceID: UUID) {
        if let app = AppDelegate.shared,
           let manager = app.tabManagerFor(tabId: workspaceID),
           let windowID = app.windowId(for: manager),
           let window = app.mainWindow(for: windowID) {
            // A sidebar-origin action is an explicit request to move keyboard
            // ownership into the opened terminal. Clear the sidebar intent
            // before the focus coordinator evaluates the terminal target.
            app.noteMainPanelKeyboardFocusIntent(
                workspaceId: workspaceID,
                panelId: panelID,
                in: window
            )
        }
        _ = TerminalController.shared.controlSurfaceFocus(routing: routing(workspaceID: workspaceID), surfaceID: panelID)
    }

    /// Closes a pane the app is replacing or discarding itself (a restored placeholder a
    /// provider replaced, the loser of an open race, the panes of a killed terminal). That
    /// end is never a layout edit on the machine, unlike a pane the person closes.
    static func close(panelID: UUID, in workspaceID: UUID) {
        SurfaceCatalog.shared.withProjectionEndReason(for: [panelID], reason: .replaced) {
            _ = TerminalController.shared.controlSurfaceClose(routing: routing(workspaceID: workspaceID), surfaceID: panelID, hasSurfaceIDParam: true)
        }
    }

    /// The pane (Bonsplit id) that hosts a panel, for re-projecting in place.
    static func paneID(ofPanel panelID: UUID, in workspaceID: UUID) -> String? {
        guard let workspace = workspace(id: workspaceID) else { return nil }
        return workspace.paneId(forPanelId: panelID)?.id.uuidString
    }

    // MARK: - internals

    private static func routing(workspaceID: UUID) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: nil,
            paneID: nil
        )
    }

    private static func workspace(id: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first { $0.id == id }
    }

    /// The surface a split is anchored on: the selected panel of the target pane.
    private static func anchorSurface(paneID: String, in workspace: Workspace) throws -> UUID {
        guard let uuid = UUID(uuidString: paneID) else { throw FactoryError.paneNotFound(paneID) }
        // Resolve the pane the way every socket command does: Bonsplit owns the PaneID
        // values, so look the UUID up among the workspace's live panes instead of
        // synthesizing one.
        guard let located = TerminalController.shared.v2LocatePane(uuid), located.workspace.id == workspace.id,
              let selected = workspace.selectedPanelForPaneDrop(in: located.paneId) else {
            throw FactoryError.paneNotFound(paneID)
        }
        return selected.panelId
    }

    private static func create(
        typeRaw: String,
        url: String?,
        initialCommand: String?,
        workingDirectory: String?,
        at destination: SurfaceDestination,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let workspaceID = destination.workspaceID
        guard let workspace = workspace(id: workspaceID) else { throw FactoryError.workspaceNotFound(workspaceID) }
        let controller = TerminalController.shared
        let routing = routing(workspaceID: workspaceID)
        // The create/split handlers honor a focus request only inside a socket command
        // whose policy allows focus (`v2FocusAllowed`); with no command active the
        // stack is empty and the request is dropped, so a Cmd+T / Cmd+D / sidebar
        // gesture would add the tab without selecting it. `focus` is the caller's
        // already-decided intent, so run the handler under a frame carrying it. A
        // frame already on the stack is a socket command's policy and still wins: a
        // command that may not move focus cannot regain it through the factory.
        // Activation stays suppressed either way (`shouldSuppressSocketCommandActivation`).
        let outerAllowsFocus = TerminalController.currentSocketCommandFocusAllowanceStack().last ?? true
        return try TerminalController.withSocketCommandPolicyStack([focus && outerAllowsFocus]) {
            switch destination {
            case .tab(_, let paneID, _):
                guard let requestedPane = UUID(uuidString: paneID) else { throw FactoryError.paneNotFound(paneID) }
                return try tab(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, requestedPane: requestedPane, focus: focus)
            case .workspace(_, .tab):
                return try tab(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, requestedPane: nil, focus: focus)
            case .split(_, let paneID, let direction):
                let anchor = try anchorSurface(paneID: paneID, in: workspace)
                return try split(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, direction: direction, anchor: anchor, focus: focus)
            case .workspace(_, .split):
                return try split(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, direction: .right, anchor: nil, focus: focus)
            }
        }
    }

    private static func tab(
        controller: TerminalController,
        routing: ControlRoutingSelectors,
        typeRaw: String,
        url: String?,
        initialCommand: String?,
        workingDirectory: String?,
        requestedPane: UUID?,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let resolution = controller.controlSurfaceCreate(
            routing: routing,
            inputs: ControlSurfaceCreateInputs(
                typeRaw: typeRaw,
                providerRaw: nil,
                rendererRaw: nil,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                tmuxStartCommand: nil,
                remoteContextRaw: nil,
                startupEnvironment: [:],
                // Bonsplit appends a new tab to the pane; no pane drop in the app honors
                // the drop index, so it is not honored here either.
                requestedPaneID: requestedPane,
                requestedFocus: focus
            )
        )
        if case .created(_, let createdWorkspaceID, _, let surfaceID, _) = resolution {
            return (createdWorkspaceID, surfaceID)
        }
        throw FactoryError.creationFailed("\(resolution)")
    }

    private static func split(
        controller: TerminalController,
        routing: ControlRoutingSelectors,
        typeRaw: String,
        url: String?,
        initialCommand: String?,
        workingDirectory: String?,
        direction: SurfaceSplitDirection,
        anchor: UUID?,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let resolution = controller.controlSurfaceSplit(
            routing: routing,
            inputs: ControlSurfaceSplitInputs(
                directionRaw: direction.rawValue,
                typeRaw: typeRaw,
                requestedSourceSurfaceID: anchor,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                tmuxStartCommand: nil,
                remoteContextRaw: nil,
                startupEnvironment: [:],
                requestedFocus: focus,
                initialDividerPosition: nil
            )
        )
        if case .created(_, let createdWorkspaceID, _, let surfaceID, _) = resolution {
            return (createdWorkspaceID, surfaceID)
        }
        throw FactoryError.creationFailed("\(resolution)")
    }
}
