import CryptoKit
import CmuxTerminalCore
import Darwin
import Foundation

enum CMUXDiffViewerLocalization {
    static func string(
        _ key: String,
        defaultValue: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let bundle = localizationBundle()
        if let localization = explicitLocalization(in: environment, bundle: bundle),
           let localized = localizedString(key, defaultValue: defaultValue, bundle: bundle, localization: localization) {
            return localized
        }
        return bundle.localizedString(forKey: key, value: defaultValue, table: nil)
    }

    static func localizationBundle(
        mainBundle: Bundle = .main,
        executableURL: URL? = CLIExecutableLocator.currentExecutableURL()
    ) -> Bundle {
        CLIExecutableLocator.enclosingAppBundle(startingAt: executableURL) ?? mainBundle
    }

    private static func explicitLocalization(in environment: [String: String], bundle: Bundle) -> String? {
        guard let languages = appleLanguages(from: environment["AppleLanguages"]),
              !languages.isEmpty else {
            return nil
        }

        return Bundle.preferredLocalizations(
            from: bundle.localizations,
            forPreferences: languages
        ).first
    }

    private static func appleLanguages(from rawValue: String?) -> [String]? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("("), value.hasSuffix(")") {
            value.removeFirst()
            value.removeLast()
        }
        let languages = value
            .split(separator: ",")
            .map { piece in
                piece
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
        return languages.isEmpty ? nil : languages
    }

    private static func localizedString(
        _ key: String,
        defaultValue: String,
        bundle: Bundle,
        localization: String
    ) -> String? {
        guard let lprojPath = bundle.path(forResource: localization, ofType: "lproj"),
              let languageBundle = Bundle(path: lprojPath) else {
            return nil
        }
        return languageBundle.localizedString(forKey: key, value: defaultValue, table: nil)
    }
}

extension CMUXCLI {
    private struct OpenArguments {
        var workspace: String?
        var window: String?
        var surface: String?
        var pane: String?
        var focus: String?
        var noFocus = false
        var targets: [String] = []
    }

    private enum OpenTarget {
        case directory(String)
        case file(String)
        case url(String)
    }

    func runOpenCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let parsedArgs = try parseOpenArguments(commandArgs)

        guard !parsedArgs.targets.isEmpty else {
            throw CLIError(message: "open requires at least one path or URL. Usage: cmux open <path-or-url>...")
        }

        let explicitFocus: Bool?
        if parsedArgs.noFocus {
            explicitFocus = false
        } else if let focusOpt = parsedArgs.focus {
            guard let parsed = parseBoolString(focusOpt) else {
                throw CLIError(message: "--focus must be true|false")
            }
            explicitFocus = parsed
        } else {
            explicitFocus = nil
        }
        let fileFocus = explicitFocus ?? true

        let targets = try parsedArgs.targets.map(resolveOpenTarget)
        var fileCount = 0
        var urlCount = 0
        var directoryCount = 0

