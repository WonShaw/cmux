import Foundation
import Observation
import os

/// Local feature flags for the macOS app. Nothing is fetched: every flag
/// resolves on this Mac from its built-in default or a local override.
///
/// Resolution semantics (flags must never break the app):
/// - A permitted local override applies, then the explicit per-flag default.
///
/// Registry contract (enforced by scripts/lint-feature-flags.py in CI): each
/// flag declares key / owner / reviewBy / defaultWhenUnavailable in the FLAG
/// comment above its property, and its key literal appears nowhere else.
@MainActor
@Observable
final class CmuxFeatureFlags {
    static let shared = CmuxFeatureFlags(publishesOffMainSnapshot: true)

    private static let agentChatUIDefault = false
    private static let sidebarWorkspaceAgentSpinnerDefault = false
    private nonisolated static let simulatorDefault = true
    private static let workspaceTodoControlsDefault = false
    private static let appKitSidebarListDefault = true

    private static let overrideKeyPrefix = "cmux.flags.override."

    // FLAG(key: sidebar-appkit-list-experiment, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
    // Renders the workspace sidebar with the AppKit NSTableView list
    // (virtualized rows, measured-once heights) instead of the SwiftUI
    // LazyVStack. On by default after the remote rollout reached 100%.
    static let appKitSidebarListFlag = CmuxFeatureFlagDefinition(
        key: "sidebar-appkit-list-experiment",
        title: String(
            localized: "featureFlags.appKitSidebarList.title",
            defaultValue: "Lawrence Sidebar"
        ),
        flagDescription: String(
            localized: "featureFlags.appKitSidebarList.description",
            defaultValue: "Renders the workspace sidebar with a native AppKit list and divider for smoother scrolling and resizing with many workspaces."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.appKitSidebarListDefault
    )

    // FLAG(key: simulator-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
    // Controls every Simulator entrypoint and active pane. Local only.
    nonisolated static let simulatorFlag = CmuxFeatureFlagDefinition(
        key: "simulator-enabled-release",
        title: String(
            localized: "featureFlags.simulator.title",
            defaultValue: "Simulator"
        ),
        flagDescription: String(
            localized: "featureFlags.simulator.description",
            defaultValue: "Enables iPhone and iPad Simulator panes, commands, and automation."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.simulatorDefault
    )

    // FLAG(key: agent-chat-ui-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
    // Shows the Agent Chat entrypoints: the new-workspace dropdown item,
    // command-palette command, surface-tab-bar button, and shared action
    // executor. Hidden by default until the sidecar UX is ready to ship.
    static let agentChatUIFlag = CmuxFeatureFlagDefinition(
        key: "agent-chat-ui-enabled-release",
        title: String(localized: "featureFlags.agentChat.title", defaultValue: "Agent Chat UI"),
        flagDescription: String(
            localized: "featureFlags.agentChat.description",
            defaultValue: "Shows Agent Chat entrypoints in the new-workspace dropdown, command palette, and surface tab bar."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.agentChatUIDefault
    )

    // FLAG(key: sidebar-workspace-agent-spinner-experiment, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
    // Shows the coding-agent activity spinner in workspace rows. Hidden
    // by default while multi-agent lifecycle edge cases are investigated.
    static let sidebarWorkspaceAgentSpinnerFlag = CmuxFeatureFlagDefinition(
        key: "sidebar-workspace-agent-spinner-experiment",
        title: String(
            localized: "featureFlags.sidebarWorkspaceAgentSpinner.title",
            defaultValue: "Workspace agent spinner"
        ),
        flagDescription: String(
            localized: "featureFlags.sidebarWorkspaceAgentSpinner.description",
            defaultValue: "Shows a spinner in workspace rows while coding agents are running."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.sidebarWorkspaceAgentSpinnerDefault
    )

    // FLAG(key: workspace-todo-controls-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
    // Shows user-facing workspace todo controls that create checklist
    // items or set completion/status lanes. Hidden until the local
    // beta setting opts in.
    static let workspaceTodoControlsFlag = CmuxFeatureFlagDefinition(
        key: "workspace-todo-controls-enabled-release",
        title: String(
            localized: "featureFlags.workspaceTodoControls.title",
            defaultValue: "Workspace todo controls"
        ),
        flagDescription: String(
            localized: "featureFlags.workspaceTodoControls.description",
            defaultValue: "Shows Add Checklist Item and workspace completion status controls."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.workspaceTodoControlsDefault
    )

    /// Every registered flag, in display order. Accessors reference their
    /// named definition directly, never a position in this list.
    static let allFlags: [CmuxFeatureFlagDefinition] = [
        CmuxFeatureFlags.agentChatUIFlag,
        CmuxFeatureFlags.sidebarWorkspaceAgentSpinnerFlag,
        CmuxFeatureFlags.simulatorFlag,
        CmuxFeatureFlags.workspaceTodoControlsFlag,
        CmuxFeatureFlags.appKitSidebarListFlag,
    ]

    var isAgentChatUIEnabled: Bool {
        effectiveValue(for: Self.agentChatUIFlag)
    }

    var isSidebarWorkspaceAgentSpinnerEnabled: Bool {
        effectiveValue(for: Self.sidebarWorkspaceAgentSpinnerFlag)
    }

    var isSimulatorEnabled: Bool {
        effectiveValue(for: Self.simulatorFlag)
    }
    var isWorkspaceTodoControlsEnabled: Bool {
        effectiveValue(for: Self.workspaceTodoControlsFlag)
    }
    var isAppKitSidebarListEnabled: Bool {
        effectiveValue(for: Self.appKitSidebarListFlag)
    }

    /// Effective values mirrored for nonisolated readers: the mobile host
    /// serves status payloads (which carry the capability list) off the main
    /// actor. Written only by the shared instance so test instances cannot
    /// stomp process-wide state. Before the shared instance exists, readers
    /// get the per-flag compile-time default (fail-closed for release flags).
    private nonisolated static let offMainEffectiveValues = OSAllocatedUnfairLock(
        initialState: [String: Bool]()
    )

    nonisolated static func offMainEffectiveValue(
        for definition: CmuxFeatureFlagDefinition
    ) -> Bool {
        offMainEffectiveValues.withLock { $0[definition.key] }
            ?? definition.defaultWhenUnavailable
    }

    @ObservationIgnored
    private let publishesOffMainSnapshot: Bool
    @ObservationIgnored
    private let overrideCapability: CmuxFeatureFlagOverrideCapability
    @ObservationIgnored
    private let defaults: UserDefaults

    private var localOverridesByKey: [String: Bool] = [:]
    private var resolutionsByKey: [String: CmuxFeatureFlagResolution] = [:]

    init(
        defaults: UserDefaults = .standard,
        overrideCapability: CmuxFeatureFlagOverrideCapability = .init(),
        publishesOffMainSnapshot: Bool = false
    ) {
        self.defaults = defaults
        self.overrideCapability = overrideCapability
        self.publishesOffMainSnapshot = publishesOffMainSnapshot
        localOverridesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.storedOverrideValue(for: definition.key, defaults: defaults) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
    }

    func effectiveValue(for definition: CmuxFeatureFlagDefinition) -> Bool {
        resolution(for: definition).effectiveValue
    }

    func resolution(for definition: CmuxFeatureFlagDefinition) -> CmuxFeatureFlagResolution {
        resolutionsByKey[definition.key] ?? CmuxFeatureFlagResolution(
            overrideValue: localOverridesByKey[definition.key],
            defaultValue: definition.defaultWhenUnavailable,
            overridePolicy: overrideCapability.policy(for: definition)
        )
    }

    func overrideValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        localOverridesByKey[definition.key]
    }

    func setOverride(_ value: Bool?, for definition: CmuxFeatureFlagDefinition) {
        guard value == nil || resolution(for: definition).allowsLocalOverride else { return }

        let previousResolutions = resolutionsByKey
        if let value {
            localOverridesByKey[definition.key] = value
            defaults.set(value, forKey: Self.overrideDefaultsKey(for: definition.key))
        } else {
            localOverridesByKey.removeValue(forKey: definition.key)
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    func clearAllOverrides() {
        let previousResolutions = resolutionsByKey
        var clearedAnyOverride = false
        for definition in Self.allFlags {
            if localOverridesByKey.removeValue(forKey: definition.key) != nil {
                clearedAnyOverride = true
            }
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        guard clearedAnyOverride else { return }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    private func recomputeEffectiveValues() {
        resolutionsByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            values[definition.key] = CmuxFeatureFlagResolution(
                overrideValue: localOverridesByKey[definition.key],
                defaultValue: definition.defaultWhenUnavailable,
                overridePolicy: overrideCapability.policy(for: definition)
            )
        }
        if publishesOffMainSnapshot {
            let effectiveValues = resolutionsByKey.mapValues(\.effectiveValue)
            Self.offMainEffectiveValues.withLock { $0 = effectiveValues }
        }
    }

    private func postChangeIfNeeded(previousResolutions: [String: CmuxFeatureFlagResolution]) {
        if previousResolutions != resolutionsByKey {
            NotificationCenter.default.post(name: .cmuxFeatureFlagsDidChange, object: self)
        }
    }

    private static func overrideDefaultsKey(for key: String) -> String {
        overrideKeyPrefix + key
    }

    private static func storedOverrideValue(for key: String, defaults: UserDefaults) -> Bool? {
        storedBoolValue(forKey: overrideDefaultsKey(for: key), defaults: defaults)
    }

    private static func storedBoolValue(forKey key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: key) else {
            return nil
        }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return nil
    }
}

extension Notification.Name {
    static let cmuxFeatureFlagsDidChange = Notification.Name("cmuxFeatureFlagsDidChange")
}
