import AppKit
import ApplicationServices

class SelectionManager {
    static let shared = SelectionManager()

    func getSelectedText(from app: NSRunningApplication? = nil, allowClipboardFallback: Bool = true) -> String? {
        #if APPSTORE
        return nil
        #else
        let currentBundleID = ContextDetector.shared.currentBundleID
        let targetApp: NSRunningApplication?

        if let app = app {
            targetApp = app
        } else {
            if let trackedApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == currentBundleID }) {
                targetApp = trackedApp
            } else if let frontmost = NSWorkspace.shared.frontmostApplication,
                      frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
                targetApp = frontmost
            } else {
                targetApp = nil
            }
        }

        guard let app = targetApp else { return nil }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""

        // 1. Finder uses AppleScript to return selected file names
        if bundleID == "com.apple.finder" {
            if let text = getFinderSelection() { return text }
        }

        // 2. Accessibility API — works for native apps, browsers, Electron, terminals, etc.
        //    PopClip and similar tools rely on this as the primary method.
        if PermissionManager.shared.canUseAccessibility() {
            let appElement = AXUIElementCreateApplication(pid)

            // Try focused element first (fastest path)
            var focusedElement: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
               let element = focusedElement {
                if let text = findSelectedText(in: element as! AXUIElement) { return text }
            }

            // Try focused window (catches web views and complex layouts)
            var focusedWindow: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let window = focusedWindow {
                if let text = findSelectedText(in: window as! AXUIElement) { return text }
            }

            // Try app element root (deep recursive, last AX resort)
            if let text = findSelectedText(in: appElement) { return text }
        }

        guard allowClipboardFallback else { return nil }

        // 3. Cmd+C fallback — for apps that don't expose selection via AX
        //    (e.g. some Electron apps, games, remote desktop clients).
        //    The clipboard is always restored afterwards; invisible to the user.
        return forceCaptureSelection(for: app)
        #endif
    }

    // MARK: - Finder

    private func getFinderSelection() -> String? {
        let script = "tell application \"Finder\" to get selection"
        return runAppleScript(script)
    }

    // MARK: - Accessibility helpers

    /// Tries kAXSelectedText on `element`, then recursively on its children.
    private func findSelectedText(in element: AXUIElement) -> String? {
        // Direct attribute check (fastest)
        for attr in [kAXSelectedTextAttribute as String, "AXSelectedText"] {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty {
                return text
            }
        }
        return findSelectedTextRecursive(in: element, depth: 0)
    }

    private func findSelectedTextRecursive(in element: AXUIElement, depth: Int) -> String? {
        if depth > 20 { return nil }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childArray = children as? [AXUIElement] else { return nil }

        for child in childArray {
            for attr in [kAXSelectedTextAttribute as String, "AXSelectedText"] {
                var value: AnyObject?
                if AXUIElementCopyAttributeValue(child, attr as CFString, &value) == .success,
                   let text = value as? String, !text.isEmpty {
                    return text
                }
            }
            if let deep = findSelectedTextRecursive(in: child, depth: depth + 1) {
                return deep
            }
        }
        return nil
    }

    // MARK: - Cmd+C fallback

    private var lastCommandCTime: Date = .distantPast

    #if !APPSTORE
    /// Simulates Cmd+C into the target app's PID, captures the clipboard,
    /// then restores the original clipboard contents.
    /// Used as a last resort for apps that don't expose AX selection text.
    private func forceCaptureSelection(for app: NSRunningApplication) -> String? {
        // Skip fallback for Apple system apps, as they perfectly support Accessibility API.
        // If AX returns nil for them, it means nothing is selected. Simulating Cmd+C
        // in these apps when there is no selection causes a system alert beep.
        if app.bundleIdentifier?.hasPrefix("com.apple.") == true {
            return nil
        }
        
        // Enforce a cooldown of 2 seconds to avoid flickering menu bars in apps like VSCode
        if Date().timeIntervalSince(lastCommandCTime) < 2.0 {
            return nil
        }
        lastCommandCTime = Date()
        
        let originalContent = NSPasteboard.general.string(forType: .string)
        let originalCount   = NSPasteboard.general.changeCount

        let source  = CGEventSource(stateID: .combinedSessionState)
        let cmdKey: CGKeyCode = 0x37  // ⌘
        let cKey:   CGKeyCode = 0x08  // C

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        let cDown   = CGEvent(keyboardEventSource: source, virtualKey: cKey,   keyDown: true)
        let cUp     = CGEvent(keyboardEventSource: source, virtualKey: cKey,   keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)

        cmdDown?.flags = .maskCommand
        cDown?.flags   = .maskCommand
        cUp?.flags     = .maskCommand

        let pid = app.processIdentifier
        cmdDown?.postToPid(pid)
        cDown?.postToPid(pid)
        cUp?.postToPid(pid)
        cmdUp?.postToPid(pid)

        // Poll up to ~200 ms for clipboard change
        for _ in 0..<4 {
            usleep(50_000)
            if NSPasteboard.general.changeCount != originalCount {
                let captured = NSPasteboard.general.string(forType: .string)

                // Restore original clipboard
                NSPasteboard.general.clearContents()
                if let old = originalContent {
                    NSPasteboard.general.setString(old, forType: .string)
                }

                if let text = captured, !text.isEmpty { return text }
                break
            }
        }
        return nil
    }
    #endif

    // MARK: - getSelectedTextBounds

    func getSelectedTextBounds(for app: NSRunningApplication) -> CGRect? {
        #if APPSTORE
        return nil
        #else
        guard PermissionManager.shared.canUseAccessibility() else { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else { return nil }
        let element = focusedElement as! AXUIElement

        for attr in [kAXSelectedTextRangeAttribute as String, "AXSelectedTextRange"] {
            var rangeValue: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attr as CFString, &rangeValue) == .success else { continue }
            var boundsValue: AnyObject?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue!, &boundsValue) == .success else { continue }
            if CFGetTypeID(boundsValue!) == AXValueGetTypeID() {
                let axValue = boundsValue as! AXValue
                var rect = CGRect.zero
                if AXValueGetValue(axValue, .cgRect, &rect) { return rect }
            }
        }
        return nil
        #endif
    }

    // MARK: - AppleScript helper

    private func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        if let obj = NSAppleScript(source: script) {
            let output = obj.executeAndReturnError(&error)
            if error == nil { return output.stringValue }
        }
        return nil
    }
}
