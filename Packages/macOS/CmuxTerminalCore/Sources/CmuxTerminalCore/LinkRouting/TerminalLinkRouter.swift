import Foundation
#if DEBUG
import CMUXDebugLog
#endif

/// Resolves a link activated inside a terminal into a system open target.
///
/// Absolute file-system paths become file URLs; anything else that parses as
/// a URL is handed to the system as-is (default browser, Finder, or scheme
/// handler).
public struct TerminalLinkRouter: Sendable {
    /// Creates a router.
    public init() {}

    /// Resolves raw link text into an open target.
    ///
    /// - Parameter rawValue: The raw link text from the runtime or UI.
    /// - Returns: The routing decision, or `nil` for empty or unparseable
    ///   text.
    public func resolveOpenURLTarget(_ rawValue: String) -> TerminalOpenURLTarget? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        logDebugEvent("link.resolve input=\(trimmed)")
        #endif
        guard !trimmed.isEmpty else {
            #if DEBUG
            logDebugEvent("link.resolve result=nil (empty)")
            #endif
            return nil
        }

        if NSString(string: trimmed).isAbsolutePath {
            #if DEBUG
            logDebugEvent("link.resolve result=external(absolutePath) url=\(trimmed)")
            #endif
            return .external(URL(fileURLWithPath: trimmed))
        }

        if let parsed = URL(string: trimmed),
           let scheme = parsed.scheme?.lowercased() {
            #if DEBUG
            logDebugEvent("link.resolve result=external(scheme=\(scheme)) url=\(parsed)")
            #endif
            return .external(parsed)
        }

        guard let fallback = URL(string: trimmed) else {
            #if DEBUG
            logDebugEvent("link.resolve result=nil (unparseable)")
            #endif
            return nil
        }
        #if DEBUG
        logDebugEvent("link.resolve result=external(fallback) url=\(fallback)")
        #endif
        return .external(fallback)
    }
}
