public import Foundation

/// The comux allowlist for commands that arrive on the control socket.
///
/// Every process started inside a terminal (shells, agent hooks, the bundled
/// `cmux` CLI, and any AI agent running there) can connect to the socket. A
/// prompt-injected agent must not be able to use comux to escape its own
/// sandbox, so the socket only accepts commands that report status, send
/// notifications, read metadata, or manage layout. Commands that would type
/// into or read other terminals, start a process or command, persist something
/// that later runs a command, answer agent permission prompts, or open things
/// outside comux are refused. Unknown commands are refused.
///
/// The policy is applied to external socket clients only; comux's own
/// in-process callers do not pass through it.
public enum ControlSocketClientPolicy {
    /// The outcome of evaluating one command line.
    public enum Decision: Equatable, Sendable {
        case allow
        /// Refused. `isV2` tells the caller which error format to answer with.
        case deny(command: String, isV2: Bool)
    }

    /// Evaluates one bare command line (after any capability or automation
    /// envelope was removed).
    public static func evaluate(_ line: String) -> Decision {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return evaluateV2(trimmed)
        }
        return evaluateV1(trimmed)
    }

    // MARK: - v1

    static let allowedV1Commands: Set<String> = [
        "ping", "auth", "help", "__internal_flags",
        "list_windows", "current_window", "focus_window", "new_window", "close_window",
        "move_workspace_to_window", "list_workspaces", "new_workspace", "new_split",
        "list_surfaces", "focus_surface", "close_workspace", "select_workspace",
        "current_workspace", "notify", "notify_surface", "notify_target",
        "notify_target_async", "list_notifications", "clear_notifications",
        "set_app_focus", "simulate_app_active",
        // Sidebar
        "sidebar_state", "reset_sidebar", "right_sidebar", "list_panes",
        "list_pane_surfaces", "focus_pane", "focus_surface_by_panel",
        "drag_surface_to_split", "new_pane", "new_surface", "close_surface",
        "reload_config", "refresh_surfaces", "surface_health",
        // Telemetry reported by shell integration and agent hooks
        "set_status", "report_meta", "report_meta_block", "clear_status", "clear_meta",
        "clear_meta_block", "list_status", "list_meta", "list_meta_blocks",
        "set_agent_pid", "set_agent_lifecycle", "workspace_loading", "clear_agent_pid",
        "log", "clear_log", "list_log", "set_progress", "clear_progress",
        "report_git_branch", "clear_git_branch", "report_ports", "clear_ports",
        "report_pwd", "report_shell_state", "report_tty", "ports_kick",
        "agent_journal_append",
    ]

    static func evaluateV1(_ line: String) -> Decision {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let command = parts.first.map { String($0).lowercased() } ?? ""
        guard allowedV1Commands.contains(command) else {
            return .deny(command: command, isV2: false)
        }
        if command == "right_sidebar" {
            // Selecting a custom sidebar runs its script.
            let arguments = parts.count > 1 ? String(parts[1]).lowercased() : ""
            let words = arguments.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.contains("custom") {
                return .deny(command: command, isV2: false)
            }
        }
        return .allow
    }

    // MARK: - v2

    static let allowedV2Methods: Set<String> = [
        // Windows and app
        "window.list", "window.current", "window.focus", "window.create", "window.close",
        "window.displays", "window.display", "app.focus_override.set", "app.simulate_active",
        // System
        "system.ping", "system.capabilities", "system.identify", "system.tree",
        "system.memory", "system.top", "auth.login", "extension.sidebar.snapshot",
        "settings.open", "caffeine.status", "caffeine.set", "events.stream",
        // Automation (read-only and switching off)
        "automation.list", "automation.show", "automation.logs", "automation.test",
        "automation.disable",
        // Vault (read-only, plus fork without opening it)
        "vault.sessions", "vault.search", "vault.checkpoints", "vault.checkpoint",
        "vault.fork",
        // Workspaces
        "workspace.list", "workspace.current", "workspace.select", "workspace.close",
        "workspace.move_to_window", "workspace.reorder", "workspace.reorder_many",
        "workspace.prompt_submit", "workspace.rename", "workspace.set_auto_title",
        "workspace.next", "workspace.previous", "workspace.last",
        "workspace.equalize_splits", "workspace.action", "workspace.env",
        "workspace.status.get", "workspace.status.set", "workspace.status.cycle",
        "workspace.create",
        // Surfaces
        "surface.list", "surface.current", "surface.focus", "surface.close",
        "surface.move", "surface.reorder", "surface.refresh", "surface.health",
        "surface.report_tty", "surface.report_pwd", "surface.report_git_branch",
        "surface.clear_git_branch", "surface.report_shell_state", "surface.ports_kick",
        "surface.clear_history", "surface.trigger_flash", "surface.drag_to_split",
        "surface.split_off", "surface.action", "tab.action",
        "surface.sync_codex_native_title", "surface.resume.get", "surface.resume.clear",
        "surface.split", "surface.create", "surface.respawn", "debug.terminals",
        // Panes
        "pane.list", "pane.focus", "pane.surfaces", "pane.resize", "pane.swap",
        "pane.break", "pane.join", "pane.last", "pane.create",
        // Layouts (opening a saved layout can start commands)
        "layout.list", "layout.get", "layout.delete", "layout.save",
        // In-app panels
        "file.open",
        // Feed (pushing and viewing, not answering)
        "feed.push", "feed.jump", "feed.list",
        // Agent hook plumbing
        "agent.hook.enqueue", "agent.hook.barrier", "agent.restore.admit",
        "agent.restore.release", "agent.resolve_delivery_target",
        "agent.hibernation.session_end",
        // Custom sidebars (validation only)
        "sidebar.custom.validate",
        // Simulator (no input, no Web Inspector protocol, no host files)
        "simulator.context", "simulator.select_device", "simulator.recover",
        "simulator.rotate", "simulator.core_animation", "simulator.memory_warning",
        "simulator.tools", "simulator.camera.mirror", "simulator.camera.status",
        "simulator.permissions.read", "simulator.ui.status", "simulator.ui.set",
        "simulator.foreground", "simulator.web_inspector.targets",
        "simulator.web_inspector.highlight", "simulator.web_inspector.release",
        "simulator.prepare_screenshot", "simulator.accessibility", "simulator.event_log",
    ]

    /// Method families whose every member only manages layout or metadata.
    static let allowedV2Prefixes: [String] = [
        "workspace.group.", "workspace.todo.", "canvas.", "project.", "notification.",
    ]

    /// Parameters that make a create, split, or respawn method run something.
    static let commandBearingKeys: Set<String> = [
        "initial_command", "initial_input", "initial_env", "startup_environment",
        "workspace_env", "tmux_start_command", "pane_start_command", "command",
        "remote_context", "layout", "environment", "env", "startup_input",
        "shell", "profile",
    ]

    /// Methods that are only allowed without ``commandBearingKeys``.
    static let commandCheckedMethods: Set<String> = [
        "workspace.create", "surface.split", "surface.create", "surface.respawn",
        "pane.create", "window.create",
    ]

    static func evaluateV2(_ line: String) -> Decision {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMethod = object["method"] as? String else {
            return .deny(command: "", isV2: true)
        }
        let method = rawMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAllowed = allowedV2Methods.contains(method)
            || allowedV2Prefixes.contains(where: { method.hasPrefix($0) })
        guard isAllowed else { return .deny(command: method, isV2: true) }
        let params = object["params"] as? [String: Any] ?? [:]

        if commandCheckedMethods.contains(method), containsCommandBearingKey(params) {
            return .deny(command: method, isV2: true)
        }
        switch method {
        case "surface.create":
            if let type = params["type"] as? String {
                let normalized = type.lowercased().filter { $0.isLetter }
                guard normalized.isEmpty || normalized == "terminal" else {
                    return .deny(command: method, isV2: true)
                }
            }
        case "vault.fork":
            // Opening the fork resumes the agent session.
            if let open = params["open"] as? Bool, open {
                return .deny(command: method, isV2: true)
            }
            if let open = params["open"] as? String, ["1", "true", "yes"].contains(open.lowercased()) {
                return .deny(command: method, isV2: true)
            }
        default:
            break
        }
        return .allow
    }

    static func containsCommandBearingKey(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if commandBearingKeys.contains(key.lowercased()), !(nested is NSNull) {
                    return true
                }
                if containsCommandBearingKey(nested) { return true }
            }
            return false
        }
        if let array = value as? [Any] {
            return array.contains(where: containsCommandBearingKey)
        }
        return false
    }
}
