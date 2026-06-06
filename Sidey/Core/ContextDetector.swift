import AppKit
import SwiftUI
import Combine

class ContextDetector: ObservableObject {
    static let shared = ContextDetector()
    
    struct AppContext: Identifiable, Equatable {
        let bundleID: String
        let appName: String
        let appIcon: NSImage?
        
        var id: String { bundleID }
        
        static func == (lhs: AppContext, rhs: AppContext) -> Bool {
            return lhs.bundleID == rhs.bundleID
        }
    }
    
    @Published var currentBundleID: String = ""
    @Published var currentAppName: String = ""
    @Published var currentAppIcon: NSImage?
    @Published var recentApps: [AppContext] = []
    
    @Published var lastClipboardSourceBundleID: String?
    private var lastPasteboardChangeCount: Int = NSPasteboard.general.changeCount
    
    private var timer: Timer?
    
    private init() {
        refresh()
        
        // Polling for clipboard and context changes.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let bundleID = app.bundleIdentifier {
                if bundleID != Bundle.main.bundleIdentifier {
                    self.updateContext(with: app)
                }
            }
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let bundleID = app.bundleIdentifier {
                if bundleID != Bundle.main.bundleIdentifier {
                    self.updateContext(with: app)
                }
            }
        }
    }
    
    private func updateContext(with app: NSRunningApplication) {
        if let bundleID = app.bundleIdentifier {
            // Optimization: Skip if it's the same app as before
            if bundleID == self.currentBundleID { return }
            
            self.currentBundleID = bundleID
            self.currentAppName = app.localizedName ?? bundleID
            if let url = app.bundleURL {
                self.currentAppIcon = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                self.currentAppIcon = nil
            }
            
            let newContext = AppContext(bundleID: bundleID, appName: self.currentAppName, appIcon: self.currentAppIcon)
            DispatchQueue.main.async {
                self.recentApps.removeAll(where: { $0.bundleID == bundleID })
                self.recentApps.insert(newContext, at: 0)
                if self.recentApps.count > 5 {
                    self.recentApps.removeLast()
                }
            }
        }
    }
    
    func refresh() {
        // Track Pasteboard changes
        let currentCount = NSPasteboard.general.changeCount
        if currentCount != lastPasteboardChangeCount {
            lastPasteboardChangeCount = currentCount
            // Record which app was active when it changed
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                lastClipboardSourceBundleID = frontApp.bundleIdentifier
            }
        }
        
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier {
            if bundleID != Bundle.main.bundleIdentifier {
                self.updateContext(with: app)
            }
        }
    }
}

// MARK: - Global Selection Monitor
class SelectionMonitor: ObservableObject {
    static let shared = SelectionMonitor()
    
    @AppStorage("isSelectionCaptureEnabled") private var isSelectionCaptureEnabled = true
    
    private var mouseUpMonitor: Any?
    private var mouseDownMonitor: Any?
    private var keyboardMonitor: Any?
    private var startPosition: CGPoint = .zero
    /// Position of the last left-mouse-down — used as fallback for keyboard-triggered button placement.
    private var lastClickPosition: CGPoint = .zero
    private var timer: Timer?
    private var distanceTimer: Timer?
    private var accessibilityCancellable: AnyCancellable?
    
    /// Tracks the last captured text during periodic checks to avoid redundant processing.
    private var lastPeriodicCheckText: String?
    
    /// Time when the mouse first moved away from the button.
    private var awayStartTime: Date?
    
    /// Debounce item for selection change notifications.
    private var debounceWorkItem: DispatchWorkItem?
    
    /// Time of the last selection capture (to enforce cooldowns).
    private var lastCaptureTime: Date = .distantPast
    
    @Published var currentSelection: String?
    @Published var buttonPosition: CGPoint = .zero
    @Published var isShowingButton: Bool = false
    
    private init() {
        // Reinstall keyboard monitors when the user grants accessibility permission
        // (they need AX permission; if start() was called before permission was given,
        //  the monitors would have returned nil and never fired).
        accessibilityCancellable = PermissionManager.shared.$isAccessibilityGranted
            .removeDuplicates()
            .sink { [weak self] granted in
                guard granted, let self = self else { return }
                self.start()
            }
    }
    
    func start() {
        // Request Permissions if needed (Silenly check)
        let hasPermissions = PermissionManager.shared.checkAccessibilityStatus()
        DebugLogger.shared.log("SelectionMonitor: Starting monitors (Permissions: \(hasPermissions))")
        
        guard hasPermissions else { return }
        
        // Track mouse-down position (used as fallback for keyboard-triggered button placement)
        if mouseDownMonitor == nil {
            mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                let loc = NSEvent.mouseLocation
                self?.startPosition = loc
                self?.lastClickPosition = loc
            }
        }
        
