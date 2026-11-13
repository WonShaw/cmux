import AppKit
import Bonsplit
import CmuxCommandPalette
import Foundation
import CmuxTerminal

func browserOmnibarNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

/// Policy decisions shared by the window and text-input shortcut routers.
enum ShortcutRoutingPolicy {
    /// Returns whether a key-down event has Option as its only primary modifier.
    /// Shift may still be present; Command and Control opt the event out of the
    /// Option-text routing policy.
    static func isOptionOnly(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let normalizedFlags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        return normalizedFlags.contains(.option)
            && !normalizedFlags.contains(.command)
            && !normalizedFlags.contains(.control)
    }
}

func shortcutRoutingShouldBypassForPrintableOptionText(
    event: NSEvent,
    textInputCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.textInputCharacter(forKeyCode:modifierFlags:)
) -> Bool {
    guard ShortcutRoutingPolicy.isOptionOnly(event) else { return false }

    if shortcutRoutingTextIsPrintable(event.characters) {
        return true
    }

    return shortcutRoutingTextIsPrintable(
        textInputCharacterProvider(event.keyCode, event.modifierFlags)
    )
}

private func shortcutRoutingTextIsPrintable(_ text: String?) -> Bool {
    guard let text, !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
        guard !isControlCharacterScalar(scalar) else { return false }
        return scalar.value < 0xF700 || scalar.value > 0xF8FF
    }
}

func shortcutResponderHasMarkedText(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }

    // During IME composition, Return/Enter belongs to the text system so the
    // candidate list can commit or confirm the marked text.
    if let textInputClient = responder as? NSTextInputClient {
        return textInputClient.hasMarkedText()
    }

    if let textField = responder as? NSTextField,
       let editor = textField.currentEditor() as? NSTextView {
        return editor.hasMarkedText()
    }

    return false
}

/// Returns true when a terminal arrow key-equivalent should be sent through keyDown.
func shouldDispatchTerminalArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsTerminal: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsTerminal, !firstResponderHasMarkedText, (123...126).contains(keyCode) else { return false }
    return !browserOmnibarNormalizedModifierFlags(flags).contains(.command)
}

func shouldDispatchCommandPaletteHorizontalArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsCommandPaletteFieldEditor: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsCommandPaletteFieldEditor else { return false }
    guard !firstResponderHasMarkedText else { return false }
    guard keyCode == 123 || keyCode == 124 else { return false }

    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    switch normalizedFlags {
    case [], [.shift], [.option], [.option, .shift], [.command], [.command, .shift]:
        return true
    default:
        return false
    }
}

/// Whether an arrow keyDown belongs to a focused standalone editable text
/// responder (text-box input, file-preview editor, …) so it should be
/// forwarded to `firstResponder.keyDown` rather than swallowed by the original
/// `NSWindow.performKeyEquivalent`.
///
/// Owns the four arrows (keyCodes 123–126) for the modifier combos a text
/// editor handles itself: plain (move), Shift (extend selection), Option
/// (word/paragraph), and Command (line/document boundary) plus their Shift
/// combos. Cmd+Option+Arrow is excluded so it still reaches cmux's pane-focus
/// shortcuts. Marked text (IME composition) is left to the input method.
private func standaloneTextResponderOwnsArrowKeyDown(
    keyCode: UInt16,
    firstResponderHasMarkedText: Bool,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard !firstResponderHasMarkedText else { return false }
    guard (123...126).contains(keyCode) else { return false }

    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    switch normalizedFlags {
    case [], [.shift], [.option], [.option, .shift], [.command], [.command, .shift]:
        return true
    default:
        return false
    }
}

func shouldDispatchTextBoxInputArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsTextBoxInput: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsTextBoxInput else { return false }
    return standaloneTextResponderOwnsArrowKeyDown(
        keyCode: keyCode,
        firstResponderHasMarkedText: firstResponderHasMarkedText,
        flags: flags
    )
}

