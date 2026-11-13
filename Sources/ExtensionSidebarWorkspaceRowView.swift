import CmuxFoundation
import AppKit
import CmuxSidebarProviderKit
import SwiftUI

struct CmuxExtensionSidebarWorkspaceRowView: View, Equatable {
    let row: CmuxSidebarProviderRow
    let workspace: CmuxSidebarProviderWorkspace?
    let providerId: String
    let relativeNow: Date
    let isSelected: Bool
    let onSelect: (UUID) -> Void
    let onOpenWindow: (CmuxSidebarProviderWorkspace) -> Void
    @State private var showsInspector = false
    @State private var inspectorDraft: CmuxExtensionWorkspaceInspectorDraft?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row &&
            lhs.workspace == rhs.workspace &&
            lhs.providerId == rhs.providerId &&
            lhs.relativeNow == rhs.relativeNow &&
            lhs.isSelected == rhs.isSelected
    }

    private var isSuperCompact: Bool {
        false
    }

    private var isThin: Bool {
        false
    }

    var body: some View {
        let primarySize: CGFloat = isSuperCompact ? 10.5 : 12.5
        let secondarySize: CGFloat = isSuperCompact ? 9 : 10
        HStack(spacing: isSuperCompact ? 5 : 7) {
            VStack(alignment: .leading, spacing: isSuperCompact ? 0 : 2) {
                Text(row.title)
                    .cmuxFont(size: primarySize, weight: .regular)
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !isSuperCompact, let subtitle = rendered(row.subtitle) {
                    Text(subtitle)
                        .cmuxFont(size: secondarySize, weight: .regular)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isSuperCompact, let trailing = rendered(row.trailingText) {
                Text(trailing)
                    .cmuxFont(size: 10.5, weight: .regular)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let accessory = row.accessory, let workspace {
                Button {
                    if inspectorDraft == nil {
                        inspectorDraft = CmuxExtensionWorkspaceInspectorDraft.initial(
                            workspace: workspace
                        )
                    }
                    showsInspector = true
                } label: {
                    Image(systemName: accessory.systemImageName)
                        .cmuxFont(size: isSuperCompact ? 10 : 12, weight: .regular)
                        .frame(width: isSuperCompact ? 14 : 18, height: isSuperCompact ? 14 : 18)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.extension.inspectWorkspace", defaultValue: "Workspace tools"))
                .popover(isPresented: $showsInspector, arrowEdge: .trailing) {
                    CmuxExtensionWorkspaceInspectorView(
                        workspace: workspace,
                        draft: Binding(
                            get: {
                                inspectorDraft ?? CmuxExtensionWorkspaceInspectorDraft.initial(
                                    workspace: workspace
                                )
                            },
                            set: { inspectorDraft = $0 }
                        ),
                        onOpenWindow: { onOpenWindow(workspace) }
                    )
                    .frame(width: 460, height: 340)
                }
            }
        }
        .padding(.leading, isSuperCompact ? 14 : 28)
        .padding(.trailing, 8)
        .padding(.vertical, isSuperCompact ? 2 : (isThin ? 5 : 7))
        .frame(minHeight: isSuperCompact ? 22 : 32)
        .background {
            if isSelected {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(row.workspaceId)
        }
    }

    private func rendered(_ text: CmuxSidebarProviderText?) -> String? {
        guard let text else { return nil }
        switch text {
        case .plain(let value):
            return value
        case .localized(let localized):
            return CmuxExtensionSidebarSelection.localizedText(localized)
        case .relativeDate(let date, _):
            return CmuxExtensionRelativeTimeFormatter.string(from: date, to: relativeNow)
        }
    }
}

struct CmuxExtensionWorkspaceInspectorDraft: Equatable {
    var notes: String

    static func initial(
        workspace: CmuxSidebarProviderWorkspace
    ) -> CmuxExtensionWorkspaceInspectorDraft {
        CmuxExtensionWorkspaceInspectorDraft(notes: "")
    }
}

enum CmuxExtensionRelativeTimeFormatter {
    static func string(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return String(localized: "relativeTime.now", defaultValue: "now") }
        let minutes = seconds / 60
        if minutes < 60 { return localizedCount("relativeTime.minutes", defaultValue: "%lldm", count: minutes) }
        let hours = minutes / 60
        if hours < 24 { return localizedCount("relativeTime.hours", defaultValue: "%lldh", count: hours) }
        let days = hours / 24
        if days < 7 { return localizedCount("relativeTime.days", defaultValue: "%lldd", count: days) }
        let weeks = days / 7
        return localizedCount("relativeTime.weeks", defaultValue: "%lldw", count: weeks)
    }

    private static func localizedCount(_ key: String, defaultValue: String, count: Int) -> String {
        let format = NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .main,
            value: defaultValue,
            comment: ""
        )
        return String.localizedStringWithFormat(format, Int64(count))
    }
}

struct CmuxExtensionWorkspaceInspectorView: View {
    let workspace: CmuxSidebarProviderWorkspace
    let onOpenWindow: () -> Void
    @Binding private var draft: CmuxExtensionWorkspaceInspectorDraft

    init(
        workspace: CmuxSidebarProviderWorkspace,
        draft: Binding<CmuxExtensionWorkspaceInspectorDraft>,
        onOpenWindow: @escaping () -> Void
    ) {
        self.workspace = workspace
        self._draft = draft
        self.onOpenWindow = onOpenWindow
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(String(localized: "sidebar.extension.notesTab", defaultValue: "Notes"))
                    .cmuxFont(size: 12, weight: .medium)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onOpenWindow) {
                    Image(systemName: "macwindow")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.extension.openWindow", defaultValue: "Open window"))
            }
            .padding(10)

            Divider()

            TextEditor(text: $draft.notes)
                .cmuxFont(size: 13)
                .scrollContentBackground(.hidden)
                .padding(8)
                .accessibilityIdentifier("ExtensionSidebarNotesEditor")
        }
    }
}