        // Mouse-up: drag or multi-click selection
        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                self?.handleMouseUp(event: event)
            }
        }
        
        installKeyboardMonitors()
    }
    
    /// Install keyboard/flags monitors — requires Accessibility permission.
    /// Returns silently if permission is not yet granted (will retry via Combine subscriber).
    private func installKeyboardMonitors() {
        if keyboardMonitor == nil {
            // keyDown fires after the frontmost app has processed the event,
            // so selection is already complete by the time our handler runs.
            keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.handleKeyDown(event: event)
            }
        }
    }
    
    func stop() {
        [mouseUpMonitor, mouseDownMonitor, keyboardMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        mouseUpMonitor = nil
        mouseDownMonitor = nil
        keyboardMonitor = nil
    }
    
    private func handleMouseUp(event: NSEvent) {
        guard isSelectionCaptureEnabled else { return }
        
        let endPosition = NSEvent.mouseLocation
        let distance = sqrt(pow(endPosition.x - startPosition.x, 2) + pow(endPosition.y - startPosition.y, 2))
        
        // Only check on drag or multi-click
        guard distance > 5 || event.clickCount > 1 else {
            if isShowingButton { self.hideButton() }
            return
        }
        
        let delay = event.clickCount > 1 ? 0.5 : 0.3
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.checkSelection(at: endPosition)
        }
    }
    
    // MARK: - Keyboard selection handlers
    
    private func handleKeyDown(event: NSEvent) {
        guard isSelectionCaptureEnabled else { return }
        
        let code = Int(event.keyCode)
        let flags = event.modifierFlags
        
        // Cmd+A — Select All (same key event as Edit > Select All menu shortcut)
        // Use strict match to avoid false positives (no Shift/Option/Control).
        let isCmdA = flags.contains(.command)
                  && !flags.contains(.shift)
                  && !flags.contains(.option)
                  && !flags.contains(.control)
                  && code == 0
        
        // Shift + arrow keys — incremental keyboard selection
        let arrowCodes: Set<Int> = [123, 124, 125, 126]           // ← → ↓ ↑
        let isShiftNav  = flags.contains(.shift) && arrowCodes.contains(code)
        
        guard isCmdA || isShiftNav else {
            if isShowingButton {
                hideButton()
            }
            return
        }
        scheduleKeyboardCheck()
    }
    

    
    private func scheduleKeyboardCheck() {
        timer?.invalidate()
        // 0.12 s is enough time for keyDown → app processes event → our timer fires
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.captureCurrentSelection(isKeyboardTriggered: true)
        }
    }
    
    /// Selection change notification (event-driven).
    /// Uses a 0.5s debounce to avoid "flicker" and heavy processing in rapid-fire apps like VSCode.
    func periodicCheck() {
        guard isSelectionCaptureEnabled else { return }
        
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.captureCurrentSelection(isKeyboardTriggered: false)
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
    
    /// Captures selection from the frontmost app.
    /// - Parameter isKeyboardTriggered: If true, uses specialized positioning (AX bounds or last click).
    private func captureCurrentSelection(isKeyboardTriggered: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }
        
        // Skip apps in blocklist
        if AppBlocklist.isBlockedForSelection(bundleID) { return }
        
        let allowClipboardFallback = isKeyboardTriggered
        guard let text = SelectionManager.shared.getSelectedText(from: app, allowClipboardFallback: allowClipboardFallback),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No text selected
            if !isKeyboardTriggered && lastPeriodicCheckText != nil {
                // If it was selected and now it's not, hide the button? 
                // Maybe not, give the user time to click the button.
                lastPeriodicCheckText = nil
            }
            return
        }
        
        // Avoid re-processing if the selection hasn't changed (for periodic ticks)
        if !isKeyboardTriggered && text == lastPeriodicCheckText { return }
        lastPeriodicCheckText = text
        
        // Determine position
        let position: CGPoint
        if isKeyboardTriggered {
            if let selRect = SelectionManager.shared.getSelectedTextBounds(for: app),
               selRect.width > 1 || selRect.height > 1 {
                let primaryH = NSScreen.screens.first?.frame.height ?? 0
                position = CGPoint(x: selRect.maxX, y: primaryH - selRect.maxY)
            } else if self.lastClickPosition != .zero {
                position = self.lastClickPosition
            } else {
                position = NSEvent.mouseLocation
            }
        } else {
            // Periodic check or Menu check: use AX bounds if possible, else mouse
            if let selRect = SelectionManager.shared.getSelectedTextBounds(for: app),
               selRect.width > 1 || selRect.height > 1 {
                let primaryH = NSScreen.screens.first?.frame.height ?? 0
                position = CGPoint(x: selRect.maxX, y: primaryH - selRect.maxY)
            } else {
                position = NSEvent.mouseLocation
            }
        }
        
        self.checkSelection(at: position, text: text)
    }
    
    private func checkSelection(at location: CGPoint, text: String? = nil) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleID = app.bundleIdentifier ?? ""
        
        // Don't show if Sidey is focused
        if bundleID == Bundle.main.bundleIdentifier { return }
        
        // Skip apps where text selection is irrelevant or impossible
        if AppBlocklist.isBlockedForSelection(bundleID) { return }
              
        let startTime = Date()
        
        // If text is already provided (from captureCurrentSelection), use it.
        // Otherwise, fetch it (for legacy mouse triggers).
        let capturedText: String
        if let provided = text {
            capturedText = provided
        } else {
            guard let fetched = SelectionManager.shared.getSelectedText(from: app, allowClipboardFallback: true), !fetched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DebugLogger.shared.log("SelectionMonitor: No text found in \(bundleID) (Time: \(String(format: "%.3f", Date().timeIntervalSince(startTime)))s)")
                self.hideButton()
                return
            }
            capturedText = fetched
        }
        
        // Use the target location
        let targetPosition = location
        
        DebugLogger.shared.log("SelectionMonitor: Selection detected in \(bundleID) (At: \(targetPosition), Time: \(String(format: "%.3f", Date().timeIntervalSince(startTime)))s)")
        
        // Don't reposition if already showing nearby
        if isShowingButton {
            let distance = sqrt(pow(targetPosition.x - buttonPosition.x, 2) + pow(targetPosition.y - buttonPosition.y, 2))
            if distance < 40 {
                self.currentSelection = capturedText
                return
            }
        }
        
        DispatchQueue.main.async {
            self.currentSelection = capturedText
            self.buttonPosition = targetPosition
            self.showButton()
        }
        
        // Auto-hide after 10 seconds
        timer?.invalidate() 
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.hideButton()
        }
    }
    
    private func showButton() {
        self.isShowingButton = true
        self.awayStartTime = nil
        startDistanceMonitoring()
        NotificationCenter.default.post(name: Notification.Name("SideyShowFloatingButton"), object: nil)
    }
    
    /// Starts a timer to monitor the mouse distance from the floating button.
    private func startDistanceMonitoring() {
        distanceTimer?.invalidate()
        distanceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkMouseDistance()
        }
    }
    
    private func checkMouseDistance() {
        guard isShowingButton else {
            distanceTimer?.invalidate()
            return
        }
        
        let mouseLoc = NSEvent.mouseLocation
        let distance = sqrt(pow(mouseLoc.x - buttonPosition.x, 2) + pow(mouseLoc.y - buttonPosition.y, 2))
        
        // Threshold: 150 pixels. Beyond this, we start the "away" countdown.
        if distance > 100 {
            if awayStartTime == nil {
                awayStartTime = Date()
            } else if let start = awayStartTime, Date().timeIntervalSince(start) > 1.0 {
                // If away for more than 3 seconds, hide it.
                hideButton()
            }
        } else {
            // Mouse is close, stay visible.
            awayStartTime = nil
        }
    }
    
    func hideButton() {
        DispatchQueue.main.async {
            self.isShowingButton = false
            self.awayStartTime = nil
            self.distanceTimer?.invalidate()
            self.distanceTimer = nil
            NotificationCenter.default.post(name: Notification.Name("SideyHideFloatingButton"), object: nil)
        }
    }
    
    func sendToAssistant() {
        guard let selection = currentSelection else { return }
        hideButton()
        NotificationCenter.default.post(name: Notification.Name("SideySendSelectionToAssistant"), object: selection)
    }
}

