import Foundation

/// A device-management policy cmux honors when an administrator forces it
/// through a macOS configuration profile (MDM "Custom Settings" payload).
///
/// The raw value is the preference key an administrator sets in the
/// ``ManagedDevicePolicy/releasePayloadDomain`` preference domain. Policy
/// keys are deliberately separate from the user-facing settings catalog:
/// a managed policy is tier-0 — it wins over environment variables, user
/// `UserDefaults`, `cmux.json` imports, and built-in defaults — and it can
/// never be changed from inside the app.
public enum ManagedDevicePolicyKey: String, CaseIterable, Sendable {
    /// Disables cmux-mediated file transfer: drag-and-drop and pasted-image
    /// uploads into remote terminals and the configured custom upload command.
    /// Local drops into local terminals still work,
    /// and a user's own `scp` in a shell is out of scope by design.
    case disableFileTransfer = "DisableFileTransfer"


    /// Disables interpreted custom sidebars from `~/.config/cmux/sidebars`
    /// (user- or agent-authored code that can dispatch `cmux(...)` commands).
    case disableCustomSidebars = "DisableCustomSidebars"

    /// The keys whose enforced state is "forced to `false`" rather than
    /// "forced to `true`". Every other Boolean key is a `Disable…` switch.
    public static let allowStyleKeys: Set<ManagedDevicePolicyKey> = []
}
