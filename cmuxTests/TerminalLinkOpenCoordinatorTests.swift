import AppKit
import Foundation
import Testing
import struct CmuxSettings.AppCatalogSection
import protocol CmuxWorkspaces.FileOpening

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal link open coordinator", .serialized)
struct TerminalLinkOpenCoordinatorTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "terminal-link-open-coordinator-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            true,
            forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        )
        return defaults
    }

    @Test("Embedded URL without an owning container falls back externally")
    @MainActor
    func unresolvedSourceFallsBackExternally() throws {
        let defaults = makeDefaults()
        let url = try #require(URL(string: "https://example.com/unresolved"))
        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, _ in nil },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            deferOperation: { operation in operation() }
        )

        let handled = coordinator.open(
            TerminalLinkOpenRequest(
                rawValue: url.absoluteString,
                sourceWorkspaceId: nil,
                sourcePanelId: UUID(),
                workingDirectory: nil
            )
        )

        #expect(handled)
        #expect(externallyOpened == [url])
    }

    @Test("Local file external opens honor the preferred editor, not the raw system opener")
    @MainActor
    func localFileExternalOpenHonorsPreferredEditor() throws {
        let defaults = makeDefaults()
        // The reporter's configuration from issue #10222: a preferred editor is
        // set, terminal links in the cmux browser are off, and supported-file
        // routing is off, so the file must go to exactly one external handler —
        // the preferred editor.
        defaults.set(
            "/usr/bin/true",
            forKey: AppCatalogSection().preferredEditor.userDefaultsKey
        )
        defaults.set(
            false,
            forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-preferred-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)

        var externallyOpened: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, _ in nil },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            deferOperation: { operation in operation() }
        )

        let handled = coordinator.open(
            TerminalLinkOpenRequest(
                rawValue: fileURL.path,
                sourceWorkspaceId: nil,
                sourcePanelId: UUID(),
                workingDirectory: nil
            )
        )

        #expect(handled)
        #expect(
            externallyOpened.isEmpty,
            "A local file open must be routed through the preferred-editor seam when app.preferredEditor is configured, never handed to the raw system opener (issue #10222)."
        )
    }

    @Test("Local file external opens are handed to the injected file-opening seam")
    @MainActor
    func localFileExternalOpenRoutesThroughFileOpeningSeam() throws {
        let defaults = makeDefaults()
        defaults.set(
            false,
            forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-open-seam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)

        var externallyOpened: [URL] = []
        let fileOpener = RecordingFileOpener()
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, _ in nil },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            fileOpen: fileOpener,
            deferOperation: { operation in operation() }
        )

        let handled = coordinator.open(
            TerminalLinkOpenRequest(
                rawValue: fileURL.path,
                sourceWorkspaceId: nil,
                sourcePanelId: UUID(),
                workingDirectory: nil
            )
        )

        #expect(handled)
        #expect(fileOpener.opened == [URL(fileURLWithPath: fileURL.path)])
        #expect(externallyOpened.isEmpty)
    }

    @Test("Explicit file URLs with locations keep the URL handler route")
    @MainActor
    func explicitFileURLWithLocationDoesNotUsePreferredEditor() throws {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-url-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("main.swift")
        try "print(\"hello\")\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let marker = directory.appendingPathComponent("preferred-editor-used")
        let editorScript = directory.appendingPathComponent("editor.sh")
        try #"""
        #!/bin/sh
        touch '#(marker.path)'
        """#.write(to: editorScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: editorScript.path)
        defaults.set(editorScript.path, forKey: AppCatalogSection().preferredEditor.userDefaultsKey)

        let fileOpener = RecordingFileOpener()
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, _ in nil },
            fileOpen: fileOpener,
            deferOperation: { operation in operation() }
        )
        let rawValue = URL(fileURLWithPath: fileURL.path).absoluteString + ":42"
        let expectedURL = try #require(URL(string: rawValue))

        #expect(coordinator.open(TerminalLinkOpenRequest(
            rawValue: rawValue,
            sourceWorkspaceId: nil,
            sourcePanelId: UUID(),
            workingDirectory: directory.path
        )))
        #expect(fileOpener.opened == [expectedURL])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Web URLs still open through the raw system opener with a preferred editor configured")
    @MainActor
    func webURLExternalOpenIgnoresPreferredEditor() throws {
        let defaults = makeDefaults()
        defaults.set(
            "/usr/bin/true",
            forKey: AppCatalogSection().preferredEditor.userDefaultsKey
        )

        let url = try #require(URL(string: "https://example.com/reference"))
        var externallyOpened: [URL] = []
        let fileOpener = RecordingFileOpener()
        let coordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { _, _ in nil },
            externalOpen: { openedURL in
                externallyOpened.append(openedURL)
                return true
            },
            fileOpen: fileOpener,
            deferOperation: { operation in operation() }
        )

        let handled = coordinator.open(
            TerminalLinkOpenRequest(
                rawValue: url.absoluteString,
                sourceWorkspaceId: nil,
                sourcePanelId: UUID(),
                workingDirectory: nil
            )
        )

        #expect(handled)
        #expect(externallyOpened == [url])
        #expect(fileOpener.opened.isEmpty)
    }

    private func makeHTMLFixture(pathExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-html-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("index.\(pathExtension)")
        try "<h1>hello</h1><p style=\"color:green\">rendered</p>".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        return fileURL
    }
}

/// Records URLs handed to the coordinator's file-opening seam.
@MainActor
private final class RecordingFileOpener: FileOpening {
    private(set) var opened: [URL] = []

    func open(_ url: URL) {
        opened.append(url)
    }
}
