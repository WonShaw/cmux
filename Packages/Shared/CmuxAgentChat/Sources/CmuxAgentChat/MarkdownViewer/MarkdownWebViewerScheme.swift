import Foundation

/// Custom WKWebView URL scheme used by the shared markdown viewer shell.
///
/// The shell (`Resources/markdown-viewer/shell.html`) rewrites local image
/// sources to this scheme so the host app mediates every image byte: local
/// images stay confined to the markdown file's directory. Remote images are
/// never loaded; the shell renders an inert placeholder for them instead.
public enum MarkdownWebViewerScheme {
    public static let localImage = "cmux-local-image"
}
