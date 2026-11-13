import AppKit
import Bonsplit
import Foundation
import Testing
import struct CmuxSettings.AppCatalogSection

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class RecordingTerminalLinkContainer: TerminalLinkOpenContainer {
    private(set) var openedFilePaths: [String] = []

    var terminalLinkContainerDebugName: String { "recording" }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        "/tmp"
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        false
    }

    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget? {
        nil
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        openedFilePaths.append(filePath)
        return true
    }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
        false
    }
}

@Suite("Terminal link locations and Dock controls", .serialized)
struct TerminalLinkLocationAndDockTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "terminal-link-location-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey)
        return defaults
    }

    @Test("path:line Cmd-click forwards the location to the preferred editor")
    @MainActor
    func pathLocationUsesPreferredEditor() async throws {
        let defaults = makeDefaults()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("main.swift")
        try "print(\"hello\")\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let marker = root.appendingPathComponent("received.txt")
        let editorScript = root.appendingPathComponent("editor.sh")
        try #"""
        #!/bin/sh
        printf %s "$1" > '\#(marker.path)'
        """#.write(to: editorScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: editorScript.path
        )
        defaults.set(editorScript.path, forKey: "preferredEditorCommand")

        let panelID = UUID()
        let container = RecordingTerminalLinkContainer()
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, sourcePanelID in
                sourcePanelID == panelID ? container : nil
            },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            deferOperation: { operation in operation() }
        )

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: "\(fileURL.path):42:5",
            sourceWorkspaceId: nil,
            sourcePanelId: panelID,
            workingDirectory: root.path
        )))

        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let received = try String(contentsOf: marker, encoding: .utf8)
        #expect(received == "\(fileURL.path):42:5")
        #expect(container.openedFilePaths.isEmpty)
        #expect(externallyOpened.isEmpty)
    }


}