/// Whether an arrow keyDown should be forwarded straight to the focused
/// standalone editable text view instead of falling through to the original
/// `NSWindow.performKeyEquivalent`, which swallows plain arrows before the
/// view's `keyDown` runs.
///
/// This generalizes the per-surface arrow-forwarding seam (browser, omnibar,
/// command palette, text-box input) to cover the whole class of standalone
/// editable `NSTextView`s cmux hosts, the file-preview editor today, any
/// future one tomorrow. Field editors (the omnibar / command-palette / find
/// field editors) are excluded by the caller because they have their own
/// dedicated routing or work through the normal field-editor path. Shares the
/// keyCode/modifier policy with ``shouldDispatchTextBoxInputArrowViaFirstResponderKeyDown``
/// via ``standaloneTextResponderOwnsArrowKeyDown(keyCode:firstResponderHasMarkedText:flags:)``.
func shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsEditableTextView: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsEditableTextView else { return false }
    return standaloneTextResponderOwnsArrowKeyDown(
        keyCode: keyCode,
        firstResponderHasMarkedText: firstResponderHasMarkedText,
        flags: flags
    )
}

/// Ctrl-N / Ctrl-P navigate the mention-completion popover (and emacs-style line
/// movement) inside the terminal textbox. Like plain arrows, the window's
/// `performKeyEquivalent` claims these before they reach the textbox `keyDown`, so
/// they must be routed to the first responder explicitly. Scoped to the textbox so
/// terminal/browser Ctrl-N/Ctrl-P are unaffected.
func shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
    charactersIgnoringModifiers: String?,
    firstResponderIsTextBoxInput: Bool,
    firstResponderHasMarkedText: Bool = false,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard firstResponderIsTextBoxInput else { return false }
    guard !firstResponderHasMarkedText else { return false }

    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    guard normalizedFlags == [.control] else { return false }
    let key = charactersIgnoringModifiers?.lowercased()
    return key == "n" || key == "p"
}

