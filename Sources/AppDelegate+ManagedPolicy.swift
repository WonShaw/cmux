import AppKit
import CmuxSettings
import Foundation

/// Runtime handling for MDM managed policies (`DisableFileTransfer`,
/// `DisableCustomSidebars`): installs the transition observer that signals
/// policy changes while the app runs.
extension AppDelegate {
    /// Installs the managed-policy transition observer once at startup.
    func installManagedPolicyEnforcement() {
        guard managedPolicyEnforcementObserver == nil else { return }
        managedPolicyEnforcementObserver = ManagedPolicyEnforcementObserver()
    }
}
