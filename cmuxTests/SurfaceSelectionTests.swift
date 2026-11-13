import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Surface selection", .serialized)
struct SurfaceSelectionTests {
    @Test func selectionValueTypesRejectInvalidPayloadStates() {
        #expect(SurfaceSelectionLineRange(start: 0, end: 1) == nil)
        #expect(SurfaceSelectionLineRange(start: 3, end: 2) == nil)
        #expect(SurfaceSelectionLineRange(start: 1, end: 1) != nil)

        let snapshot = SurfaceSelectionSnapshot.none(
            kind: .filePreview,
            filePath: "/tmp/example.swift"
        )
        #expect(!snapshot.hasSelection)
        #expect(snapshot.text.isEmpty)
        #expect(snapshot.lineRange == nil)

        let oversizedText = SurfaceSelectionSnapshot.boundedText(
            String(repeating: "x", count: SurfaceSelectionSnapshot.maximumTextBytes + 32)
        )
        #expect(oversizedText.utf8.count <= SurfaceSelectionSnapshot.maximumTextBytes)
        #expect(oversizedText.hasSuffix("…"))

        let oversizedUnicode = SurfaceSelectionSnapshot.boundedText(
            String(repeating: "😀", count: SurfaceSelectionSnapshot.maximumTextBytes / 4 + 32)
        )
        #expect(oversizedUnicode.utf8.count <= SurfaceSelectionSnapshot.maximumTextBytes)
        #expect(!oversizedUnicode.contains("\u{FFFD}"))
    }

    @Test func paneRoutingSelectsItsSurfaceAndFailsClosed() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: panelID)?.id)

        let resolved = try #require(workspace.controlRequestedSurfaceTarget(
            explicitSurfaceID: nil,
            routedPaneID: paneID
        ))
        #expect(resolved.requestedSurfaceID == panelID)
        #expect(resolved.target?.surfaceID == panelID)
        #expect(workspace.controlRequestedSurfaceTarget(
            explicitSurfaceID: nil,
            routedPaneID: UUID()
        ) == nil)
    }

    @Test func nativeSelectionMapsUTF16RangesToOneBasedSourceLines() async throws {
        let cases: [(source: String, selected: String, start: Int, end: Int)] = [
            ("alpha\nbeta\ngamma", "beta", 2, 2),
            ("alpha\r\nbeta\r\ngamma", "beta\r\ngamma", 2, 3),
            ("alpha\rbeta", "beta", 2, 2),
            ("alpha\u{0085}beta", "beta", 2, 2),
            ("alpha\u{2028}beta", "beta", 2, 2),
            ("zero\n😀 emoji\nlast\n", "😀 emoji\nlast\n", 2, 3),
        ]

        for testCase in cases {
            let textView = NSTextView(frame: .zero)
            textView.string = testCase.source
            let selectedRange = (testCase.source as NSString).range(of: testCase.selected)
            textView.setSelectedRange(selectedRange)

            let snapshot = await NativeTextSurfaceSelectionReader().read(
                textView: textView,
                kind: .filePreview,
                filePath: "/tmp/../tmp/example.swift"
            )

            #expect(snapshot.hasSelection)
            #expect(snapshot.text == testCase.selected)
            #expect(snapshot.filePath == "/tmp/example.swift")
            #expect(snapshot.lineRange?.start == testCase.start)
            #expect(snapshot.lineRange?.end == testCase.end)
        }
    }

    @Test func nativePanelsExposeTheSameSelectionShape() async throws {
        let source = "first\nselected 😀 text\nlast"
        let selectedRange = (source as NSString).range(of: "selected 😀 text")

        let fileTextView = NSTextView(frame: .zero)
        fileTextView.string = source
        fileTextView.setSelectedRange(selectedRange)
        let filePanel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: "/tmp/example.swift",
            startFileWatcher: false
        )
        filePanel.textView = fileTextView
        defer { filePanel.close() }

        let fileSnapshot = try snapshot(from: await filePanel.readSurfaceSelection())
        #expect(fileSnapshot.kind == .filePreview)
        #expect(fileSnapshot.text == "selected 😀 text")
        #expect(fileSnapshot.filePath == "/tmp/example.swift")
        #expect(fileSnapshot.lineRange == SurfaceSelectionLineRange(start: 2, end: 2))

        let markdownTextView = NSTextView(frame: .zero)
        markdownTextView.string = source
        markdownTextView.setSelectedRange(selectedRange)
        let markdownPanel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: "/tmp/example.md"
        )
        markdownPanel.setDisplayMode(.text)
        markdownPanel.attachTextView(markdownTextView)
        defer { markdownPanel.close() }

        let markdownSnapshot = try snapshot(from: await markdownPanel.readSurfaceSelection())
        #expect(markdownSnapshot.kind == .markdown)
        #expect(markdownSnapshot.text == "selected 😀 text")
        #expect(markdownSnapshot.filePath == "/tmp/example.md")
        #expect(markdownSnapshot.lineRange == SurfaceSelectionLineRange(start: 2, end: 2))
    }

    private func snapshot(
        from result: SurfaceSelectionReadResult
    ) throws -> SurfaceSelectionSnapshot {
        guard case .snapshot(let snapshot) = result else {
            throw SurfaceSelectionTestError.expectedSnapshot
        }
        return snapshot
    }
}

private final class SurfaceSelectionFirstResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
