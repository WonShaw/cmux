internal import Foundation

/// The file-into-panel openers of the project domain: `markdown.open` and
/// `file.open`, lifted byte-faithfully from the former
/// `TerminalController.v2MarkdownOpen` / `v2FileOpen` bodies (including the
/// pure-Foundation readable-path validation, which both share).
extension ControlCommandCoordinator {
    /// `file.open` — open one or more files as preview/markdown surfaces.
    ///
    /// A passthrough to the still-shared `v2FileOpen` body (also driven directly
    /// by cmuxTests), bridging its Foundation result — one source of truth,
    /// byte-identical wire output, like `workspace.create`.
    func fileOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        projectContext?.controlFileOpen(params: params)
            ?? .err(code: "unavailable", message: "TabManager not available", data: nil)
    }

    /// The shared readable-file-path validation of `markdown.open` /
    /// `file.open` (the legacy `v2ResolveReadableFilePath`): tilde-expand,
    /// standardize, then require an absolute, existing, non-directory,
    /// readable file.
    func resolveReadableFilePath(_ rawPath: String) -> (path: String?, error: ControlCallResult?) {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let filePath = NSString(string: expandedPath).standardizingPath

        guard filePath.hasPrefix("/") else {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Path must be absolute: \(filePath)",
                    data: .object(["path": .string(filePath)])
                )
            )
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
            return (
                nil,
                .err(
                    code: "not_found",
                    message: "File not found: \(filePath)",
                    data: .object(["path": .string(filePath)])
                )
            )
        }
        guard !isDir.boolValue else {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Path is a directory, not a file: \(filePath)",
                    data: .object(["path": .string(filePath)])
                )
            )
        }
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            return (
                nil,
                .err(
                    code: "permission_denied",
                    message: "File not readable: \(filePath)",
                    data: .object(["path": .string(filePath)])
                )
            )
        }

        return (filePath, nil)
    }
}
