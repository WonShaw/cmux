import AppKit
import Foundation
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

enum SurfaceSelectionTestError: Error {
    case expectedSnapshot
    case navigationFailed(String)
}
