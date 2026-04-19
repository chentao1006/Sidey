import AppKit
import ApplicationServices

class SelectionManager {
    static let shared = SelectionManager()
    
    func getSelectedText(from app: NSRunningApplication? = nil) -> String? {
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
        
        // 1. Try Specialized Fallbacks (AppleScript) for specific apps (non-disruptive)
        if bundleID == "com.apple.Safari" {
            if let text = getBrowserSelection(bundleID: bundleID) { return text }
        } else if bundleID == "com.google.Chrome" || bundleID == "com.google.Chrome.canary" || bundleID == "com.microsoft.edgemac" {
            if let text = getBrowserSelection(bundleID: bundleID) { return text }
        } else if bundleID == "com.apple.finder" {
            if let text = getFinderSelection() { return text }
        }
        
        // 2. Try Enhanced Accessibility Search (standard and deep)
        // 2. Try Enhanced Accessibility Search (standard and deep)
        if PermissionManager.shared.canUseAccessibility() {
            let appElement = AXUIElementCreateApplication(pid)
            for _ in 0..<3 { // 3 retries with small delays
                var focusedElement: AnyObject?
                if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success {
                    if let text = findSelectedText(in: focusedElement as! AXUIElement) { return text }
                }
                
                if let text = findSelectedText(in: appElement) { return text }
                
                var focusedWindow: AnyObject?
                if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success {
                    if let text = findSelectedText(in: focusedWindow as! AXUIElement) { return text }
                }
                
                usleep(50000) // 50ms
            }
        }
        
        // 3. Fallback: Force Capture via simulated Cmd+C (non-disruptive, PID-targeted)
        #if !APPSTORE
        return forceCaptureSelection(for: app)
        #else
        return nil
        #endif
    }
    
    private func getBrowserSelection(bundleID: String) -> String? {
        let isSafari = bundleID == "com.apple.Safari"
        let appName = isSafari ? "Safari" : (bundleID.contains("Chrome") ? "Google Chrome" : "Microsoft Edge")
        let javascript = "window.getSelection().toString()"
        
        // Safari and Chrome have slightly different AppleScript syntax for JS
        let script = isSafari ? 
            "tell application \"Safari\" to do JavaScript \"\(javascript)\" in document 1" :
            "tell application \"\(appName)\" to tell active tab of window 1 to return execute javascript \"\(javascript)\""
        
        return runAppleScript(script)
    }
    
    private func getFinderSelection() -> String? {
        let script = "tell application \"Finder\" to get selection" // Returns list of files
        return runAppleScript(script)
    }
    
    #if !APPSTORE
    private func forceCaptureSelection(for app: NSRunningApplication) -> String? {
        let originalContent = NSPasteboard.general.string(forType: .string)
        let originalCount = NSPasteboard.general.changeCount
        
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdKey: CGKeyCode = 0x37 // Command key
        let cKey: CGKeyCode = 0x08 // 'C' key
        
        // Post events directly to the target app PID
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        
        cmdDown?.flags = .maskCommand
        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand
        
        let pid = app.processIdentifier
        cmdDown?.postToPid(pid)
        cDown?.postToPid(pid)
        cUp?.postToPid(pid)
        cmdUp?.postToPid(pid)
        
        // Wait briefly for clipboard update
        for _ in 0..<4 {
            usleep(50000)
            if NSPasteboard.general.changeCount != originalCount {
                let text = NSPasteboard.general.string(forType: .string)
                
                // RESTORE original clipboard
                if let old = originalContent {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(old, forType: .string)
                }
                
                if let text = text, !text.isEmpty {
                    return text
                }
                break
            }
        }
        return nil
    }
    #endif
    
    private func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let output = scriptObject.executeAndReturnError(&error)
            if error == nil {
                return output.stringValue
            }
        }
        return nil
    }
    
    private func findSelectedText(in element: AXUIElement) -> String? {
        let attributes = [
            kAXSelectedTextAttribute as String,
            "AXSelectedText",
            "AXSelectedTextMarkerRange",
            "AXSelectedTextRange"
        ]
        for attr in attributes {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success {
                if let text = value as? String, !text.isEmpty {
                    return text
                }
                
                // If it's a marker range (Safari/Mail), we can't cast to String. 
                // We need to use kAXStringForRangeParameterizedAttribute if we had the text area,
                // but let's try the recursive search which often finds the string on a child.
            }
        }
        return findSelectedTextRecursive(in: element, depth: 0)
    }
    
    private func findSelectedTextRecursive(in element: AXUIElement, depth: Int) -> String? {
        if depth > 20 { return nil }
        
        var children: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let childrenArray = children as? [AXUIElement] {
            for child in childrenArray {
                // Check multiple attributes at each level for efficiency
                let attributes = [kAXSelectedTextAttribute, "AXSelectedText"]
                for attr in attributes {
                    var selectedText: AnyObject?
                    if AXUIElementCopyAttributeValue(child, attr as CFString, &selectedText) == .success,
                       let text = selectedText as? String, !text.isEmpty {
                        return text
                    }
                }
                
                if let deepMatch = findSelectedTextRecursive(in: child, depth: depth + 1) {
                    return deepMatch
                }
            }
        }
        return nil
    }
    
    func getSelectedTextBounds(for app: NSRunningApplication) -> CGRect? {
        guard PermissionManager.shared.canUseAccessibility() else { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        
        var focusedElement: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success {
            let element = focusedElement as! AXUIElement
            
            // Try different range attributes
            let rangeAttributes = [
                kAXSelectedTextRangeAttribute,
                "AXSelectedTextRange"
            ]
            
            for attr in rangeAttributes {
                var rangeValue: AnyObject?
                if AXUIElementCopyAttributeValue(element, attr as CFString, &rangeValue) == .success {
                    var boundsValue: AnyObject?
                    if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue!, &boundsValue) == .success {
                        if CFGetTypeID(boundsValue!) == AXValueGetTypeID() {
                            let axValue = boundsValue as! AXValue
                            var rect = CGRect.zero
                            if AXValueGetValue(axValue, .cgRect, &rect) {
                                return rect
                            }
                        }
                    }
                }
            }
        }
        return nil
    }
}

