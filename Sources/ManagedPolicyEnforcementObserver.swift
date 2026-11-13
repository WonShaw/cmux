import AppKit
import CmuxSettings
import Foundation

/// Applies MDM managed-policy transitions to a running app.
///
/// No remaining policy has live resources to tear down, so every transition
/// only posts
/// `ManagedDevicePolicy.didChangeNotification` so Settings UI re-reads the
/// resolver.
///
/// Managed-preference pushes do not reliably fire
/// `UserDefaults.didChangeNotification`, so the observer also re-evaluates on
/// app activation and on a periodic cadence (``recheckInterval``) — an MDM
/// push against a Mac that stays frontmost is enforced within one interval,
/// not only at the next activation.
@MainActor
final class ManagedPolicyEnforcementObserver {
    /// Upper bound on enforcement latency for out-of-band MDM pushes that
    /// fire no local notification. Justified periodic re-check: there is no
    /// callback API for managed-preference changes, and an enforcement
    /// deadline is the intended behavior (matches MDM check-in semantics).
    static let recheckInterval: Duration = .seconds(60)
    private let notificationCenter: NotificationCenter
    private let capabilityPolicy: ManagedDevicePolicy
    /// Keys whose runtime effect is a per-call read, a launch-time read, or a
    /// Settings lock: a transition only needs the change signal.
    private static let settingsVisibleKeys: [ManagedDevicePolicyKey] = [
        .disableCustomSidebars,
    ]
    private var settingsVisiblePolicyStates: [ManagedDevicePolicyKey: Bool]
    private var fileTransferPolicyActive: Bool
    private var observationTasks: [Task<Void, Never>] = []

    init(
        notificationCenter: NotificationCenter = .default,
        capabilityPolicy: ManagedDevicePolicy = ManagedDevicePolicy()
    ) {
        self.notificationCenter = notificationCenter
        self.capabilityPolicy = capabilityPolicy
        settingsVisiblePolicyStates = Self.settingsVisibleStates(capabilityPolicy)
        fileTransferPolicyActive = capabilityPolicy.isEnforced(.disableFileTransfer)
        observe(UserDefaults.didChangeNotification)
        observe(NSApplication.didBecomeActiveNotification)
        observationTasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.recheckInterval)
                } catch {
                    break
                }
                guard let self else { break }
                self.reevaluate()
            }
        })
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
    }

    private static func settingsVisibleStates(_ policy: ManagedDevicePolicy) -> [ManagedDevicePolicyKey: Bool] {
        Dictionary(uniqueKeysWithValues: settingsVisibleKeys.map { ($0, policy.isEnforced($0)) })
    }

    private func observe(_ name: Notification.Name) {
        let center = notificationCenter
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: name) {
                guard let self else { break }
                self.reevaluate()
            }
        })
    }

    /// Compares the current policy state to the last-seen state and posts the
    /// change signal on a transition. Exposed for tests and for the
    /// startup call after construction.
    func reevaluate() {
        var anyTransition = false
        let fileTransferNow = capabilityPolicy.isEnforced(.disableFileTransfer)
        if fileTransferNow != fileTransferPolicyActive {
            // Transfers are momentary: nothing live to tear down, the next
            // upload reads the resolver.
            fileTransferPolicyActive = fileTransferNow
            anyTransition = true
        }
        let settingsVisibleNow = Self.settingsVisibleStates(capabilityPolicy)
        if settingsVisibleNow != settingsVisiblePolicyStates {
            settingsVisiblePolicyStates = settingsVisibleNow
            anyTransition = true
        }
        if anyTransition {
            // Settings UI re-reads the resolver on this signal.
            notificationCenter.post(
                name: ManagedDevicePolicy.didChangeNotification,
                object: nil
            )
        }
    }
}
