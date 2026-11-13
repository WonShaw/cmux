import AppKit
@testable import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Vault pane-transfer lifecycle", .serialized)
struct VaultPaneTransferLifecycleTests {
    private typealias TargetKind = VaultPaneDropTestHarness.TargetKind
    private typealias Placement = VaultPaneDropTestHarness.Placement
    private let dropHarness = VaultPaneDropTestHarness(suiteName: "lifecycle")

    private struct DockDropCase: Sendable {
        let targetKind: TargetKind
        let placement: Placement
    }

    private nonisolated static let dockDropCases = [
        DockDropCase(targetKind: .terminal, placement: .center),
        DockDropCase(targetKind: .terminal, placement: .right),
    ]
    private nonisolated static let paneTargetKinds: [TargetKind] = [
        .terminal,
    ]

    @Test("An accepted surface pane transfer defers native completion to endedAt")
    func acceptedSurfaceTransferDefersNativeCompletionToEndedAt() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let panelID = try #require(fixture.workspace.focusedPanelId)
            let paneID = try #require(fixture.workspace.paneId(forPanelId: panelID))
            let tabID = try #require(fixture.workspace.surfaceIdFromPanelId(panelID))
            let controller = fixture.workspace.bonsplitController
            let sourceTab = try #require(
                controller.internalController
                    .paneState(for: paneID)?
                    .tabs
                    .first(where: { $0.id == tabID.uuid })
            )
            let generation = controller.internalController.beginTabDrag(
                sourceTab,
                from: paneID
            )
            let registry = fixture.appDelegate.tabDragTransferRegistry
            let registration = try #require(registry.register(TabDragTransfer(
                tab: Tab(from: sourceTab),
                sourcePaneId: paneID
            )))
            let source = TabDragSessionSource(
                generation: generation,
                transferRegistration: registration,
                transferRegistry: registry,
                controller: controller.internalController
            )
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(
                "cmux.test.surface-pane-drop.\(UUID().uuidString)"
            ))
            pasteboard.clearContents()
            #expect(registration.write(to: pasteboard))
            defer {
                source.finishDrag()
                pasteboard.clearContents()
            }
            let context = PaneDropContext(
                workspaceId: fixture.workspace.id,
                panelId: panelID,
                paneId: paneID
            )
            let router = PaneTransferDropRouter()
            router.begin(context: context)
            defer { router.clear() }
            guard case .accepted(let plan) = router.resolve(
                pasteboard: pasteboard,
                context: context,
                proposedZone: .center
            ) else {
                Issue.record("Shared pane router rejected a live surface capability")
                return
            }

            #expect(plan.source == .surface)
            #expect(registry.resolve(from: pasteboard) != nil)
            #expect(router.perform(plan, pasteboard: pasteboard))
            // Destination acceptance revokes routing, but the native source
            // remains live until AppKit invokes its `endedAt` callback.
            #expect(controller.internalController.tabDragSession != nil)
            #expect(registry.resolve(from: pasteboard) == nil)
            source.finishDrag()
            #expect(controller.internalController.tabDragSession == nil)
            withExtendedLifetime(source) {}
        }
    }

    @Test("Every repeated Vault row publishes a live capability to the shared pane registry")
    func repeatedVaultSourcesPublishSharedPaneCapabilities() throws {
        let sessionRegistry = SessionDragRegistry()
        let paneTransferRegistry = TabDragTransferRegistry()
        let dragPasteboard = NSPasteboard(name: .drag)
        dragPasteboard.clearContents()
        defer { dragPasteboard.clearContents() }

        var activeSource: SessionDragSessionSource?
        let coordinator = SessionDragCoordinator(
            startDraggingSession: { _, _, _, source in
                activeSource = source
            }
        )
        let frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        let sourceView = NSView(frame: frame)
        let sourceEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 12),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let duplicate = Self.makeEntry(sessionID: "shared-capability-duplicate")
        let entries = [
            duplicate,
            duplicate,
            Self.makeEntry(sessionID: "shared-capability-distinct"),
        ]

        for entry in entries {
            #expect(coordinator.beginSessionDrag(
                entry,
                registry: sessionRegistry,
                tabDragTransferRegistry: paneTransferRegistry,
                from: sourceView,
                event: sourceEvent,
                frame: frame,
                image: NSImage(size: frame.size)
            ))
            let source = try #require(activeSource)
            let transfer = try #require(
                paneTransferRegistry.resolve(from: dragPasteboard)
            )
            #expect(transfer.tab.id.uuid == source.dragID)
            #expect(transfer.tab.title == entry.displayTitle)
            #expect(sessionRegistry.entry(id: source.dragID) == entry)

            source.finishDrag()
            #expect(sessionRegistry.entry(id: source.dragID) == nil)
            #expect(paneTransferRegistry.resolve(from: dragPasteboard) == nil)
            activeSource = nil
        }
    }

    private static func makeEntry(sessionID: String) -> SessionEntry {
        SessionEntry(
            id: "codex:/tmp/vault-pane-transfer/\(sessionID).jsonl",
            agent: .codex,
            sessionId: sessionID,
            title: "Vault pane transfer",
            cwd: "/tmp/vault-pane-transfer",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_000),
            fileURL: nil,
            specifics: .codex(
                model: nil,
                approvalPolicy: nil,
                sandboxMode: nil,
                effort: nil
            )
        )
    }

    private final class OccludingBrowserContentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

}
