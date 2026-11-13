import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    static let agentHookAdmissionResponseTimeoutSeconds =
        AgentHookDeliveryPolicy.admissionResponseTimeoutSeconds
    static let agentHookBarrierResponseTimeoutSeconds = 20
    static let agentHookDeclaredTimeoutSeconds =
        AgentHookDeliveryPolicy.declaredTimeoutSeconds
    static let agentHookDeclaredTimeoutMilliseconds =
        AgentHookDeliveryPolicy.declaredTimeoutMilliseconds
    static let agentHookRouteSnapshotEnvironmentKey =
        AgentHookDeliveryPolicy.routeSnapshotEnvironmentKey
    private static let agentHookRouteResolutionTimeoutSeconds: TimeInterval = 0.2
    static let relayClaudeForkSessionPayloadKey = "_cmux_claude_fork_session"
    static let relayClaudeForkParentSessionIDPayloadKey = "_cmux_claude_fork_parent_session_id"
    private static let maximumAgentHookInputBytes = 1 * 1_024 * 1_024

    /// Builds a fail-open command that admits a non-decision hook to the app's
    /// ordered delivery queue. The hook process performs no downstream delivery.
    static func queuedAgentHookShellCommand(
        agent: String,
        subcommand: String,
        disableEnvironmentVariable: String,
        identityMarker: String? = nil
    ) -> String {
        let pidEnvironmentVariable = agentHookPIDEnvironmentVariable(agentName: agent)
        let executableExpression = agentHookCLIExecutableExpression(agent: agent)
        var commandParts = [
            "cmux_cli=\"\(executableExpression)\"",
            "if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "agent_pid=\"${\(pidEnvironmentVariable):-${PPID:-}}\"",
            "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(disableEnvironmentVariable)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then \(pidEnvironmentVariable)=\"$agent_pid\" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=\(agentHookAdmissionResponseTimeoutSeconds) \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" hooks enqueue \(agent) \(subcommand) 2>/dev/null || { cat >/dev/null; echo '{}'; }; else \(pidEnvironmentVariable)=\"$agent_pid\" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=\(agentHookAdmissionResponseTimeoutSeconds) \"$cmux_cli\" hooks enqueue \(agent) \(subcommand) 2>/dev/null || { cat >/dev/null; echo '{}'; }; fi; else cat >/dev/null; echo '{}'; fi",
        ]
        if let identityMarker {
            commandParts.insert(": \(identityMarker)", at: 0)
        }
        return commandParts.joined(separator: "; ")
    }

    static func agentHookCLIExecutableExpression(agent: String) -> String {
        switch agent {
        case "claude":
            return "${CMUX_CLAUDE_HOOK_CMUX_BIN:-${CMUX_BUNDLED_CLI_PATH:-}}"
        case "codex":
            return "${CMUX_CODEX_HOOK_CMUX_BIN:-${CMUX_BUNDLED_CLI_PATH:-}}"
        default:
            return "${CMUX_BUNDLED_CLI_PATH:-}"
        }
    }

    /// Captures the identity shared by queued lifecycle events and direct
    /// decision barriers.
    func agentHookOrderingEnvironment(
        agent: String,
        client: SocketClient,
        socketPassword: String? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: processEnvironment,
            kind: agent
        )
        for key in Self.queuedAgentHookDataEnvironmentKeys(agent: agent) {
            if let value = processEnvironment[key] {
                environment[key] = value
            }
        }
        let pidEnvironmentKey = Self.agentHookPIDEnvironmentVariable(agentName: agent)
        if environment[pidEnvironmentKey].flatMap(Int.init).map({ $0 > 0 }) != true,
           let inferredPID = inferredAgentPID() {
            environment[pidEnvironmentKey] = String(inferredPID)
        }
        let routeWasAlreadySnapshotted =
            environment[Self.agentHookRouteSnapshotEnvironmentKey] == "1"
        if let processID = environment[pidEnvironmentKey].flatMap(Int.init),
           let binding = admittedAgentHookRoute(
               processID: processID,
               client: client,
               socketPassword: socketPassword
           ) {
            environment["CMUX_WORKSPACE_ID"] = binding.workspaceId
            environment["CMUX_SURFACE_ID"] = binding.surfaceId
            environment[Self.agentHookRouteSnapshotEnvironmentKey] = "1"
        } else if !routeWasAlreadySnapshotted {
            environment.removeValue(forKey: Self.agentHookRouteSnapshotEnvironmentKey)
        }
        return environment
    }

    /// Resolves the live local process binding before queue admission while the
    /// hook PID still identifies the caller. This is a small, bounded control
    /// response rather than a complete `system.top` process snapshot.
    private func admittedAgentHookRoute(
        processID: Int,
        client: SocketClient,
        socketPassword: String?
    ) -> CallerTerminalBinding? {
        guard processID > 0 else { return nil }
        let routeClient = SocketClient(path: client.socketPath)
        defer { routeClient.close() }
        guard (try? routeClient.connect()) != nil,
              (try? authenticateClientIfNeeded(
                  routeClient,
                  explicitPassword: socketPassword,
                  socketPath: client.socketPath,
                  responseTimeout: Self.agentHookRouteResolutionTimeoutSeconds
              )) != nil,
              let payload = try? routeClient.sendV2(
                  method: "agent.resolve_delivery_target",
                  params: ["pid": processID],
                  responseTimeout: Self.agentHookRouteResolutionTimeoutSeconds
              ),
              payload["source"] as? String == "pid",
              let workspaceID = normalizedHandleValue(
                  payload["workspace_id"] as? String
              ),
              UUID(uuidString: workspaceID) != nil,
              let surfaceID = normalizedHandleValue(
                  payload["surface_id"] as? String
              ),
              UUID(uuidString: surfaceID) != nil else {
            return nil
        }
        return CallerTerminalBinding(
            workspaceId: workspaceID,
            surfaceId: surfaceID
        )
    }

    /// Re-homes an admitted surface snapshot at asynchronous delivery time so
    /// pane moves remain correct without consulting the original process PID.
    func admittedAgentHookRouteSnapshot(
        environment: [String: String],
        client: SocketClient
    ) -> CallerTerminalBinding? {
        guard environment[Self.agentHookRouteSnapshotEnvironmentKey] == "1",
              let surfaceID = normalizedHandleValue(
                  environment["CMUX_SURFACE_ID"]
              ),
              UUID(uuidString: surfaceID) != nil else {
            return nil
        }
        var params: [String: Any] = ["surface_id": surfaceID]
        if let workspaceID = normalizedHandleValue(
            environment["CMUX_WORKSPACE_ID"]
        ),
        UUID(uuidString: workspaceID) != nil {
            params["workspace_id"] = workspaceID
        }
        guard let payload = try? client.sendV2(
                  method: "agent.resolve_delivery_target",
                  params: params,
                  responseTimeout: 2
              ),
              payload["source"] as? String == "surface",
              let workspaceID = normalizedHandleValue(
                  payload["workspace_id"] as? String
              ),
              UUID(uuidString: workspaceID) != nil else {
            return nil
        }
        return CallerTerminalBinding(
            workspaceId: workspaceID,
            surfaceId: surfaceID
        )
    }

    /// Establishes the direct hook behind every earlier queued event in the
    /// same socket/surface lane. The app performs the bounded wait; this CLI
    /// retains its stdin and synchronous decision stdout/exit contract.
    func waitForPriorAgentHookDeliveries(
        agent: String,
        client: SocketClient,
        socketPassword: String? = nil,
        responseTimeout: TimeInterval = TimeInterval(Self.agentHookBarrierResponseTimeoutSeconds),
        deadline: Date? = nil
    ) throws {
        let environment = agentHookOrderingEnvironment(
            agent: agent,
            client: client,
            socketPassword: socketPassword
        )
        let params: [String: Any] = [
            "agent": agent,
            "environment": environment,
        ]
        _ = try client.sendV2(
            method: "agent.hook.barrier",
            params: params,
            responseTimeout: responseTimeout,
            deadline: deadline
        )
    }

    /// Sends one immutable hook event to the app-owned queue, then returns the
    /// agent's neutral response. Downstream CLI/socket work happens in the app.
    func enqueueAgentHook(
        commandArgs: [String],
        client: SocketClient,
        socketPassword: String? = nil
    ) throws {
        guard commandArgs.count == 2 else {
            throw CLIError(message: String(
                localized: "cli.hooks.enqueue.usage",
                defaultValue: "Usage: cmux hooks enqueue <agent> <subcommand>"
            ))
        }
        let agent = commandArgs[0].lowercased()
        let subcommand = commandArgs[1].lowercased()
        let deliveryPolicy = AgentHookDeliveryPolicy()
        guard deliveryPolicy.supportsQueuedDelivery(agent: agent, subcommand: subcommand) else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.hooks.enqueue.error.unsupportedHook",
                    defaultValue: "Unsupported queued hook: %@ %@"
                ),
                agent,
                subcommand
            ))
        }

        let processEnvironment = ProcessInfo.processInfo.environment
        let environment = agentHookOrderingEnvironment(
            agent: agent,
            client: client,
            socketPassword: socketPassword,
            processEnvironment: processEnvironment
        )
        let rawPayload = Self.readBoundedAgentHookInput() ?? "{}"
        let payload = compactAgentHookPayload(
            rawPayload,
            maximumBytes: AgentHookDeliveryPolicy.maximumPayloadBytes,
            maximumEncodedBytes: nil
        )
        let params: [String: Any] = [
            "agent": agent,
            "subcommand": subcommand,
            "payload": payload,
            "environment": environment,
            "socket_path": client.socketPath,
        ]
        _ = try client.sendV2(
            method: "agent.hook.enqueue",
            params: params,
            responseTimeout: TimeInterval(Self.agentHookAdmissionResponseTimeoutSeconds)
        )
        print("{}")
    }

    /// Reads only a finite admission envelope before any string materialization
    /// or JSON parsing. Hooks above 1 MiB fail open with a neutral payload: the
    /// lifecycle event is still admitted, but oversized untrusted detail is
    /// discarded instead of making the foreground hook process scale with stdin.
    private static func readBoundedAgentHookInput(
        handle: FileHandle = .standardInput
    ) -> String? {
        var data = Data()
        while data.count <= maximumAgentHookInputBytes {
            let remainingBytes = maximumAgentHookInputBytes + 1 - data.count
            let chunkSize = min(64 * 1_024, remainingBytes)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            guard !chunk.isEmpty else {
                return String(data: data, encoding: .utf8)
            }
            data.append(chunk)
        }
        return nil
    }

    private func compactAgentHookPayload(
        _ rawPayload: String,
        maximumBytes: Int,
        maximumEncodedBytes: Int?
    ) -> String {
        let compactor = AgentHookPayloadCompactor()
        guard !compactor.payloadFits(
            rawPayload,
            maximumPayloadBytes: maximumBytes,
            maximumEncodedPayloadBytes: maximumEncodedBytes
        ) else {
            return rawPayload
        }
        let parsed = parseClaudeHookInput(rawInput: rawPayload)
        var compact = parsed.object ?? [:]
        if let sessionID = parsed.sessionId {
            compact["session_id"] = sessionID
        }
        if let turnID = parsed.turnId {
            compact["turn_id"] = turnID
        }
        if let cwd = parsed.cwd {
            compact["cwd"] = cwd
        }
        if let transcriptPath = parsed.transcriptPath {
            compact["transcript_path"] = transcriptPath
        }
        if let rawObject = parsed.rawObject {
            compact.merge(
                compactClaudeBackgroundWorkEvidence(rawObject),
                uniquingKeysWith: { _, boundedValue in boundedValue }
            )
        }
        var candidates: [String] = []
        if JSONSerialization.isValidJSONObject(compact),
           let compactData = try? JSONSerialization.data(
               withJSONObject: compact,
               options: [.sortedKeys, .withoutEscapingSlashes]
           ),
           let compactPayload = String(data: compactData, encoding: .utf8) {
            candidates.append(compactPayload)
        }

        let behavioralFallback = compactAgentHookBehavioralFallback(parsed)
        if let identityData = try? JSONSerialization.data(
            withJSONObject: behavioralFallback,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
        let identityPayload = String(data: identityData, encoding: .utf8) {
            candidates.append(identityPayload)
        }
        return compactor.firstFittingPayload(
            in: candidates,
            maximumPayloadBytes: maximumBytes,
            maximumEncodedPayloadBytes: maximumEncodedBytes
        )
    }

    /// Preserves the fields that determine lifecycle behavior even when a rich
    /// payload is too large for relay transport. Values are bounded so this
    /// candidate remains below both the raw and JSON-encoded relay limits.
    private func compactAgentHookBehavioralFallback(
        _ parsed: ClaudeHookParsedInput
    ) -> [String: Any] {
        var fallback: [String: Any] = [:]
        func setBoundedString(_ key: String, value: String?, maximumLength: Int) {
            guard let value else { return }
            fallback[key] = compactQueuedAgentHookString(value, maximumLength: maximumLength)
        }
        setBoundedString("session_id", value: parsed.sessionId, maximumLength: 256)
        setBoundedString("turn_id", value: parsed.turnId, maximumLength: 256)
        setBoundedString("cwd", value: parsed.cwd, maximumLength: 512)
        setBoundedString("transcript_path", value: parsed.transcriptPath, maximumLength: 512)

        guard let rawObject = parsed.rawObject else { return fallback }
        let toolName = firstString(in: rawObject, keys: ["tool_name", "toolName"])
        setBoundedString("tool_name", value: toolName, maximumLength: 80)
        setBoundedString(
            "hook_event_name",
            value: firstString(
                in: rawObject,
                keys: ["hook_event_name", "hookEventName", "event_name", "event"]
            ),
            maximumLength: 80
        )
        setBoundedString(
            "permission_mode",
            value: firstString(
                in: rawObject,
                keys: ["permission_mode", "permissionMode"]
            ),
            maximumLength: 80
        )
        for key in ["agent_state", "turn_outcome"] {
            setBoundedString(
                key,
                value: firstString(in: rawObject, keys: [key]),
                maximumLength: 80
            )
        }
        for key in [
            "fullyIdle",
            "cmux_notification_routed",
            Self.relayClaudeForkSessionPayloadKey,
        ] {
            if let value = rawObject[key] as? Bool {
                fallback[key] = value
            }
        }
        if let forkParentSessionID = rawObject[
            Self.relayClaudeForkParentSessionIDPayloadKey
        ] as? String {
            fallback[Self.relayClaudeForkParentSessionIDPayloadKey] =
                compactQueuedAgentHookString(
                    forkParentSessionID,
                    maximumLength: 256
                )
        }
        fallback.merge(
            compactClaudeBackgroundWorkEvidence(rawObject),
            uniquingKeysWith: { _, boundedValue in boundedValue }
        )
        if let toolName,
           let compactToolInput = parsed.object?["tool_input"] as? [String: Any],
           let toolSummary = compactQueuedAgentHookToolSummary(
               toolName: toolName,
               toolInput: compactToolInput
           ) {
            fallback["tool_input"] = toolSummary
        }
        return fallback
    }

    /// Reduces Claude's potentially large background-work collections to the
    /// exact bounded shapes consumed by lifecycle replay. Missing keys remain
    /// missing for older Claude clients; present-but-idle collections stay
    /// empty, while active work keeps one representative entry.
    private func compactClaudeBackgroundWorkEvidence(
        _ rawObject: [String: Any]
    ) -> [String: Any] {
        var evidence: [String: Any] = [:]
        if let tasks = rawObject["background_tasks"] as? [[String: Any]] {
            let hasRunningTask = tasks.contains {
                $0["status"] as? String == "running"
            }
            let compactTasks: [[String: String]] = hasRunningTask
                ? [["status": "running"]]
                : []
            evidence["background_tasks"] = compactTasks
        }
        if let crons = rawObject["session_crons"] as? [Any] {
            let compactCrons: [[String: Bool]] = crons.isEmpty
                ? []
                : [["pending": true]]
            evidence["session_crons"] = compactCrons
        }
        return evidence
    }

    private func compactQueuedAgentHookToolSummary(
        toolName: String,
        toolInput: [String: Any]
    ) -> [String: Any]? {
        if toolName == "AskUserQuestion",
           let firstQuestion = (toolInput["questions"] as? [[String: Any]])?.first {
            var question: [String: Any] = [:]
            for key in ["question", "header"] {
                if let value = firstQuestion[key] as? String {
                    question[key] = compactQueuedAgentHookString(
                        value,
                        maximumLength: key == "question" ? 180 : 80
                    )
                }
            }
            if let options = firstQuestion["options"] as? [[String: Any]] {
                question["options"] = options.prefix(4).compactMap { option -> [String: String]? in
                    guard let label = option["label"] as? String else { return nil }
                    return [
                        "label": compactQueuedAgentHookString(label, maximumLength: 60),
                    ]
                }
            }
            return question.isEmpty ? nil : ["questions": [question]]
        }

        if toolName == "ExitPlanMode", let plan = toolInput["plan"] as? String {
            return [
                "plan": compactQueuedAgentHookString(plan, maximumLength: 512),
            ]
        }

        for key in ["file_path", "command", "pattern", "description", "query", "planFilePath"] {
            if let value = toolInput[key] as? String {
                return [
                    key: compactQueuedAgentHookString(value, maximumLength: 240),
                ]
            }
        }
        return nil
    }

    private func compactQueuedAgentHookString(
        _ value: String,
        maximumLength: Int
    ) -> String {
        truncate(normalizedSingleLine(value), maxLength: maximumLength)
    }

    private static func queuedAgentHookDataEnvironmentKeys(agent: String) -> [String] {
        [
            "PWD",
            "CMUX_AGENT_HOOK_STATE_DIR", "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
            "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD",
            "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_KIND",
            "CMUX_AGENT_MANAGED_SUBAGENT", "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
            "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", agentHookRouteSnapshotEnvironmentKey,
            agentHookPIDEnvironmentVariable(agentName: agent),
        ]
    }

    static func agentHookPIDEnvironmentVariable(agentName: String) -> String {
        AgentHookDeliveryPolicy().pidEnvironmentVariable(agentName: agentName)
    }

    static func agentHookCanRunQueued(agent: String, subcommand: String) -> Bool {
        AgentHookDeliveryPolicy().supportsQueuedDelivery(agent: agent, subcommand: subcommand)
    }
}