        // Web URLs go to the system default browser from this process; when the
        // command names nothing else, the app is never contacted.
        let webURLs: [String] = targets.compactMap { target in
            if case .url(let url) = target { return url }
            return nil
        }
        if webURLs.count == targets.count {
            var opened: [[String: Any]] = []
            for url in webURLs {
                try openURLInSystemBrowser(url)
                opened.append(["kind": "url", "url": url])
            }
            if jsonOutput {
                print(jsonString(["opened": opened]))
            } else {
                print(openCommandSummary(
                    payloads: opened,
                    fileCount: 0,
                    urlCount: webURLs.count,
                    directoryCount: 0,
                    idFormat: idFormat
                ))
            }
            return
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let windowHandle = try normalizeWindowHandle(parsedArgs.window, client: client)
        let workspaceRaw = parsedArgs.workspace ?? (parsedArgs.window == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let shouldInheritCallerSurface = parsedArgs.workspace == nil && parsedArgs.pane == nil && parsedArgs.window == nil
        let surfaceRaw = parsedArgs.surface ?? (shouldInheritCallerSurface ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)
        let paneHandle = try normalizePaneHandle(parsedArgs.pane, client: client, workspaceHandle: workspaceHandle)

        var payloads: [[String: Any]] = []

        var pendingFiles: [String] = []
        func flushPendingFiles() throws {
            guard !pendingFiles.isEmpty else { return }
            let files = pendingFiles
            pendingFiles.removeAll()

            var params: [String: Any] = ["paths": files, "focus": fileFocus]
            if let windowHandle { params["window_id"] = windowHandle }
            if let workspaceHandle { params["workspace_id"] = workspaceHandle }
            if let surfaceHandle { params["surface_id"] = surfaceHandle }
            if let paneHandle { params["pane_id"] = paneHandle }
            let payload = try client.sendV2(method: "file.open", params: params)
            payloads.append(["kind": "file", "payload": payload])
            fileCount += files.count
        }

        for target in targets {
            switch target {
            case .file(let path):
                pendingFiles.append(path)
            case .directory(let directory):
                try flushPendingFiles()
                var params: [String: Any] = ["cwd": directory]
                if let windowHandle { params["window_id"] = windowHandle }
                let payload = try client.sendV2(method: "workspace.create", params: params)
                payloads.append(["kind": "workspace", "payload": payload, "path": directory])
                directoryCount += 1
            case .url(let url):
                try flushPendingFiles()
                try openURLInSystemBrowser(url)
                payloads.append(["kind": "url", "url": url])
                urlCount += 1
            }
        }
        try flushPendingFiles()

        if jsonOutput {
            print(jsonString(formatIDs(["opened": payloads], mode: idFormat)))
            return
        }

        print(openCommandSummary(
            payloads: payloads,
            fileCount: fileCount,
            urlCount: urlCount,
            directoryCount: directoryCount,
            idFormat: idFormat
        ))
    }

    /// Opens a web URL in the system default browser. Called only as the direct
    /// result of the user running `cmux open <url>`.
    private func openURLInSystemBrowser(_ url: String) throws {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/open",
            arguments: [url]
        )
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(message: detail.isEmpty ? "Failed to open URL: \(url)" : "Failed to open URL: \(url): \(detail)")
        }
    }

    private func parseOpenArguments(_ commandArgs: [String]) throws -> OpenArguments {
        var parsed = OpenArguments()
        var index = 0
        var isParsingOptions = true

        while index < commandArgs.count {
            let arg = commandArgs[index]
            if isParsingOptions, arg == "--" {
                isParsingOptions = false
                index += 1
                continue
            }

            if isParsingOptions {
                switch arg {
                case "--workspace":
                    parsed.workspace = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--window":
                    parsed.window = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--surface":
                    parsed.surface = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--pane":
                    parsed.pane = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--focus":
                    parsed.focus = try openOptionValue(commandArgs, index: index, name: arg)
                    index += 2
                    continue
                case "--no-focus":
                    parsed.noFocus = true
                    index += 1
                    continue
                default:
                    if arg.hasPrefix("-") {
                        throw CLIError(message: "open: unknown flag '\(arg)'. Usage: cmux open <path-or-url>... [--workspace <id|ref|index>] [--surface <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>] [--focus true|false] [--no-focus]")
                    }
                }
            }

            parsed.targets.append(arg)
            index += 1
        }

        return parsed
    }

    private func openOptionValue(_ args: [String], index: Int, name: String) throws -> String {
        guard index + 1 < args.count else {
            throw CLIError(message: "\(name) requires a value")
        }
        return args[index + 1]
    }

    private func resolveOpenTarget(_ raw: String) throws -> OpenTarget {
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .url(url.absoluteString)
        }
        let resolved = TerminalPathResolver().resolveOpenURLFileReference(raw, cwd: FileManager.default.currentDirectoryPath)?.path ?? resolvePath(raw)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        if isDir.boolValue {
            return .directory(resolved)
        }
        return .file(resolved)
    }

    func openSubcommandUsage() -> String {
        """
        Usage: cmux open <path-or-url>... [options]

        Open files and directories in cmux; http(s) URLs open in the system default browser.
        Markdown files open in markdown preview tabs; other files open in file preview tabs.
        Multiple files open as tabs in the same target pane.

        Options:
          --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
          --surface <id|ref|index>     Target surface whose pane should receive file tabs (default: $CMUX_SURFACE_ID)
          --pane <id|ref|index>        Target pane for file tabs
          --window <id|ref|index>      Target window
          --focus <true|false>         Focus opened file previews (default: true)
          --no-focus                   Do not focus opened file previews

        Examples:
          cmux open report.pdf
          cmux open image-a.png image-b.jpg
          cmux open ~/Downloads/movie.mov --pane pane:1
          cmux open https://example.com
        """
    }

    private func openCommandSummary(
        payloads: [[String: Any]],
        fileCount: Int,
        urlCount: Int,
        directoryCount: Int,
        idFormat: CLIIDFormat
    ) -> String {
        let filePayload = payloads.first { ($0["kind"] as? String) == "file" }?["payload"] as? [String: Any]
        let surfaceText = filePayload.flatMap { formatHandle($0, kind: "surface", idFormat: idFormat) }
        let paneText = filePayload.flatMap { formatHandle($0, kind: "pane", idFormat: idFormat) }
        var pieces = ["OK"]
        if fileCount > 0 {
            pieces.append("files=\(fileCount)")
            if let surfaceText { pieces.append("surface=\(surfaceText)") }
            if let paneText { pieces.append("pane=\(paneText)") }
        }
        if urlCount > 0 {
            pieces.append("urls=\(urlCount)")
        }
        if directoryCount > 0 {
            pieces.append("workspaces=\(directoryCount)")
        }
        return pieces.joined(separator: " ")
    }
}
