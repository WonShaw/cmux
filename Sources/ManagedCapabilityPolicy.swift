import AppKit
import CmuxSettings
import Foundation

/// MDM master switches for the capabilities that reach off this Mac.
///
/// Each type is the single authoritative answer to "may cmux do this at all",
/// so every entry point (UI, command palette, menus, CLI, socket, session
/// restore, automation) composes the same check instead of repeating the
/// resolver lookup. All of them default to *allowed*: an unmanaged Mac, and a
/// managed Mac whose profile does not force the key, behave exactly as before.
///
/// Decisions read only the forced-preference resolver. Tests inject a resolver
/// into the resource owner instead of replacing process-wide policy state.
/// MDM master switch for cmux-mediated file transfer.
enum ManagedFileTransferPolicy {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableFileTransfer`.
    static var isDisabled: Bool {
        return policy.isEnforced(.disableFileTransfer)
    }

    static var isEnabled: Bool { !isDisabled }

    static var disabledMessage: String {
        String(
            localized: "managedPolicy.fileTransfer.disabled",
            defaultValue: "File transfer is disabled by your organization."
        )
    }

    /// The failure handed to transfer callers.
    static func refusalError() -> NSError {
        NSError(
            domain: refusalErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: disabledMessage]
        )
    }

    static let refusalErrorDomain = "cmux.managedPolicy.fileTransfer"

    /// Whether `error` is this policy's refusal (as opposed to a transport
    /// failure), so a drop or paste handler can explain it instead of beeping.
    static func isRefusal(_ error: Error) -> Bool {
        (error as NSError).domain == refusalErrorDomain
    }

    /// Tells the user why the drop or paste did nothing. The failure handlers
    /// otherwise reduce every upload error to a beep, which would leave a
    /// managed refusal indistinguishable from a broken connection. Callable
    /// from any context: the alert is presented on the main actor.
    static func presentRefusal() {
        let message = disabledMessage
        let detail = String(
            localized: "managedPolicy.fileTransfer.refusalDetail",
            defaultValue: "cmux did not upload the file. Your organization's device policy disables file transfer through cmux."
        )
        let present: @MainActor () -> Void = {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.alertStyle = .informational
            alert.runModal()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(present)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(present) }
        }
    }
}

/// A managed-policy refusal thrown from a service boundary. Its description
/// is the user-facing message, so socket and CLI error paths print it as-is.
struct ManagedPolicyRefusal: Error, CustomStringConvertible, LocalizedError {
    let message: String
    var description: String { message }
    var errorDescription: String? { message }
}