func shouldToggleMainWindowFullScreenForCommandControlFShortcut(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> Bool {
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    guard normalizedFlags == [.command, .control] else { return false }
    let normalizedChars = chars.lowercased()
    if normalizedChars == "f" {
        return true
    }
    let charsAreControlSequence = !normalizedChars.isEmpty
        && normalizedChars.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
    if !normalizedChars.isEmpty && !charsAreControlSequence {
        return false
    }

    // Fallback to layout translation only when characters are unavailable (for
    // synthetic/key-equivalent paths that can report an empty string).
    if let translatedCharacter = layoutCharacterProvider(keyCode, flags), !translatedCharacter.isEmpty {
        return translatedCharacter == "f"
    }

    // Keep ANSI fallback as a final safety net when layout translation is unavailable.
    return keyCode == 3
}

func shouldRouteCommandPaletteSelectionNavigation(
    delta: Int?,
    isInteractive: Bool,
    usesInlineTextHandling: Bool
) -> Bool {
    guard delta != nil, isInteractive else { return false }
    return !usesInlineTextHandling
}

func shouldConsumeShortcutWhileCommandPaletteVisible(
    isCommandPaletteVisible: Bool,
    normalizedFlags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Bool {
    guard isCommandPaletteVisible else { return false }

    // Escape dismisses the palette, and must not leak through to the
    // underlying terminal or browser content.
    if normalizedFlags.isEmpty, keyCode == 53 {
        return true
    }

    guard normalizedFlags.contains(.command) else { return false }

    let normalizedChars = chars.lowercased()

    if normalizedFlags == [.command] {
        if normalizedChars == "a"
            || normalizedChars == "c"
            || normalizedChars == "v"
            || normalizedChars == "x"
            || normalizedChars == "z"
            || normalizedChars == "y" {
            return false
        }

        switch keyCode {
        case 49, 51, 117, 123, 124:
            return false
        default:
            break
        }
    }

    if normalizedFlags == [.command, .shift], normalizedChars == "z" {
        return false
    }

    return true
}

func shouldSubmitCommandPaletteWithReturn(
    keyCode: UInt16,
    flags: NSEvent.ModifierFlags,
    mode: String
) -> Bool {
    guard keyCode == 36 || keyCode == 76 else { return false }
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    if normalizedFlags.isEmpty {
        return true
    }
    if normalizedFlags == [.shift] {
        return mode != "workspace_description_input"
    }
    return false
}

func commandPaletteFieldEditorHasMarkedText(in window: NSWindow) -> Bool {
    if let editor = window.firstResponder as? NSTextView {
        return editor.hasMarkedText()
    }
    if let textField = window.firstResponder as? NSTextField,
       let editor = textField.currentEditor() as? NSTextView {
        return editor.hasMarkedText()
    }
    return false
}

func shouldHandleCommandPaletteShortcutEvent(
    _ event: NSEvent,
    paletteWindow: NSWindow?
) -> Bool {
    guard let paletteWindow else { return false }
    if let eventWindow = event.window {
        return eventWindow === paletteWindow
    }
    let eventWindowNumber = event.windowNumber
    if eventWindowNumber > 0 {
        return eventWindowNumber == paletteWindow.windowNumber
    }
    if let keyWindow = NSApp.keyWindow {
        return keyWindow === paletteWindow
    }
    return false
}

enum BrowserZoomShortcutAction: Equatable {
    case zoomIn
    case zoomOut
    case reset
}

func browserZoomShortcutAction(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> BrowserZoomShortcutAction? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let hasCommand = normalizedFlags.contains(.command)
    let hasOnlyCommandAndOptionalShift = hasCommand && normalizedFlags.isDisjoint(with: [.control, .option])

    guard hasOnlyCommandAndOptionalShift else { return nil }
    let keys = browserZoomShortcutKeyCandidates(
        chars: chars,
        literalChars: literalChars,
        keyCode: keyCode
    )

    if keys.contains("=") || keys.contains("+") || keyCode == 24 || keyCode == 69 { // kVK_ANSI_Equal / kVK_ANSI_KeypadPlus
        return .zoomIn
    }

    if keys.contains("-") || keys.contains("_") || keyCode == 27 || keyCode == 78 { // kVK_ANSI_Minus / kVK_ANSI_KeypadMinus
        return .zoomOut
    }

    if keys.contains("0") || keyCode == 29 || keyCode == 82 { // kVK_ANSI_0 / kVK_ANSI_Keypad0
        return .reset
    }

    return nil
}

func browserZoomShortcutKeyCandidates(
    chars: String,
    literalChars: String?,
    keyCode: UInt16
) -> Set<String> {
    var keys: Set<String> = [chars.lowercased()]

    if let literalChars, !literalChars.isEmpty {
        keys.insert(literalChars.lowercased())
    }

    if let layoutChar = KeyboardLayout.character(forKeyCode: keyCode), !layoutChar.isEmpty {
        keys.insert(layoutChar)
    }

    return keys
}

func shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
    firstResponderIsWindow: Bool,
    hostedSize: CGSize,
    hostedHiddenInHierarchy: Bool,
    hostedAttachedToWindow: Bool
) -> Bool {
    guard firstResponderIsWindow else { return false }
    let tinyGeometry = hostedSize.width <= 1 || hostedSize.height <= 1
    return tinyGeometry || hostedHiddenInHierarchy || !hostedAttachedToWindow
}
func focusedTerminalKeyRepairNeeded(
    responderIsWindow: Bool,
    responderHasViableKeyRoutingOwner: Bool,
    responderMatchesPreferredKeyboardFocus: Bool
) -> Bool {
    responderIsWindow || !responderHasViableKeyRoutingOwner || !responderMatchesPreferredKeyboardFocus
}
func shouldRepairFocusedTerminalCommandEquivalentInputs(
    flags: NSEvent.ModifierFlags,
    responderIsWindow: Bool,
    responderHasViableKeyRoutingOwner: Bool,
    responderMatchesPreferredKeyboardFocus: Bool
) -> Bool {
    let normalizedFlags = flags.intersection(.deviceIndependentFlagsMask)
    guard normalizedFlags.contains(.command) else { return false }
    // The caller filters foreign controls first. A live terminal responder is
    // viable only for the pane whose preferred keyboard focus it matches.
    return responderIsWindow
        || !responderHasViableKeyRoutingOwner
        || !responderMatchesPreferredKeyboardFocus
}
func shouldRouteTerminalFontZoomShortcutToGhostty(
    firstResponderIsGhostty: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    literalChars: String? = nil
) -> Bool {
    guard firstResponderIsGhostty else { return false }
    return browserZoomShortcutAction(
        flags: flags,
        chars: chars,
        keyCode: keyCode,
        literalChars: literalChars
    ) != nil
}
// Main-actor isolated: TerminalSurface.searchState carries the legacy
// main-thread-only contract as compiler-enforced isolation after the
// CmuxTerminal lift; both callers (TabManager, overlay tests) are @MainActor.
@MainActor
@discardableResult
func startOrFocusTerminalSearch(
    _ terminalSurface: TerminalSurface,
    initialNeedle: String = "",
    searchFocusNotifier: @escaping (TerminalSurface) -> Void = {
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: $0)
    }
) -> Bool {
    if terminalSurface.searchState != nil {
        if !initialNeedle.isEmpty { terminalSurface.searchState?.needle = initialNeedle }
        searchFocusNotifier(terminalSurface)
        return true
    }
    if terminalSurface.performExplicitInputBindingAction("start_search") {
        DispatchQueue.main.async { [weak terminalSurface] in
            guard let terminalSurface else { return }
            if let searchState = terminalSurface.searchState {
                if !initialNeedle.isEmpty { searchState.needle = initialNeedle }
            } else {
                terminalSurface.searchState = TerminalSurface.SearchState(needle: initialNeedle)
            }
            searchFocusNotifier(terminalSurface)
        }
        return true
    }
    terminalSurface.searchState = TerminalSurface.SearchState(needle: initialNeedle)
    searchFocusNotifier(terminalSurface)
    return true
}

