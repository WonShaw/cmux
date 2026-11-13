import CmuxTerminal

/// Count-only view telemetry read on the actor that owns the native surfaces.
struct MemoryResourceViewCounts: Sendable {
    let visibleTerminals: Int
    let realizedRenderers: Int
    let presentedRenderers: Int

    @MainActor
    static func capture() -> Self {
        let surfaces = GhosttyApp.terminalSurfaceRegistry.allTerminalSurfacesUnordered()
        return Self(
            visibleTerminals: surfaces.filter(\.isRendererEffectivelyVisible).count,
            realizedRenderers: surfaces.filter(\.isRendererRealized).count,
            presentedRenderers: surfaces.filter(\.isRendererPresented).count
        )
    }

    func payload() -> [String: Any] {
        [
            "visible_terminal_count": visibleTerminals,
            "realized_renderer_count": realizedRenderers,
            "presented_renderer_count": presentedRenderers
        ]
    }
}