struct CmuxExtensionWorkspaceInspectorWindowContentView: View {
    let workspace: CmuxSidebarProviderWorkspace
    let onOpenWindow: () -> Void
    @State private var draft: CmuxExtensionWorkspaceInspectorDraft

    init(
        workspace: CmuxSidebarProviderWorkspace,
        onOpenWindow: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.onOpenWindow = onOpenWindow
        _draft = State(initialValue: CmuxExtensionWorkspaceInspectorDraft.initial(workspace: workspace))
    }

    var body: some View {
        CmuxExtensionWorkspaceInspectorView(
            workspace: workspace,
            draft: $draft,
            onOpenWindow: onOpenWindow
        )
    }
}

@MainActor
final class CmuxExtensionSidebarInspectorWindowController {
    private static var controllers: [UUID: NSWindowController] = [:]
    private static var closeObservers: [UUID: NSObjectProtocol] = [:]

    static func show(workspace: CmuxSidebarProviderWorkspace) {
        if let controller = controllers[workspace.id] {
            controller.window?.title = workspace.title
            controller.window?.setContentSize(NSSize(width: 620, height: 440))
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let view = CmuxExtensionWorkspaceInspectorWindowContentView(workspace: workspace) {
            show(workspace: workspace)
        }
        let hostingController = NSHostingController(rootView: view.frame(width: 620, height: 440))
        let window = NSWindow(contentViewController: hostingController)
        window.title = workspace.title
        window.identifier = NSUserInterfaceItemIdentifier("cmux.extensionSidebarInspector")
        window.setContentSize(NSSize(width: 620, height: 440))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let controller = NSWindowController(window: window)
        controllers[workspace.id] = controller
        closeObservers[workspace.id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                controllers.removeValue(forKey: workspace.id)
                if let observer = closeObservers.removeValue(forKey: workspace.id) {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
