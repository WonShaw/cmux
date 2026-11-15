public import Foundation
internal import UniformTypeIdentifiers

/// Decides what cmux may hand to Launch Services.
///
/// Opening a file "with the system default application" runs it when the file
/// is a script, an executable, an application bundle, or a document type whose
/// handler executes its contents (`.command`, `.terminal`, `.webloc`, ...).
/// A link printed in a terminal or a file in a cloned repository is not
/// trusted, so cmux only launches plain document types and shows everything
/// else in Finder instead.
public enum SystemOpenSafetyPolicy {
    /// URL schemes cmux may pass to the system without asking.
    public static let directlyOpenableSchemes: Set<String> = ["http", "https", "mailto"]

    /// Extensions that are never launched, whatever type they resolve to.
    static let blockedExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "workflow", "action", "scpt", "scptd",
        "applescript", "osascript", "sh", "bash", "zsh", "csh", "ksh", "fish", "py",
        "pyc", "pl", "rb", "php", "js", "mjs", "cjs", "jar", "jnlp", "ps1", "bat",
        "cmd", "exe", "msi", "pkg", "mpkg", "dmg", "kext", "prefpane", "saver",
        "qlgenerator", "plugin", "bundle", "framework", "dylib", "so", "webloc",
        "inetloc", "fileloc", "afploc", "ftploc", "url", "webarchive", "html", "htm",
        "xhtml", "shtml", "svg", "mobileconfig", "configprofile", "provisionprofile",
        "itermcolors", "shortcut", "service", "xpc", "systemextension", "appex",
        "installer", "pyw", "lua", "tcl", "awk", "vbs", "wsf", "desktop", "lnk",
    ]

    /// Content types that are safe to open in their default viewer or editor.
    static let allowedTypes: [UTType] = [
        .image, .audiovisualContent, .pdf, .plainText, .rtf, .rtfd, .json, .xml,
        .commaSeparatedText, .tabSeparatedText, .spreadsheet, .presentation, .log,
        .yaml, .sourceCode,
    ]

    /// Content types that are never launched even when they conform to an
    /// allowed type (scripts are plain text).
    static let blockedTypes: [UTType] = [
        .executable, .application, .applicationBundle, .script, .shellScript,
        .appleScript, .osaScript, .unixExecutable, .package, .bundle, .html,
        .internetLocation, .internetShortcut, .webArchive, .diskImage,
        .systemPreferencesPane, .pluginBundle, .applicationExtension,
    ]

    /// Whether `url` (a non-file URL) may be opened without confirmation.
    public static func isDirectlyOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return directlyOpenableSchemes.contains(scheme)
    }

    /// Whether a local file may be opened with its default application.
    ///
    /// Directories, packages, files with an execute bit, and any type that is
    /// not a plain document are refused.
    public static func isSafeToLaunch(fileURL url: URL, fileManager: FileManager = .default) -> Bool {
        guard url.isFileURL else { return false }
        let resolved = url.resolvingSymlinksInPath()
        let path = resolved.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        if fileManager.isExecutableFile(atPath: path) { return false }
        let extensions = [url.pathExtension.lowercased(), resolved.pathExtension.lowercased()]
        if extensions.contains(where: { blockedExtensions.contains($0) }) { return false }
        let type = (try? resolved.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: resolved.pathExtension)
        guard let type else { return false }
        if blockedTypes.contains(where: { type.conforms(to: $0) }) { return false }
        // A source file such as `.swift` is fine, but Launch Services may map
        // an unknown "source code" extension to an interpreter, so only the
        // explicit allowlist is accepted.
        return allowedTypes.contains(where: { type.conforms(to: $0) })
    }
}
