/// The kind of surface a Dock pane hosts. The Dock reuses the main-area panel
/// system; terminals are the only pane kind it creates.
enum DockSurfaceKind: String, Codable, Equatable, Sendable {
    case terminal
}
