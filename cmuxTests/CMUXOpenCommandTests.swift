import Darwin
import Foundation
import XCTest

final class CMUXOpenCommandTests: XCTestCase {
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }
    }

    private final class AsyncValueBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func set(_ value: Value) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> Value {
            lock.lock()
            let value = self.value
            lock.unlock()
            return value
        }
    }

    func testSimulatorCommandForwardsAmbientWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("simroute")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = UUID().uuidString.lowercased()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            guard method == "simulator.tap" else {
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
            return Self.v2Response(id: id, ok: true, result: ["completed": true])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["simulator", "tap", "0.5", "0.5"],
            environmentOverrides: ["CMUX_WORKSPACE_ID": workspaceID]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let command = try XCTUnwrap(state.commands.first(where: {
            Self.v2Payload(from: $0)?["method"] as? String == "simulator.tap"
        }))
        let payload = try XCTUnwrap(Self.v2Payload(from: command))
        let params = try XCTUnwrap(payload["params"] as? [String: Any])
        XCTAssertEqual(payload["method"] as? String, "simulator.tap")
        XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
        XCTAssertNil(params["surface_id"])
        XCTAssertNil(params["pane_id"])
    }

    func testSimulatorCommandIgnoresStaleAmbientSurfaceWhenWorkspaceIsAvailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("simstale")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = UUID().uuidString.lowercased()
        let staleSurfaceID = UUID().uuidString.lowercased()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  payload["method"] as? String == "simulator.tap" else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(id: id, ok: true, result: ["completed": true])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["simulator", "tap", "0.5", "0.5"],
            environmentOverrides: [
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": staleSurfaceID,
            ]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let command = try XCTUnwrap(state.commands.first(where: {
            Self.v2Payload(from: $0)?["method"] as? String == "simulator.tap"
        }))
        let payload = try XCTUnwrap(Self.v2Payload(from: command))
        let params = try XCTUnwrap(payload["params"] as? [String: Any])
        XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
        XCTAssertNil(params["surface_id"])
        XCTAssertNil(params["pane_id"])
        XCTAssertNotEqual(params["surface_id"] as? String, staleSurfaceID)
    }

    func testSimulatorCommandPreservesExplicitWindowAndSurface() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("simwinsurf")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowID = UUID().uuidString.lowercased()
        let surfaceID = UUID().uuidString.lowercased()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            switch method {
            case "window.focus":
                return Self.v2Response(id: id, ok: true, result: ["focused": true])
            case "workspace.list":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspaces": [["id": "workspace-id", "ref": "workspace:1"]],
                ])
            case "surface.list":
                return Self.v2Response(id: id, ok: true, result: [
                    "surfaces": [["id": surfaceID, "ref": "surface:1", "type": "simulator"]],
                ])
            case "simulator.tap":
                return Self.v2Response(id: id, ok: true, result: ["completed": true])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: [
                "--window", windowID,
                "simulator", "tap", "0.5", "0.5", "--surface", surfaceID,
            ]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let command = try XCTUnwrap(state.commands.first(where: {
            Self.v2Payload(from: $0)?["method"] as? String == "simulator.tap"
        }))
        let payload = try XCTUnwrap(Self.v2Payload(from: command))
        let params = try XCTUnwrap(payload["params"] as? [String: Any])
        XCTAssertEqual(params["window_id"] as? String, windowID)
        XCTAssertEqual(params["surface_id"] as? String, surfaceID)
    }

    func testNumericSimulatorSurfaceIsScopedToCallerWorkspace() throws {
        try assertNumericSimulatorSelectorScopesCallerWorkspace(
            arguments: ["simulator", "tap", "0.5", "0.5", "--surface", "5"],
            expectedMethod: "simulator.tap"
        )
    }

    func testNumericIOSSurfaceIsScopedToCallerWorkspace() throws {
        try assertNumericSimulatorSelectorScopesCallerWorkspace(
            arguments: ["ios", "context", "--surface", "5"],
            expectedMethod: "simulator.context"
        )
    }

    func testIOSScreenshotPreparesTheSelectedDeviceBeforeCapture() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("iosshot")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let surfaceID = UUID().uuidString.lowercased()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String,
                  method == "simulator.context" || method == "simulator.prepare_screenshot" else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(id: id, ok: true, result: [
                "surface_ref": "surface:1",
            ])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["ios", "screenshot", "--surface", surfaceID]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(
            state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String },
            ["simulator.prepare_screenshot"]
        )
    }

    func testIOSListUsesExplicitWindowInsteadOfAmbientWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ioswin")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowID = UUID().uuidString.lowercased()
        let ambientWorkspaceID = UUID().uuidString.lowercased()
        let selectedWorkspaceID = UUID().uuidString.lowercased()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "window.focus" {
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowID)
                return Self.v2Response(id: id, ok: true, result: ["focused": true])
            }
            switch method {
            case "workspace.current":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": selectedWorkspaceID,
                ])
            case "surface.list":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": selectedWorkspaceID,
                    "surfaces": [],
                ])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected"])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["--window", windowID, "ios", "list"],
            environmentOverrides: ["CMUX_WORKSPACE_ID": ambientWorkspaceID]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let payloads = state.commands.compactMap { Self.v2Payload(from: $0) }
        let currentParams = try XCTUnwrap(payloads.first(where: {
            $0["method"] as? String == "workspace.current"
        })?["params"] as? [String: Any])
        XCTAssertEqual(currentParams["window_id"] as? String, windowID)
        let listParams = try XCTUnwrap(payloads.first(where: {
            $0["method"] as? String == "surface.list"
        })?["params"] as? [String: Any])
        XCTAssertEqual(listParams["window_id"] as? String, windowID)
        XCTAssertEqual(listParams["workspace_id"] as? String, selectedWorkspaceID)
        XCTAssertNotEqual(listParams["workspace_id"] as? String, ambientWorkspaceID)
    }

    private func assertNumericSimulatorSelectorScopesCallerWorkspace(
        arguments: [String],
        expectedMethod: String
    ) throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("simindex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = UUID().uuidString.lowercased()
        let surfaceID = UUID().uuidString.lowercased()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            switch method {
            case "surface.list":
                return Self.v2Response(id: id, ok: true, result: [
                    "surfaces": [[
                        "id": surfaceID,
                        "ref": "surface:5",
                        "index": 5,
                        "type": "simulator",
                    ]],
                ])
            case "simulator.tap":
                return Self.v2Response(id: id, ok: true, result: ["completed": true])
            case "simulator.context":
                return Self.v2Response(id: id, ok: true, result: [
                    "surface_ref": "surface:5",
                    "simulator_id": "SIMULATOR",
                    "device_name": "iPhone",
                    "state": "Booted",
                ])
            default:
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: arguments,
            environmentOverrides: ["CMUX_WORKSPACE_ID": workspaceID]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let payloads = state.commands.compactMap { Self.v2Payload(from: $0) }
        let listParams = try XCTUnwrap(payloads.first(where: {
            $0["method"] as? String == "surface.list"
        })?["params"] as? [String: Any])
        XCTAssertEqual(listParams["workspace_id"] as? String, workspaceID)
        let commandParams = try XCTUnwrap(payloads.first(where: {
            $0["method"] as? String == expectedMethod
        })?["params"] as? [String: Any])
        XCTAssertEqual(commandParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(commandParams["surface_id"] as? String, surfaceID)
    }

    func testOpenCommandHonorsTerminatorForDashPrefixedPath() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-dash")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("-notes.txt")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "dash file\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            if method == "file.open",
               let paths = params["paths"] as? [String],
               paths == [fileURL.path] {
                return Self.v2Response(id: id, ok: true, result: ["surface_id": "surface-id", "pane_id": "pane-id"])
            }
            return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", "--", fileURL.path]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK files=1 surface=surface-id pane=pane-id\n")
    }

    func testOpenCommandProcessesMixedTargetsInInputOrder() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-order")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("notes.txt")
        let directoryURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "notes\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "file.open":
                guard let paths = params["paths"] as? [String], paths == [fileURL.path] else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-file-paths"])
                }
                return Self.v2Response(id: id, ok: true, result: ["surface_id": "surface-id", "pane_id": "pane-id"])
            case "workspace.create":
                guard params["cwd"] as? String == directoryURL.path else {
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-cwd"])
                }
                return Self.v2Response(id: id, ok: true, result: ["workspace_id": "workspace-id"])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected-method", "message": method])
            }
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", fileURL.path, directoryURL.path]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK files=1 surface=surface-id pane=pane-id workspaces=1\n")
        XCTAssertEqual(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String }, ["file.open", "workspace.create"])
    }

    func testMarkdownOpenCommandUsesMarkdownOpenEndpoint() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("markdown-open")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("README.md")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "# Smoke\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            guard method == "markdown.open",
                  params["path"] as? String == fileURL.path else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: ["surface_id": "surface-id", "pane_id": "pane-id", "path": fileURL.path]
            )
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["markdown", "open", fileURL.path]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK surface=surface-id pane=pane-id path=\(fileURL.path)\n")
        XCTAssertEqual(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String }, ["markdown.open"])
    }

    func testTopCommandSortsWorkspacesByCPUDescending() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-cpu")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "workspaces": [
                        topNode(ref: "workspace:low", cpu: 1, rss: 1_000, processCount: 1),
                        topNode(ref: "workspace:high", cpu: 10, rss: 10_000, processCount: 3),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--sort", "cpu"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let lines = outputLines(result.stdout)
        XCTAssertGreaterThanOrEqual(lines.count, 4, result.stdout)
        XCTAssertTrue(lines[2].contains("workspace workspace:high"), result.stdout)
        XCTAssertTrue(lines[3].contains("workspace workspace:low"), result.stdout)
    }

    func testTopCommandForwardsWindowFlag() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let windowId = "11111111-1111-1111-1111-111111111111"
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:2", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "id": windowId,
                    "workspaces": [],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload) { params in
            XCTAssertEqual(params["window_id"] as? String, windowId)
            XCTAssertEqual(params["all_windows"] as? Bool, false)
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--window", windowId]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("window window:2"), result.stdout)
    }

    func testTopCommandSortsMixedWorkspaceChildrenByMemoryAlias() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-mem")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "workspaces": [
                        topNode(ref: "workspace:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                            "tags": [
                                topTag(key: "codex", cpu: 1, rss: 10_000, processCount: 1),
                            ],
                            "panes": [
                                topNode(ref: "pane:1", cpu: 2, rss: 50_000, processCount: 2),
                            ],
                        ]),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--sort", "mem"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let lines = outputLines(result.stdout)
        XCTAssertGreaterThanOrEqual(lines.count, 5, result.stdout)
        XCTAssertTrue(lines[3].contains("pane pane:1"), result.stdout)
        XCTAssertTrue(lines[4].contains("tag codex"), result.stdout)
    }

    func testTopCommandSortsSurfaceWebviewsAndProcessesTogetherByMemory() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-surface-mixed")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "workspaces": [
                        topNode(ref: "workspace:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                            "panes": [
                                topNode(ref: "pane:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                                    "surfaces": [
                                        topNode(ref: "surface:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                                            "webviews": [
                                                topNode(ref: "webview:1", cpu: 1, rss: 1_000, processCount: 1, extra: [
                                                    "pid": 8000,
                                                    "title": "lighter webview",
                                                ]),
                                            ],
                                            "processes": [
                                                [
                                                    "pid": 9000,
                                                    "name": "high-proc",
                                                    "resources": topResources(cpu: 3, rss: 10_000, processCount: 1),
                                                    "children": [],
                                                ] as [String: Any],
                                            ],
                                        ]),
                                    ],
                                ]),
                            ],
                        ]),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--processes", "--sort", "mem"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let lines = outputLines(result.stdout)
        let processLine = try XCTUnwrap(lines.firstIndex { $0.contains("process 9000 high-proc") })
        let webviewLine = try XCTUnwrap(lines.firstIndex { $0.contains("webview pid=8000") })
        XCTAssertLessThan(processLine, webviewLine, result.stdout)
    }

    func testTopCommandOutputsFlatTSVForShellSorting() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-tsv")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "totals": topResources(cpu: 12, rss: 12_000, processCount: 4),
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "workspaces": [
                        topNode(ref: "workspace:1", cpu: 10, rss: 10_000, processCount: 3, extra: [
                            "title": "High\tCPU\nWorkspace",
                        ]),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--flat", "--format", "tsv"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(outputLines(result.stdout), [
            "12.0\t12000\t4\ttotal\ttotal\t\t",
            "2.0\t2000\t2\twindow\twindow:1\ttotal\t",
            "10.0\t10000\t3\tworkspace\tworkspace:1\twindow:1\tHigh CPU Workspace",
        ])
    }

    func testTopCommandFormatTSVImpliesFlatOutput() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-fmt")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--format", "tsv"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(outputLines(result.stdout), [
            "2.0\t2000\t2\twindow\twindow:1\ttotal\t",
        ])
    }

    func testTopCommandOutputsWindowLevelProcessRows() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-proc")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 1, extra: [
                    "processes": [
                        [
                            "pid": 4129,
                            "name": "cmux",
                            "resources": topResources(cpu: 2, rss: 2_000, processCount: 1),
                            "children": [],
                        ] as [String: Any],
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--processes", "--format", "tsv"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(outputLines(result.stdout), [
            "2.0\t2000\t1\twindow\twindow:1\ttotal\t",
            "2.0\t2000\t1\tprocess\t4129\twindow:1\tcmux",
        ])
    }

    func testTopCommandSortsFlatTSVSiblingsByMemory() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-tsv-sort")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "workspaces": [
                        topNode(ref: "workspace:low", cpu: 1, rss: 1_000, processCount: 1),
                        topNode(ref: "workspace:high", cpu: 3, rss: 10_000, processCount: 3),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--format", "tsv", "--sort", "rss"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(outputLines(result.stdout), [
            "2.0\t2000\t2\twindow\twindow:1\ttotal\t",
            "3.0\t10000\t3\tworkspace\tworkspace:high\twindow:1\t",
            "1.0\t1000\t1\tworkspace\tworkspace:low\twindow:1\t",
        ])
    }

    func testTopCommandSortsFlatWindowProcessesAndWorkspacesTogetherByMemory() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("top-tsv-window-process-sort")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let payload: [String: Any] = [
            "windows": [
                topNode(ref: "window:1", cpu: 2, rss: 2_000, processCount: 2, extra: [
                    "processes": [
                        [
                            "pid": 4129,
                            "name": "cmux",
                            "resources": topResources(cpu: 4, rss: 10_000, processCount: 1),
                            "children": [],
                        ] as [String: Any],
                    ],
                    "workspaces": [
                        topNode(ref: "workspace:low", cpu: 1, rss: 1_000, processCount: 1),
                    ],
                ]),
            ],
        ]
        let serverHandled = startTopMockServer(listenerFD: listenerFD, payload: payload)

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["top", "--processes", "--format", "tsv", "--sort", "mem"]
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(outputLines(result.stdout), [
            "2.0\t2000\t2\twindow\twindow:1\ttotal\t",
            "4.0\t10000\t1\tprocess\t4129\twindow:1\tcmux",
            "1.0\t1000\t1\tworkspace\tworkspace:low\twindow:1\t",
        ])
    }

    func runCLI(
        cliPath: String,
        socketPath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        stdinText: String? = nil
    ) -> ProcessRunResult {
        var environment = ProcessInfo.processInfo.environment
        // CLI routing tests must not inherit the host test runner's ambient
        // workspace/surface/window/socket context. The app-host process runs
        // many suites in one process, so a previous test can otherwise make a
        // command take an implicit window-focus or surface-validation path.
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        return runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 15,
            currentDirectoryURL: currentDirectoryURL,
            stdinText: stdinText
        )
    }

    func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        currentDirectoryURL: URL? = nil,
        stdinText: String? = nil
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe: Pipe?
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        if let stdinText, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(stdinText.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(status: timedOut ? 124 : process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }

        return fd
    }

    func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli open mock socket handled")
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.fulfill()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.fulfill()
            }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    state.append(line)
                    let response = handler(line) + "\n"
                    _ = response.withCString { ptr in
                        Darwin.write(clientFD, ptr, strlen(ptr))
                    }
                }
            }
        }
        return handled
    }

    private func startTopMockServer(
        listenerFD: Int32,
        payload: [String: Any],
        assertParams: (([String: Any]) -> Void)? = nil
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: MockSocketServerState()) { line in
            guard let request = Self.v2Payload(from: line),
                  let id = request["id"] as? String,
                  request["method"] as? String == "system.top" else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            assertParams?(request["params"] as? [String: Any] ?? [:])
            return Self.v2Response(id: id, ok: true, result: payload)
        }
    }

    private func topNode(
        ref: String,
        cpu: Double,
        rss: Int,
        processCount: Int,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var result = extra
        result["ref"] = ref
        result["resources"] = topResources(cpu: cpu, rss: rss, processCount: processCount)
        return result
    }

    private func topTag(
        key: String,
        cpu: Double,
        rss: Int,
        processCount: Int
    ) -> [String: Any] {
        [
            "key": key,
            "resources": topResources(cpu: cpu, rss: rss, processCount: processCount),
        ]
    }

    private func topResources(cpu: Double, rss: Int, processCount: Int) -> [String: Any] {
        [
            "cpu_percent": cpu,
            "resident_bytes": rss,
            "process_count": processCount,
        ]
    }

    private func outputLines(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
    }

    static func v2Payload(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    static func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}
