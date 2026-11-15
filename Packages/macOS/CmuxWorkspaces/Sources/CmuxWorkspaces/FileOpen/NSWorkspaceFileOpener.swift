public import Foundation
internal import AppKit

/// The production ``SystemFileOpening`` conformer: opens files through
/// `NSWorkspace`.
///
/// Only plain document types are launched (see ``SystemOpenSafetyPolicy``).
/// Anything that could execute (scripts, executables, bundles, `.terminal`,
/// `.webloc`, ...) is shown in Finder instead, so a link or a file from an
/// untrusted source can never run with one click.
public struct NSWorkspaceFileOpener: SystemFileOpening {
    /// Creates an opener backed by the shared `NSWorkspace`.
    public init() {}

    @MainActor
    public func openWithSystemDefault(_ url: URL) {
        if SystemOpenSafetyPolicy.isSafeToLaunch(fileURL: url) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
