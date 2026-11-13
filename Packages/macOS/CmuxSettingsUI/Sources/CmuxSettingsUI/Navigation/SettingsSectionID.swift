import Foundation

/// Top-level navigation targets for the settings window.
///
/// The cmux app exposes a fixed set of section panes. Each section gets
/// its own SwiftUI view in `Sections/`; the sidebar lists them in
/// declaration order, the search index filters across all of them.
///
/// Adding a section means: add a case here, add its title and icon in
/// the `SettingsSectionID` extension below, and add a view file in
/// `Sections/`.
public enum SettingsSectionID: String, CaseIterable, Identifiable, Sendable, Hashable {
    case app
    case terminal
    case textBox
    /// Sleepy Mode screensaver + keep-awake lock.
    case sleepyMode
    case sidebarAppearance
    /// User/agent-authored custom sidebars: enable gate and renderer choice.
    case customSidebars
    case betaFeatures
    case automation
    case globalHotkey
    case keyboardShortcuts
    case workspaceColors
    case settingsJSON
    case reset

    public var id: Self { self }

    /// User-facing section title shown in the sidebar.
    public var title: String {
        switch self {
        case .app: return String(localized: "settings.section.app", defaultValue: "App")
        case .terminal: return String(localized: "settings.section.terminal", defaultValue: "Terminal")
        case .textBox: return String(localized: "settings.section.textBox", defaultValue: "TextBox (Beta)")
        case .sleepyMode: return String(localized: "settings.section.sleepyMode", defaultValue: "Sleepy Mode")
        case .sidebarAppearance: return String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar")
        case .customSidebars: return String(localized: "settings.section.customSidebars", defaultValue: "Custom Sidebars")
        case .betaFeatures: return String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features")
        case .automation: return String(localized: "settings.section.automation", defaultValue: "Automation")
        case .globalHotkey: return String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey")
        case .keyboardShortcuts: return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .workspaceColors: return String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors")
        case .settingsJSON: return "cmux.json"
        case .reset: return String(localized: "settings.section.reset", defaultValue: "Reset")
        }
    }

    /// SF Symbol shown alongside the title in the sidebar.
    public var symbolName: String {
        switch self {
        case .app: return "gearshape"
        case .terminal: return "terminal"
        case .textBox: return "textformat"
        case .sleepyMode: return "moon.zzz"
        case .sidebarAppearance: return "sidebar.left"
        case .customSidebars: return "sidebar.squares.left"
        case .betaFeatures: return "exclamationmark.triangle"
        case .automation: return "wand.and.sparkles"
        case .globalHotkey: return "keyboard.badge.ellipsis"
        case .keyboardShortcuts: return "keyboard"
        case .workspaceColors: return "paintpalette"
        case .settingsJSON: return "doc.text"
        case .reset: return "arrow.counterclockwise"
        }
    }

    /// Space-separated keywords used by the settings search index. Each
    /// section can advertise additional terms here so users find sections
    /// by capability rather than only by title.
    public var searchKeywords: String {
        switch self {
        case .app: return "appearance language workspace notifications menu bar"
        case .terminal: return "scrollbar copy on select agent resume hibernation"
        case .textBox: return "textbox text box rich input prompt default new terminal workspace split tab focus show beta"
        case .sleepyMode: return "sleepy mode screensaver caffeinate keep awake lock touch id battery wifi clock mascot theme glow pixel"
        case .sidebarAppearance: return "sidebar details branches material terminal background"
        case .customSidebars: return "custom sidebars vibe swift json interpreted renderer in-process remote worker isolated"
        case .betaFeatures: return "beta experimental unstable feed dock right sidebar"
        case .automation: return "socket integrations hooks ports claude cursor gemini naming auto naming workspace tabs"
        case .globalHotkey: return "system wide shortcut"
        case .keyboardShortcuts: return "keybindings commands chords"
        case .workspaceColors: return "palette tabs indicator"
        case .settingsJSON: return "config file preferences editor schema jsonc reload"
        case .reset: return "defaults reset"
        }
    }
}