/// Let AppKit own native Cmd+` window cycling so key-window changes do not
/// re-enter our direct-to-menu shortcut path.
func shouldRouteCommandEquivalentDirectlyToMainMenu(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command) else { return false }

    let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
    if event.keyCode == 50,
       normalizedFlags == [.command] || normalizedFlags == [.command, .shift] {
        return false
    }

    return true
}

func cmuxIsWebInspectorClassName(_ className: String) -> Bool {
    className.contains("WKInspector") || className.contains("WebInspector")
}

func cmuxIsWebInspectorObject(_ object: NSObject) -> Bool {
    cmuxIsWebInspectorClassName(String(describing: type(of: object))) ||
        cmuxIsWebInspectorClassName(NSStringFromClass(type(of: object)))
}

func cmuxIsLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }
    if cmuxIsWebInspectorObject(responder) {
        return true
    }
    guard let view = responder as? NSView else { return false }
    var node: NSView? = view
    var hops = 0
    while let current = node, hops < 64 {
        if cmuxIsWebInspectorObject(current) {
            return true
        }
        node = current.superview
        hops += 1
    }
    return false
}

extension NSResponder {
    /// Strict owner lookup for direct Ghostty responder chains, sidebar ownership,
    /// and call sites that must not treat hosted surface descendants as Ghostty.
    func cmuxStrictOwningGhosttyView() -> GhosttyNSView? {
        cmuxOwningGhosttyView(for: self, includingHostedSurfaceDescendants: false)
    }

    /// Terminal focus lookup for AppKit responders hosted below
    /// GhosttySurfaceScrollView, where keyboard focus still belongs to Ghostty.
    func cmuxTerminalFocusOwningGhosttyView() -> GhosttyNSView? {
        cmuxOwningGhosttyView(for: self, includingHostedSurfaceDescendants: true)
    }

    /// Terminal key-equivalent routing lookup; hosted surface descendants should
    /// count as terminal-owned so app shortcuts can be repaired or forwarded.
    func cmuxTerminalKeyEquivalentOwningGhosttyView() -> GhosttyNSView? {
        cmuxTerminalFocusOwningGhosttyView()
    }
}

extension Optional where Wrapped: NSResponder {
    func cmuxStrictOwningGhosttyView() -> GhosttyNSView? {
        self?.cmuxStrictOwningGhosttyView()
    }

    func cmuxTerminalFocusOwningGhosttyView() -> GhosttyNSView? {
        self?.cmuxTerminalFocusOwningGhosttyView()
    }

    func cmuxTerminalKeyEquivalentOwningGhosttyView() -> GhosttyNSView? {
        self?.cmuxTerminalKeyEquivalentOwningGhosttyView()
    }
}

