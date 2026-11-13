import AppKit

extension NSWindow {
    static func keyDescription(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.control) { parts.append("Ctrl") }
        let chars: String
        if event.type == .keyDown || event.type == .keyUp {
            chars = event.charactersIgnoringModifiers ?? "?"
        } else {
            chars = String(describing: event.type)
        }
        parts.append("'\(chars)'(\(event.keyCode))")
        return parts.joined(separator: "+")
    }
}
