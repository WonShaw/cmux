import Darwin
import Foundation
import XCTest

/// Shared harness for socket-driven UI tests: launches the app with a unique
/// tagged debug socket and exposes V2 request helpers.
class WorkspaceSocketUITestCase: XCTestCase {
    private(set) var socketPath = ""
    private var diagnosticsPath = ""
    private var launchTag = ""
    private(set) var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-workspace-socket-\(UUID().uuidString).json"
        launchTag = "ui-tests-workspace-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
        super.tearDown()
    }

    // MARK: - Launch

    @discardableResult
    func launchApp(additionalLaunchArguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += [
            "-socketControlMode", "allowAll",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ] + additionalLaunchArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        // Debug launches require a tag outside reload.sh; provide one in UITests so CI
        // does not fail with "Application ... does not have a process ID".
        app.launchEnvironment["CMUX_TAG"] = launchTag
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
        self.app = app
        // On headless CI runners (no GUI session), XCUIApplication.launch()
        // blocks ~60s then fails with "Failed to activate application
        // (current state: Running Background)". Mark this as an expected
        // failure so the test can continue: these tests are socket-driven.
        let activationOptions = XCTExpectedFailure.Options()
        activationOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: activationOptions) {
            app.launch()
        }
        if app.state != .runningForeground {
            XCTAssertTrue(
                app.state == .runningBackground,
                "Expected app to be running for socket-driven test. state=\(app.state.rawValue)"
            )
        }
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected socket ping at \(socketPath). diagnostics=\(loadDiagnostics())"
        )
        return app
    }


    // MARK: - V2 socket helpers

    /// Sends one V2 request and returns the raw response envelope
    /// (`{"id":…,"ok":…,"result"/"error":…}`), or nil if the socket did not answer.
    func socketEnvelope(
        method: String,
        params: [String: Any],
        responseTimeout: TimeInterval = 8.0
    ) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        return ControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendJSON(request)
    }

    /// Sends one V2 request, asserts `ok == true`, and returns `result`.
    @discardableResult
    func socketResult(
        method: String,
        params: [String: Any],
        responseTimeout: TimeInterval = 8.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let envelope = try XCTUnwrap(
            socketEnvelope(method: method, params: params, responseTimeout: responseTimeout),
            "No socket response for \(method)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            envelope["ok"] as? Bool,
            true,
            "\(method) failed: \(envelope)",
            file: file,
            line: line
        )
        return envelope["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Socket plumbing (mirrors AutomationSocketUITests)

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        let ready = waitForControlSocketReady(
            pingTimeout: timeout,
            socketFileExists: {
                self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) }
            },
            pingReturnsPong: {
                for candidate in self.socketCandidates() {
                    guard FileManager.default.fileExists(atPath: candidate) else { continue }
                    if ControlSocketClient(path: candidate, responseTimeout: 1.0).sendLine("ping") == "PONG" {
                        self.socketPath = candidate
                        return true
                    }
                }
                return false
            }
        )
        if ready { return true }

        let diagnostics = loadDiagnostics()
        guard controlSocketDiagnosticsReportReady(diagnostics),
              let expectedPath = diagnostics["socketExpectedPath"],
              socketCandidates().contains(expectedPath) else {
            return false
        }
        socketPath = expectedPath
        return true
    }

    private func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
        if let expectedPath = loadDiagnostics()["socketExpectedPath"], !expectedPath.isEmpty {
            candidates.append(expectedPath)
        }
        var seen = Set<String>()
        candidates.removeAll { !seen.insert($0).inserted }
        return candidates
    }

    private func taggedSocketPath() -> String {
        let slug = launchTag
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "/tmp/cmux-debug-\(slug).sock"
    }

    private func loadDiagnostics() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var diagnostics: [String: String] = [:]
        for (key, value) in object {
            diagnostics[key] = String(describing: value)
        }
        return diagnostics
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendJSON(_ object: [String: Any]) -> [String: Any]? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8),
                  let response = sendLine(line),
                  let responseData = response.data(using: .utf8) else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var timeout = timeval(
                tv_sec: Int(responseTimeout),
                tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
            )
            withUnsafePointer(to: &timeout) { ptr in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let pathBytes = Array(path.utf8CString)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            guard pathBytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                for index in 0..<pathBytes.count {
                    raw[index] = pathBytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + pathBytes.count)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.connect(fd, sockaddrPtr, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = Array((line + "\n").utf8)
            let wrote = payload.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return true }
                return Darwin.write(fd, baseAddress, rawBuffer.count) == rawBuffer.count
            }
            guard wrote else { return nil }

            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulator = ""
            let deadline = Date().addingTimeInterval(responseTimeout)
            while Date() < deadline {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newline = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newline])
                    }
                }
            }
            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