// MARK: - Floating Button UI and Manager
class FloatingButtonManager {
    static let shared = FloatingButtonManager()
    private var window: NSPanel?
    
    private init() {
        NotificationCenter.default.addObserver(forName: Notification.Name("SideyShowFloatingButton"), object: nil, queue: .main) { [weak self] _ in
            self?.show()
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("SideyHideFloatingButton"), object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        }
    }
    
    private func show() {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered, defer: false)
            panel.level = .mainMenu + 1
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: FloatingButtonView())
            self.window = panel
        }
        
        let position = SelectionMonitor.shared.buttonPosition
        // Position to the RIGHT of the mouse (offset 10px), centered vertically (-15px)
        window?.setFrameOrigin(CGPoint(x: position.x + 10, y: position.y - 15))
        window?.alphaValue = 1.0
        window?.orderFront(nil)
    }
    
    private func hide() {
        window?.orderOut(nil)
        window?.alphaValue = 0
    }
}

struct FloatingButtonView: View {
    @State private var isHovered = false
    
    private var appIcon: NSImage? {
        return NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
    }
    
    var body: some View {
        Button(action: { SelectionMonitor.shared.sendToAssistant() }) {
            ZStack {
                Circle()
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.95))
                    .shadow(radius: 1)
                
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                        .clipShape(Circle())
                }
                
                Circle()
                    .stroke(Color.gray.opacity(0.4), lineWidth: 0.5)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            isHovered = hovering
        }
    }
}
