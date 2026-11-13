import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case newAgentChat = "cmux.newAgentChat"
    case newTerminal = "cmux.newTerminal"
    case newSimulator = "cmux.newSimulator"
    case splitRight = "cmux.splitRight"
    case splitDown = "cmux.splitDown"

    init?(configID: String) {
        switch configID {
        case "cmux.newWorkspace", "newWorkspace":
            self = .newWorkspace
        case "cmux.newAgentChat", "cmux.agentChat", "newAgentChat", "new-agent-chat", "agentChat":
            self = .newAgentChat
        case "cmux.newTerminal", "newTerminal":
            self = .newTerminal
        case "cmux.newSimulator", "newSimulator", "new-simulator", "simulator":
            self = .newSimulator
        case "cmux.splitRight", "splitRight":
            self = .splitRight
        case "cmux.splitDown", "splitDown":
            self = .splitDown
        default:
            return nil
        }
    }

    var configID: String {
        rawValue
    }

    /// Whether `configID` names a built-in action that no longer exists (the
    /// built-in browser's `newBrowser`). Older cmux.json files may still list
    /// it; config loading skips such entries instead of rejecting the file.
    static func isRemovedConfigID(_ configID: String) -> Bool {
        configID == "cmux.newBrowser" || configID == "newBrowser"
    }

    var resolvedConfigMetadata: (title: String, keywords: [String]) {
        switch self {
        case .newWorkspace:
            return (String(localized: "command.newWorkspace.title", defaultValue: "New Workspace"), ["create", "new", "workspace"])
        case .newAgentChat:
            return (String(localized: "command.newAgentChat.title", defaultValue: "New agent chat"), ["create", "new", "agent", "chat", "browser", "codex", "claude"])
        case .newTerminal:
            return (String(localized: "command.newTerminalTab.title", defaultValue: "New Terminal Tab"), ["new", "terminal", "tab", "surface"])
        case .newSimulator:
            return (String(localized: "command.newSimulatorPane.title", defaultValue: "New Simulator Pane"), ["new", "simulator", "iphone", "ipad", "ios", "surface"])
        case .splitRight:
            return (String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right"), ["terminal", "split", "right"])
        case .splitDown:
            return (String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down"), ["terminal", "split", "down"])
        }
    }

    var defaultIcon: String {
        switch self {
        case .newWorkspace:
            return "plus.square"
        case .newAgentChat:
            return "message"
        case .newTerminal:
            return "terminal"
        case .newSimulator:
            return "iphone.gen3"
        case .splitRight:
            return "square.split.2x1"
        case .splitDown:
            return "square.split.1x2"
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .newAgentChat, .newSimulator:
            return nil
        case .newTerminal:
            return .newTerminal
        case .splitRight:
            return .splitRight
        case .splitDown:
            return .splitDown
        }
    }
}

extension CmuxSurfaceTabBarBuiltInAction {
    /// The user-editable shortcut that triggers the same behavior as this
    /// built-in action. Menus that list built-in actions read the live
    /// `KeyboardShortcutSettings` value through this mapping, so a rebind or
    /// an unbind in Settings or `cmux.json` shows up the next time the menu
    /// opens. Actions with no cmux-owned shortcut return nil.
    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .newWorkspace: return .newTab
        case .newTerminal: return .newSurface
        case .splitRight: return .splitRight
        case .splitDown: return .splitDown
        case .newAgentChat, .newSimulator: return nil
        }
    }

}
