import Foundation
import Testing

@testable import CmuxWorkspaces

@Suite("comux system open safety policy")
struct SystemOpenSafetyPolicyTests {
    private func makeFile(_ name: String, executable: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemOpenSafetyPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url
    }

    @Test("plain documents may be launched", arguments: [
        "notes.txt", "readme.md", "data.json", "photo.png", "doc.pdf", "main.swift", "table.csv",
    ])
    func documents(name: String) throws {
        #expect(SystemOpenSafetyPolicy.isSafeToLaunch(fileURL: try makeFile(name)))
    }

    @Test("anything that could run is refused", arguments: [
        "run.command", "x.sh", "x.tool", "evil.terminal", "site.webloc", "a.inetloc", "page.html",
        "img.svg", "p.py", "s.scpt", "w.workflow", "noext", "installer.pkg", "x.fileloc",
    ])
    func runnable(name: String) throws {
        #expect(!SystemOpenSafetyPolicy.isSafeToLaunch(fileURL: try makeFile(name)))
    }

    @Test("an executable file is refused whatever its extension")
    func executableBit() throws {
        #expect(!SystemOpenSafetyPolicy.isSafeToLaunch(fileURL: try makeFile("exec.txt", executable: true)))
    }

    @Test("only web and mail links open without asking")
    func schemes() throws {
        for value in ["https://example.com", "http://a.b", "mailto:x@y.z"] {
            #expect(SystemOpenSafetyPolicy.isDirectlyOpenable(try #require(URL(string: value))))
        }
        for value in ["ssh://h", "smb://h/s", "x-apple.systempreferences:a", "comux://prompt", "file:///tmp/x"] {
            #expect(!SystemOpenSafetyPolicy.isDirectlyOpenable(try #require(URL(string: value))))
        }
    }
}
