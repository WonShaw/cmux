import Testing
@testable import CmuxControlSocket

@Suite("comux control socket allowlist")
struct ControlSocketClientPolicyTests {
    private func allowed(_ line: String) -> Bool {
        ControlSocketClientPolicy.evaluate(line) == .allow
    }

    @Test("status reporting, layout and hook plumbing stay allowed", arguments: [
        "ping",
        "report_pwd \"/tmp\" --tab=1",
        "report_git_branch main --status=dirty",
        "set_status claude Running",
        "list_workspaces",
        "auth secret",
        "right_sidebar files",
        #"{"method":"system.ping","id":1}"#,
        #"{"method":"workspace.create","params":{"cwd":"/tmp","title":"x"}}"#,
        #"{"method":"surface.split","params":{"direction":"right"}}"#,
        #"{"method":"feed.push","params":{}}"#,
        #"{"method":"notification.create_for_caller","params":{}}"#,
        #"{"method":"canvas.align","params":{"command":"left"}}"#,
        #"{"method":"agent.hook.enqueue","params":{}}"#,
        #"{"method":"vault.fork","params":{"open":false}}"#,
        #"{"method":"surface.create","params":{"type":"terminal"}}"#,
    ])
    func allowedCommands(line: String) {
        #expect(allowed(line))
    }

    @Test("typing, reading, spawning, approving and persisting are refused", arguments: [
        "send echo hi\\n",
        "SEND x",
        "send_key enter",
        "read_screen",
        "agent_hibernation on",
        "right_sidebar set custom foo",
        "unknown_command",
        #"{"method":"surface.send_text","params":{"text":"x"}}"#,
        #"{"method":"surface.read_text"}"#,
        #"{"method":"feed.permission.reply","params":{}}"#,
        #"{"method":"surface.resume.set","params":{}}"#,
        #"{"method":"automation.enable"}"#,
        #"{"method":"layout.open"}"#,
        #"{"method":"session.restore_previous"}"#,
        #"{"method":"sidebar.custom.select"}"#,
        #"{"method":"simulator.type"}"#,
        #"{"method":"workspace.create","params":{"initial_command":"x"}}"#,
        #"{"method":"workspace.create","params":{"layout":{"a":1}}}"#,
        #"{"method":"surface.split","params":{"initial_env":{"A":"b"}}}"#,
        #"{"method":"pane.create","params":{"nested":[{"initial_input":"x"}]}}"#,
        #"{"method":"surface.respawn","params":{"command":"x"}}"#,
        #"{"method":"surface.create","params":{"type":"agentSession"}}"#,
        #"{"method":"vault.fork","params":{"open":true}}"#,
        #"{"method":"  surface.send_text  "}"#,
        "{not json",
    ])
    func deniedCommands(line: String) {
        #expect(!allowed(line))
    }
}