private func cmuxOwningGhosttyView(
    for responder: NSResponder?,
    includingHostedSurfaceDescendants: Bool
) -> GhosttyNSView? {
    guard let responder else { return nil }
    if let ghosttyView = responder as? GhosttyNSView {
        return ghosttyView
    }

    if let view = responder as? NSView,
       let ghosttyView = cmuxOwningGhosttyView(
           for: view,
           includingHostedSurfaceDescendants: includingHostedSurfaceDescendants
       ) {
        return ghosttyView
    }

    if let textView = responder as? NSTextView {
        if textView.isFieldEditor,
           let ownerView = cmuxFieldEditorOwnerView(textView),
           let ghosttyView = cmuxOwningGhosttyView(
               for: ownerView,
               includingHostedSurfaceDescendants: includingHostedSurfaceDescendants
           ) {
            return ghosttyView
        }
    }

    var current = responder.nextResponder
    while let next = current {
        if let ghosttyView = next as? GhosttyNSView {
            return ghosttyView
        }
        if let view = next as? NSView,
           let ghosttyView = cmuxOwningGhosttyView(
               for: view,
               includingHostedSurfaceDescendants: includingHostedSurfaceDescendants
           ) {
            return ghosttyView
        }
        current = next.nextResponder
    }

    return nil
}

private func cmuxOwningGhosttyView(
    for view: NSView,
    includingHostedSurfaceDescendants: Bool
) -> GhosttyNSView? {
    if let ghosttyView = view as? GhosttyNSView {
        return ghosttyView
    }

    var current: NSView? = view.superview
    while let candidate = current {
        if let ghosttyView = candidate as? GhosttyNSView {
            return ghosttyView
        }
        if includingHostedSurfaceDescendants,
           let hostedView = candidate as? GhosttySurfaceScrollView {
            return hostedView.surfaceView
        }
        current = candidate.superview
    }

    return nil
}

func cmuxFieldEditorOwnerView(_ editor: NSTextView) -> NSView? {
    guard editor.isFieldEditor else { return nil }
    if let owner = cmuxTrackedFindFieldEditorOwner(editor) { return owner }
    var current = editor.nextResponder
    while let next = current {
        if let view = next as? NSView {
            return view
        }
        current = next.nextResponder
    }

    return editor.superview
}

func shouldSuppressWindowMoveForFolderDrag(hitView: NSView?) -> Bool {
    var candidate = hitView
    while let view = candidate {
        if view is DraggableFolderNSView {
            return true
        }
        candidate = view.superview
    }
    return false
}

func shouldSuppressWindowMoveForFolderDrag(window: NSWindow, event: NSEvent) -> Bool {
    guard event.type == .leftMouseDown,
          window.isMovable,
          let contentView = window.contentView else {
        return false
    }

    let hitView = contentView.cmuxHitTest(windowPoint: event.locationInWindow)
    return shouldSuppressWindowMoveForFolderDrag(hitView: hitView)
}

enum WindowMoveSuppressionReason: String {
    case folderDrag
    case bonsplitPaneTabDrag
}

func shouldSuppressWindowMoveForBonsplitPaneTabDrag(window: NSWindow, event: NSEvent) -> Bool {
    guard event.type == .leftMouseDown else {
        return false
    }

    return BonsplitTabItemHitRegionRegistry.containsWindowPoint(event.locationInWindow, in: window)
}

func windowMoveSuppressionReason(window: NSWindow, event: NSEvent) -> WindowMoveSuppressionReason? {
    if shouldSuppressWindowMoveForFolderDrag(window: window, event: event) {
        return .folderDrag
    }
    if shouldSuppressWindowMoveForBonsplitPaneTabDrag(window: window, event: event) {
        return .bonsplitPaneTabDrag
    }
    return nil
}

func beginOrContinueWindowMoveSuppressionSequenceForEvent(
    window: NSWindow,
    event: NSEvent,
    pressedMouseButtons: Int = NSEvent.pressedMouseButtons
) -> WindowMoveSuppressionReason? {
    if let activeReason = activeWindowMoveSuppressionSequenceReason(window: window) {
        if event.type == .leftMouseDown {
            _ = finishWindowMoveSuppressionSequence(window: window)
        } else if event.type == .leftMouseUp || event.type == .leftMouseDragged || (pressedMouseButtons & 0x1) != 0 {
            ensureWindowMoveSuppressionSequenceIsImmovable(window: window)
            return activeReason
        } else {
            _ = finishWindowMoveSuppressionSequence(window: window)
        }
    }

    guard let reason = windowMoveSuppressionReason(window: window, event: event) else {
        return nil
    }
    return beginWindowMoveSuppressionSequence(window: window, reason: reason)
}

func shouldFinishWindowMoveSuppressionSequenceAfterDispatch(window: NSWindow, event: NSEvent) -> Bool {
    activeWindowMoveSuppressionSequenceReason(window: window) != nil && event.type == .leftMouseUp
}
