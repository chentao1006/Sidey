import AppKit
import Combine
import ApplicationServices

enum DockingPosition: String, CaseIterable, Identifiable {
    case right = "Right"
    case left = "Left"
    case auto = "Auto"
    var id: String { self.rawValue }
}

class DockingManager: ObservableObject {
    static let shared = DockingManager()
    
    @Published var activeWindowFrame: NSRect?
    @Published var isAdsorptionEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isAdsorptionEnabled, forKey: "isAdsorptionEnabled")
            if isAdsorptionEnabled, let bundleID = lastObservedBundleID {
                restoreAssistantState(for: bundleID)
            }
            updatePositions()
        }
    }
    
    @Published var isIconVisible: Bool = true {
        didSet {
            UserDefaults.standard.set(isIconVisible, forKey: "isIconVisible")
            if !isIconVisible {
                iconWindow?.orderOut(nil)
            } else {
                updatePositions()
            }
        }
    }
    
    @Published var dockingPosition: DockingPosition = .right {
        didSet {
            UserDefaults.standard.set(dockingPosition.rawValue, forKey: "adsorptionPosition")
            updatePositions()
        }
    }
    
    var iconWindow: NSWindow?
    var assistantWindow: NSWindow?
    
    private var appAssistantStates: [String: Bool] = [:]
    private(set) var lastObservedBundleID: String?
    private var isSideyFocused: Bool = false
    
    // Accessibility API support
    private var axObserver: AXObserver?
    private var currentObservedPID: pid_t?
    
    private var timer: Timer?
    private var persistentTargetPID: Int32?
    private var lastFoundWindowTime: Date = .distantPast
    private var currentTargetScreen: NSScreen? // Stability filter for multi-monitor tracking
    @Published var isIconHovered: Bool = false
    
    private func setupDefaults() {
        if UserDefaults.standard.object(forKey: "isAdsorptionEnabled") == nil {
            self.isAdsorptionEnabled = true
        } else {
            self.isAdsorptionEnabled = UserDefaults.standard.bool(forKey: "isAdsorptionEnabled")
        }
        
        if UserDefaults.standard.object(forKey: "isIconVisible") == nil {
            self.isIconVisible = true
        } else {
            self.isIconVisible = UserDefaults.standard.bool(forKey: "isIconVisible")
        }
        
        if let states = UserDefaults.standard.dictionary(forKey: "appAssistantStates") as? [String: Bool] {
            self.appAssistantStates = states
        }
    }
    
    private init() {
        setupDefaults()
        
        if let pos = UserDefaults.standard.string(forKey: "adsorptionPosition"),
           let dockingPos = DockingPosition(rawValue: pos) {
            self.dockingPosition = dockingPos
        }
        
        startTracking()
        
        // Immediate response to focus changes
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshActiveWindowFrame()
        }
    }
    
    func startTracking() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshActiveWindowFrame()
        }
    }
    
    func refreshActiveWindowFrame() {
        guard isAdsorptionEnabled || isIconVisible else { 
            if activeWindowFrame != nil {
                DispatchQueue.main.async {
                    self.activeWindowFrame = nil
                    self.iconWindow?.orderOut(nil)
                    self.assistantWindow?.orderOut(nil)
                }
            }
            return 
        }
        
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier ?? ""
        let processName = frontApp?.localizedName ?? ""
        let isSideyFocused = bundleID == Bundle.main.bundleIdentifier
        
        // Ignore system permission dialogs and system settings
        let systemBlacklist = [
            "com.apple.universalaccessd",
            "com.apple.accessibility.universalAccessAuthWarn",
            "universalAccessAuthWarn",
            "com.apple.SecurityAgent",
            "com.apple.notificationcenterui",
            "com.apple.ScreenReader",
            "com.apple.systemevents",
            "com.apple.controlcenter",
            "com.apple.loginwindow",
            "com.apple.QuickLookUIService",
            "QuickLookUIService"
        ]
        
        let isBlacklisted = systemBlacklist.contains { $0.lowercased() == bundleID.lowercased() } ||
                           systemBlacklist.contains { $0.lowercased() == processName.lowercased() } ||
                           bundleID.lowercased().contains("universalaccess") ||
                           processName.lowercased().contains("universalaccess")
        
        // Update persistent target ONLY if valid non-Sidey app and not a system/blacklisted one
        if !isSideyFocused && !isBlacklisted && !bundleID.isEmpty {
            if let pid = frontApp?.processIdentifier {
                if pid != persistentTargetPID {
                    persistentTargetPID = pid
                    DebugLogger.shared.log("New target app: \(processName) (\(bundleID)) PID: \(pid)")
                    
                    // Set up Accessibility Observer if needed
                    if pid != currentObservedPID && PermissionManager.shared.checkAccessibility() {
                        setupAccessibilityObserver(for: pid)
                    }
                }
            }
            
            // App switch detection
            if bundleID != lastObservedBundleID {
                lastObservedBundleID = bundleID
                restoreAssistantState(for: bundleID)
            }
        }
        
        var cocoaRect: NSRect?
        var foundWindow = false
        
        // Priority 1: Accessibility API (Most accurate, no shadows)
        if PermissionManager.shared.checkAccessibility(), let pid = persistentTargetPID {
            let appElement = AXUIElementCreateApplication(pid)
            var focusedWindow: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let window = focusedWindow {
                
                var positionRef: AnyObject?
                var sizeRef: AnyObject?
                
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &positionRef) == .success,
                   AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let posVal = positionRef, 
                   let sizeVal = sizeRef {
                    
                    var position = CGPoint.zero
                    var size = CGSize.zero
                    
                    if AXValueGetValue(posVal as! AXValue, .cgPoint, &position) &&
                       AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) {
                        
                        let cgRect = CGRect(origin: position, size: size)
                        cocoaRect = convertCGRectToCocoa(cgRect)
                        foundWindow = true
                    }
                }
            }
        }
        
        // Priority 2: CGWindowList Fallback
        if !foundWindow {
            guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
                return
            }
            
            let sortedWindowList = windowList.sorted { 
                ($0[kCGWindowLayer as String] as? Int ?? Int.max) < ($1[kCGWindowLayer as String] as? Int ?? Int.max)
            }
            
            for winInfo in sortedWindowList {
                guard let ownerPID = winInfo[kCGWindowOwnerPID as String] as? Int32,
                      ownerPID == persistentTargetPID,
                      let bounds = winInfo[kCGWindowBounds as String] as? [String: Any],
                      let x = bounds["X"] as? CGFloat,
                      let y = bounds["Y"] as? CGFloat,
                      let w = bounds["Width"] as? CGFloat,
                      let h = bounds["Height"] as? CGFloat,
                      let layer = winInfo[kCGWindowLayer as String] as? Int,
                      layer >= 0 && layer <= 100,
                      w > 100, h > 100 else { continue }
                
                let winName = winInfo[kCGWindowName as String] as? String ?? ""
                let ownerName = winInfo[kCGWindowOwnerName as String] as? String ?? ""
                let alpha = winInfo[kCGWindowAlpha as String] as? CGFloat ?? 1.0
                
                if alpha == 0 { continue }
                if winName == "Desktop" || winName == "Wallpaper" || winName == "Focus Window" { continue }
                if ownerName == "Finder" && winName.isEmpty { continue }

                let cgRect = CGRect(x: x, y: y, width: w, height: h)
                cocoaRect = convertCGRectToCocoa(cgRect)
                foundWindow = true
                break
            }
        }
        
        DispatchQueue.main.async {
            if let cocoaRect = cocoaRect, foundWindow {
                self.activeWindowFrame = cocoaRect
                self.updatePositions()
                self.lastFoundWindowTime = Date()
            } else {
                if self.activeWindowFrame != nil {
                    let timeSinceLastSeen = Date().timeIntervalSince(self.lastFoundWindowTime)
                    if timeSinceLastSeen > 0.8 {
                        self.activeWindowFrame = nil
                        self.iconWindow?.orderOut(nil)
                        self.assistantWindow?.orderOut(nil)
                        DebugLogger.shared.log("Losing window tracking for PID: \(self.persistentTargetPID ?? 0)")
                    }
                }
            }
        }
    }
    
    func updatePositions() {
        guard let activeFrame = activeWindowFrame else { return }
        if !isAdsorptionEnabled && !isIconVisible {
            iconWindow?.orderOut(nil)
            assistantWindow?.orderOut(nil)
            return
        }
        
        let screens = NSScreen.screens
        var largestArea: CGFloat = 0
        var foundTargetScreen = screens.first ?? NSScreen.main
        
        for screen in screens {
            let intersection = screen.frame.intersection(activeFrame)
            let area = intersection.width * intersection.height
            if area > largestArea {
                largestArea = area
                foundTargetScreen = screen
            }
        }
        
        if largestArea == 0 { foundTargetScreen = NSScreen.main }
        
        if let current = currentTargetScreen {
            let currentIntersection = current.frame.intersection(activeFrame)
            let currentArea = currentIntersection.width * currentIntersection.height
            if largestArea > currentArea + 1000 {
                currentTargetScreen = foundTargetScreen
            }
        } else {
            currentTargetScreen = foundTargetScreen
        }
        
        let stableScreen = currentTargetScreen ?? foundTargetScreen
        let bundleID = lastObservedBundleID ?? ""
        let isAssistantShowing = assistantWindow?.isVisible ?? false
        
        // Manual closure and opening are now handled via AppDelegate signals
        // to avoid race conditions during focus transitions.
        
        let shouldShowAssistant = isAdsorptionEnabled && (appAssistantStates[bundleID] ?? false)
        
        // Show icon if enabled in settings AND (Assistant is not showing OR adsorption is disabled for this app)
        let actualIconShow = isIconVisible && !isAssistantShowing && (!isAdsorptionEnabled || !shouldShowAssistant)
        
        updateIconPosition(activeFrame: activeFrame, screen: stableScreen, show: actualIconShow)
        
        if isAdsorptionEnabled {
            updateAssistantPosition(activeFrame: activeFrame, screen: stableScreen, show: shouldShowAssistant)
        }
    }
    
    func updateIconPosition(activeFrame: NSRect, screen: NSScreen? = nil, show: Bool = true) {
        guard let iconWin = iconWindow else { return }
        if !show { iconWin.orderOut(nil); return }
            
        let screenFrame = screen?.frame ?? .zero
        let iconWidth: CGFloat = 120 
        let iconHeight: CGFloat = 700 
        let topOffset: CGFloat = 40 // Move down from top boundary
        
        var winX: CGFloat = 0
        var isActuallyRight = true
        
        switch dockingPosition {
        case .right:
            winX = activeFrame.maxX
            isActuallyRight = true
        case .left:
            winX = activeFrame.minX - iconWidth
            isActuallyRight = false
        case .auto:
            let appMidX = activeFrame.midX
            let screenMidX = screenFrame.midX
            if appMidX > screenMidX {
                winX = activeFrame.maxX
                isActuallyRight = true
            } else {
                winX = activeFrame.minX - iconWidth
                isActuallyRight = false
            }
        }
        
        if isActuallyRight {
            // Icon is at the LEADING (left) edge of the 120pt-wide icon window.
            // We only clamp winX (the LEFT edge of the window) so the ICON (first 40pt) stays on screen.
            // We allow the rest of the 120pt window (which is mostly empty/transparent) to go off-screen.
            winX = max(screenFrame.minX, min(screenFrame.maxX - 42, winX))
        } else {
            // Icon is at the TRAILING (right) edge of the 120pt-wide icon window.
            // Icon right edge is winX + 120. We want it >= screenFrame.minX + 42.
            // Icon left edge is winX + 80. We want it <= screenFrame.maxX - 42.
            let minWinX = screenFrame.minX + 42 - iconWidth
            let maxWinX = screenFrame.maxX - 42 - 80
            winX = max(minWinX, min(maxWinX, winX))
        }
        
        if DockingState.shared.isRightSide != isActuallyRight {
            DispatchQueue.main.async { DockingState.shared.isRightSide = isActuallyRight }
        }
        
        let iconTopY = activeFrame.maxY - topOffset
        let windowY = iconTopY - iconHeight // Directly below top boundary
        let newIconFrame = NSRect(x: winX, y: windowY, width: iconWidth, height: iconHeight)
        
        if iconWin.frame != newIconFrame {
            DispatchQueue.main.async {
                iconWin.setFrame(newIconFrame, display: true)
                iconWin.level = .normal
                iconWin.orderFrontRegardless()
            }
        } else {
            DispatchQueue.main.async {
                let targetLevel = NSWindow.Level.normal
                if iconWin.level != targetLevel { iconWin.level = targetLevel }
                iconWin.orderFrontRegardless()
            }
        }
    }
    
    func updateAssistantPosition(activeFrame: NSRect, screen: NSScreen? = nil, show: Bool = true) {
        guard let assistant = assistantWindow else { return }
        if !show { assistant.orderOut(nil); return }
        
        let targetScreen = screen ?? assistant.screen ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? .zero
        let assistantSize = assistant.frame.size
        let spacing: CGFloat = 4
        
        var targetX: CGFloat
        switch dockingPosition {
        case .right: targetX = activeFrame.maxX + spacing
        case .left: targetX = activeFrame.minX - assistantSize.width - spacing
        case .auto:
            targetX = activeFrame.maxX + spacing
            if targetX + assistantSize.width > screenFrame.maxX {
                targetX = activeFrame.minX - assistantSize.width - spacing
            }
        }
        
        targetX = max(screenFrame.minX + spacing, min(screenFrame.maxX - assistantSize.width - spacing, targetX))
        
        // Match host window height and align with its Y position
        let targetHeight = activeFrame.height
        let targetY = activeFrame.minY
        
        let newAssistantFrame = NSRect(x: targetX, y: targetY, width: assistantSize.width, height: targetHeight)
        if assistant.frame != newAssistantFrame { assistant.setFrame(newAssistantFrame, display: true) }
        if !assistant.isVisible { assistant.orderFront(nil) }
    }
    
    private func convertCGRectToCocoa(_ cgRect: CGRect) -> NSRect {
        let primaryScreen = NSScreen.screens.first
        let primaryHeight = primaryScreen?.frame.height ?? 0
        return NSRect(x: cgRect.origin.x, 
                      y: primaryHeight - cgRect.origin.y - cgRect.size.height, 
                      width: cgRect.size.width, 
                      height: cgRect.size.height)
    }
    
    private func restoreAssistantState(for bundleID: String) {
        let shouldBeVisible = appAssistantStates[bundleID] ?? false
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if shouldBeVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    AppDelegate.shared.showAssistant(shouldActivate: false)
                }
            } else {
                if self.assistantWindow?.isVisible ?? false {
                    self.assistantWindow?.orderOut(nil)
                    self.updatePositions()
                }
            }
        }
    }
    
    func updateAssistantState(isVisible: Bool) {
        guard isAdsorptionEnabled, let bundleID = lastObservedBundleID else { return }
        if appAssistantStates[bundleID] != isVisible {
            appAssistantStates[bundleID] = isVisible
            UserDefaults.standard.set(appAssistantStates, forKey: "appAssistantStates")
            updatePositions()
        }
    }
    
    // MARK: - Accessibility Observers
    
    private func setupAccessibilityObserver(for pid: pid_t) {
        cleanupAccessibilityObserver()
        var observer: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &observer)
        guard result == .success, let observer = observer else { return }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, appElement, kAXMovedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, appElement, kAXResizedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.axObserver = observer
        self.currentObservedPID = pid
    }
    
    private func cleanupAccessibilityObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
            axObserver = nil
        }
        currentObservedPID = nil
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    let manager = Unmanaged<DockingManager>.fromOpaque(refcon!).takeUnretainedValue()
    DispatchQueue.main.async { manager.refreshActiveWindowFrame() }
}

class PermissionManager {
    static let shared = PermissionManager()
    func checkAccessibility() -> Bool {
        #if APPSTORE
        return false
        #else
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
        #endif
    }
}
