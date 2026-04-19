import AppKit
import SwiftUI

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
    private var startPosition: CGPoint = .zero
    private var timer: Timer?
    
    @Published var currentSelection: String?
    @Published var buttonPosition: CGPoint = .zero
    @Published var isShowingButton: Bool = false
    
    private init() {}
    
    func start() {
        // Request Permissions if needed (Silenly check)
        let hasPermissions = PermissionManager.shared.checkAccessibilityStatus()
        DebugLogger.shared.log("SelectionMonitor: Starting monitors (Permissions: \(hasPermissions))")
        
        // Track start position
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.startPosition = NSEvent.mouseLocation
        }
        
        // Listen for mouse up events globally
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.handleMouseUp(event: event)
        }
    }
    
    func stop() {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
    }
    
    private func handleMouseUp(event: NSEvent) {
        guard isSelectionCaptureEnabled else { return }
        
        let endPosition = NSEvent.mouseLocation

        let distance = sqrt(pow(endPosition.x - startPosition.x, 2) + pow(endPosition.y - startPosition.y, 2))
        
        // Only check if it looks like a drag/selection (moved more than 5 pixels)
        // OR if it's a multiple click (double click to select word, triple to select line)
        guard distance > 5 || event.clickCount > 1 else {
            // If just a single click and no move, hide the button if it was showing
            if isShowingButton {
                self.hideButton()
            }
            return
        }
        
        let delay = event.clickCount > 1 ? 0.5 : 0.3
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.checkSelection(at: endPosition)
        }
    }
    
    private func checkSelection(at location: CGPoint) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleID = app.bundleIdentifier ?? ""
        
        // Don't show if Sidey is focused
        if bundleID == Bundle.main.bundleIdentifier { return }
              
        let startTime = Date()
        guard let text = SelectionManager.shared.getSelectedText(from: app), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DebugLogger.shared.log("SelectionMonitor: No text found in \(bundleID) (Time: \(String(format: "%.3f", Date().timeIntervalSince(startTime)))s)")
            self.hideButton()
            return
        }
        
        // Use the mouse release position as the target
        let targetPosition = location
        
        DebugLogger.shared.log("SelectionMonitor: Selection detected in \(bundleID) (At: \(targetPosition), Time: \(String(format: "%.3f", Date().timeIntervalSince(startTime)))s)")
        
        // Don't reposition if already showing nearby
        if isShowingButton {
            let distance = sqrt(pow(targetPosition.x - buttonPosition.x, 2) + pow(targetPosition.y - buttonPosition.y, 2))
            if distance < 40 {
                self.currentSelection = text
                return
            }
        }
        
        DispatchQueue.main.async {
            self.currentSelection = text
            self.buttonPosition = targetPosition
            self.showButton()
        }
        
        // Auto-hide after 10 seconds (give more time)
        timer?.invalidate() 
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.hideButton()
        }
    }
    
    private func showButton() {
        self.isShowingButton = true
        NotificationCenter.default.post(name: Notification.Name("SideyShowFloatingButton"), object: nil)
    }
    
    func hideButton() {
        DispatchQueue.main.async {
            self.isShowingButton = false
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