final class WorkspaceWorkingDirectorySpawnUITests: WorkspaceSocketUITestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        super.tearDown()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testDisabledInheritanceDoesNotReachSpawnedShell() throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-issue-8741-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        temporaryDirectories.append(sourceDirectory)

        let app = try launchApp(additionalLaunchArguments: [
            "-workspaceInheritWorkingDirectory", "false",
        ])
        app.activate()

        let source = try socketResult(
            method: "workspace.create",
            params: [
                "title": "Issue 8741 source",
                "working_directory": sourceDirectory.path,
                "initial_command": #"printf 'SOURCE_CWD=%s\n' "$PWD"; sleep 60"#,
                "focus": true,
            ],
            responseTimeout: 12.0
        )
        let sourceWorkspaceID = try XCTUnwrap(source["workspace_id"] as? String)
        let sourceSurfaceID = try XCTUnwrap(source["surface_id"] as? String)
        let sourceOutput = try XCTUnwrap(
            waitForScreenLine(prefix: "SOURCE_CWD=/", surfaceID: sourceSurfaceID, timeout: 12.0),
            "Expected source shell to report its cwd"
        )
        XCTAssertEqual(sourceOutput, "SOURCE_CWD=\(sourceDirectory.path)")

        _ = try socketResult(
            method: "surface.focus",
            params: ["surface_id": sourceSurfaceID]
        )
        app.activate()
        XCTAssertTrue(
            waitForFocusedSurface(
                workspaceID: sourceWorkspaceID,
                surfaceID: sourceSurfaceID,
                timeout: 5.0
            ),
            "Expected source terminal to become the focused surface"
        )

        let target = try socketResult(
            method: "workspace.create",
            params: [
                "title": "Issue 8741 probe",
                "initial_command": #"printf 'SPAWN_CWD=%s\n' "$PWD"; sleep 60"#,
                "focus": false,
            ],
            responseTimeout: 12.0
        )
        let targetWorkspaceID = try XCTUnwrap(target["workspace_id"] as? String)
        let targetSurfaceID = try XCTUnwrap(target["surface_id"] as? String)
        let expectedDirectory = try XCTUnwrap(
            waitForRequestedWorkingDirectory(
                workspaceID: targetWorkspaceID,
                surfaceID: targetSurfaceID,
                timeout: 5.0
            ),
            "Expected workspace policy to provide a concrete Ghostty default"
        )
        let targetOutput = try XCTUnwrap(
            waitForScreenLine(prefix: "SPAWN_CWD=/", surfaceID: targetSurfaceID, timeout: 12.0),
            "Expected new workspace shell to report its spawn cwd"
        )
        let spawnedDirectory = String(targetOutput.dropFirst("SPAWN_CWD=".count))

        XCTAssertNotEqual(
            expectedDirectory,
            sourceDirectory.path,
            "Disabled workspace cwd inheritance must choose the Ghostty default"
        )
        XCTAssertEqual(
            spawnedDirectory,
            expectedDirectory,
            "The concrete Ghostty default must reach the spawned shell"
        )
    }

    private func waitForFocusedSurface(
        workspaceID: String,
        surfaceID: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if currentSurfaceMatches(workspaceID: workspaceID, surfaceID: surfaceID) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return currentSurfaceMatches(workspaceID: workspaceID, surfaceID: surfaceID)
    }

    private func currentSurfaceMatches(workspaceID: String, surfaceID: String) -> Bool {
        guard let envelope = socketEnvelope(
            method: "surface.current",
            params: [:],
            responseTimeout: 2.0
        ),
              envelope["ok"] as? Bool == true,
              let result = envelope["result"] as? [String: Any] else {
            return false
        }
        return result["workspace_id"] as? String == workspaceID
            && result["surface_id"] as? String == surfaceID
    }

    private func waitForRequestedWorkingDirectory(
        workspaceID: String,
        surfaceID: String,
        timeout: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let directory = requestedWorkingDirectory(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ) {
                return directory
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return requestedWorkingDirectory(workspaceID: workspaceID, surfaceID: surfaceID)
    }

    private func requestedWorkingDirectory(workspaceID: String, surfaceID: String) -> String? {
        guard let envelope = socketEnvelope(
            method: "surface.list",
            params: ["workspace_id": workspaceID],
            responseTimeout: 2.0
        ), envelope["ok"] as? Bool == true,
           let result = envelope["result"] as? [String: Any],
           let surfaces = result["surfaces"] as? [[String: Any]],
           let surface = surfaces.first(where: { $0["id"] as? String == surfaceID }) else {
            return nil
        }
        return surface["requested_working_directory"] as? String
    }

    private func waitForScreenLine(
        prefix: String,
        surfaceID: String,
        timeout: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let line = screenLine(prefix: prefix, surfaceID: surfaceID) {
                return line
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return screenLine(prefix: prefix, surfaceID: surfaceID)
    }

    private func screenLine(prefix: String, surfaceID: String) -> String? {
        guard let envelope = socketEnvelope(
            method: "surface.read_text",
            params: ["surface_id": surfaceID],
            responseTimeout: 2.0
        ), envelope["ok"] as? Bool == true,
           let result = envelope["result"] as? [String: Any],
           let text = result["text"] as? String else {
            return nil
        }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix(prefix) }
    }
}
