import Foundation
import Testing
import CmuxTerminalCore

@Suite struct TerminalLinkRouterTests {
    private let router = TerminalLinkRouter()

    @Test func resolvesFileSchemeAsExternal() throws {
        let target = try #require(router.resolveOpenURLTarget("file:///tmp/cmux.txt"))
        guard case let .external(url) = target else {
            Issue.record("Expected file URL to open externally")
            return
        }
        #expect(url.isFileURL)
        #expect(url.path == "/tmp/cmux.txt")
    }

    @Test func resolvesAbsolutePathAsExternalFileURL() throws {
        let target = try #require(router.resolveOpenURLTarget("/tmp/cmux-path.txt"))
        guard case let .external(url) = target else {
            Issue.record("Expected absolute file path to open externally")
            return
        }
        #expect(url.isFileURL)
        #expect(url.path == "/tmp/cmux-path.txt")
    }

    @Test func resolvesNonWebSchemeAsExternal() throws {
        let target = try #require(router.resolveOpenURLTarget("mailto:test@example.com"))
        guard case let .external(url) = target else {
            Issue.record("Expected non-web scheme to open externally")
            return
        }
        #expect(url.scheme == "mailto")
    }

    @Test func resolvesHostlessHTTPSAsExternal() throws {
        let target = try #require(router.resolveOpenURLTarget("https:///tmp/cmux.txt"))
        guard case let .external(url) = target else {
            Issue.record("Expected hostless HTTPS URL to open externally")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == nil)
        #expect(url.path == "/tmp/cmux.txt")
    }

    @Test func emptyTextResolvesToNil() {
        #expect(router.resolveOpenURLTarget("") == nil)
        #expect(router.resolveOpenURLTarget("   \n") == nil)
    }

    @Test func nonNavigableTokenFallsBackToExternalURL() {
        // Scheme-less text the browser cannot navigate still becomes an
        // external URL when Foundation can parse it as a relative URL.
        // (Multi-word text is deliberately not asserted here: URL(string:)
        // rejects spaces on macOS 14/15 but percent-encodes them on newer
        // Foundation, so its routing is OS-dependent.)
        let target = router.resolveOpenURLTarget("foo_bar")
        guard case let .external(url)? = target else {
            Issue.record("Expected non-navigable token to fall back to external routing")
            return
        }
        #expect(url.absoluteString == "foo_bar")
    }

    @Test func openTargetURLAccessorReturnsDestination() throws {
        let embedded = try #require(router.resolveOpenURLTarget("https://example.com/a"))
        #expect(embedded.url.absoluteString == "https://example.com/a")
        let external = try #require(router.resolveOpenURLTarget("mailto:a@b.com"))
        #expect(external.url.absoluteString == "mailto:a@b.com")
    }
}
