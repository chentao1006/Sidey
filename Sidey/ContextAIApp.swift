import SwiftUI
import AppKit
import ServiceManagement
import Carbon
import Aptabase
import Combine


@main
struct SideyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("menuBarIcon") private var menuBarIcon = "brain"
    
    init() {
        if UserDefaults.standard.bool(forKey: "allowAnalytics") {
            Aptabase.shared.initialize(appKey: "A-US-3536295643")
        }
        _ = SyncManager.shared
        _ = NotificationManager.shared
    }
    
    var currentLocale: Locale {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        return lang == "system" ? .current : Locale(identifier: lang)
    }
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .systemServices) {
                GlobalHotKeyListener()
            }
        }
    }
}

struct GlobalHotKeyListener: View {
    var body: some View {
        EmptyView()
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CXAIToggleMainWindow"))) { _ in
            }
    }
}

enum PendingTextPresentation {
    case input
    case placeholder
}

private final class CursorAssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct PendingAssistantText {
    let text: String
    let presentation: PendingTextPresentation
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    
    var hotKeyManager = HotKeyManager.shared
    var contextDetector = ContextDetector.shared
    
    private var assistantWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var launchReady = false
    private var launchedAsLoginItem = false
    
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var menuBarAssistantPopover: NSPopover?
    private var cursorAssistantPanel: NSPanel?
    private let updaterViewModel = UpdaterViewModel()
    private let menuBarAssistantSize = NSSize(width: 320, height: 540)
    private var pendingAssistantSwitch: (bundleID: String, promptID: String)?
    private var pendingSelectedTextForAssistant: PendingAssistantText?
    #if !APPSTORE
    private var accessibilityCancellable: AnyCancellable?
    #endif

    private var isCursorAssistantPinned: Bool {
        UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication)
        )
    }
    
    @objc func handleAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        if event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAsLoginItem = true
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        
        UserDefaults.standard.register(defaults: [
            "showDockIcon": false,
            "openAI_BaseURL": "https://api.openai.com/v1",
            "usePublicService": true,
            "assistantWindowType": "menuBarPopover"
        ])
        
        setupAssistantWindow()
        setupIconWindow()
        setupStatusItem()
        
        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
        
        if let iconURL = Bundle.sideyModule.url(forResource: "Mac-512", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        
        #if !APPSTORE
        // Initialize selection monitoring only when already authorized.
        if PermissionManager.shared.checkAccessibilityStatus() {
            _ = FloatingButtonManager.shared
            SelectionMonitor.shared.start()
        }
        accessibilityCancellable = PermissionManager.shared.$isAccessibilityGranted
            .removeDuplicates()
            .sink { granted in
                guard granted else { return }
                _ = FloatingButtonManager.shared
                SelectionMonitor.shared.start()
            }
        #endif
        
        // Use a small delay to detect manual launch vs login launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !self.launchedAsLoginItem {
                #if APPSTORE
                if self.usesRegularAssistantWindow {
                    self.showAssistant()
                }
                #else
                if self.usesRegularAssistantWindow && PermissionManager.shared.checkAccessibilityStatus() {
                    self.showAssistant()
                }
                #endif
                
                // If API key is not set and not using public service, also show settings
                let apiKey = UserDefaults.standard.string(forKey: "openAI_APIKey") ?? ""
                let usePublicService = UserDefaults.standard.bool(forKey: "usePublicService")
                if !usePublicService && apiKey.isEmpty {
                    UserDefaults.standard.set("api", forKey: "settingsSelectedTab")
                    self.showSettings()
                }
            }
            self.launchReady = true
        }
        
        NotificationCenter.default.addObserver(forName: Notification.Name("CXAIToggleMainWindow"), object: nil, queue: .main) { _ in
            self.showAssistantWithCurrentSelection(positionInputAtMouse: true)
        }
        
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let closingWindow = notification.object as? NSWindow,
                  closingWindow == self?.assistantWindow else { return }
            
            DispatchQueue.main.async {
                self?.updateDockIconVisibility()
                // Update docking state to reflect manual closure
                DockingManager.shared.updateAssistantState(isVisible: false)
                DebugLogger.shared.log("Assistant window closed manually, disabling adsorption for current app.")
            }
        }
        
        setupAnalyticsPrompt()
    }
    
    private func setupAnalyticsPrompt() {
        guard !UserDefaults.standard.bool(forKey: "hasAskedAnalytics") else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            guard !UserDefaults.standard.bool(forKey: "hasAskedAnalytics") else { return }
            
            let alert = NSAlert()
            alert.messageText = L("Help Improve Sidey")
            alert.informativeText = L("Would you like to share anonymous usage data to help improve the app? You can change this later in Settings > About.")
            alert.addButton(withTitle: L("Yes, Share Anonymous Data"))
            alert.addButton(withTitle: L("No Thanks"))
            
            let showAndHandle = {
                NSApplication.shared.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                UserDefaults.standard.set(true, forKey: "hasAskedAnalytics")
                if response == .alertFirstButtonReturn {
                    UserDefaults.standard.set(true, forKey: "allowAnalytics")
                    Aptabase.shared.initialize(appKey: "A-US-3536295643")
                }
            }
            
            if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) {
                alert.beginSheetModal(for: window) { response in
                    UserDefaults.standard.set(true, forKey: "hasAskedAnalytics")
                    if response == .alertFirstButtonReturn {
                        UserDefaults.standard.set(true, forKey: "allowAnalytics")
                        Aptabase.shared.initialize(appKey: "A-US-3536295643")
                    }
                }
            } else {
                showAndHandle()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "sidey" else { return }

        switch url.host?.lowercased() {
        case "send":
            handleSendURL(url)
        default:
            break
        }
    }

    private func handleSendURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAssistant(reopenMenuBarPopover: true)
            return
        }

        queueSelectedTextForAssistant(text, presentation: .placeholder)
        showAssistant(reopenMenuBarPopover: true, positionInputAtMouse: true)
        notifyPendingSelectedTextIfNeeded()
    }
    
    private func setupAssistantWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = L("Sidey")
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        
        if !window.setFrameUsingName("AssistantWindow") {
            if let screen = NSScreen.main {
                let targetWidth: CGFloat = 420
                let targetHeight: CGFloat = 620
                let targetX = screen.visibleFrame.maxX - targetWidth - 40
                let targetY = screen.visibleFrame.maxY - targetHeight - 60
                window.setFrame(NSRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight), display: true)
            } else {
                window.center()
            }
        }
        window.setFrameAutosaveName("AssistantWindow")
        
        let assistantView = AssistantWindow()
        window.contentView = NSHostingView(rootView: assistantView)
        window.contentView = NSHostingView(rootView: assistantView)
        self.assistantWindow = window
        DockingManager.shared.assistantWindow = window
    }
    
    private func setupIconWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 700),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let iconView = AdsorptionIconView(onClick: { [weak self] in
            self?.showAssistant()
        }, onClickWithAssistant: { [weak self] promptID in
            self?.showAssistant()
            let bundleID = DockingManager.shared.lastObservedBundleID ?? ""
            NotificationCenter.default.post(name: Notification.Name("SideyDirectSend"), object: nil, userInfo: [
                "promptID": promptID,
                "bundleID": bundleID
            ])
        })
        
        window.contentView = NSHostingView(rootView: iconView)
        DockingManager.shared.iconWindow = window
    }
    
    func showAssistant(targetScreen: NSScreen? = nil, shouldActivate: Bool = true, reopenMenuBarPopover: Bool = false, positionInputAtMouse: Bool = false) {
        Aptabase.shared.trackEvent("show_assistant")
        if usesRegularAssistantWindow {
            showStandardAssistant(targetScreen: targetScreen, shouldActivate: shouldActivate, positionInputAtMouse: positionInputAtMouse)
        } else if positionInputAtMouse {
            showCursorAssistantPanel()
        } else {
            showMenuBarAssistantPopover(forceReopen: reopenMenuBarPopover, positionInputAtMouse: positionInputAtMouse)
        }
    }
    
    func showAssistantWithCurrentSelection(targetScreen: NSScreen? = nil, shouldActivate: Bool = true, reopenMenuBarPopover: Bool = false, positionInputAtMouse: Bool = false) {
        showAssistant(targetScreen: targetScreen, shouldActivate: shouldActivate, reopenMenuBarPopover: reopenMenuBarPopover, positionInputAtMouse: positionInputAtMouse)
        #if !APPSTORE
        captureSelectedTextForAssistantAsync { [weak self] text in
            if let text = text {
                self?.queueSelectedTextForAssistant(text)
                self?.notifyPendingSelectedTextIfNeeded()
            }
        }
        #endif
    }

    #if !APPSTORE
    private func captureSelectedTextForAssistantAsync(completion: @escaping (String?) -> Void) {
        guard PermissionManager.shared.checkAccessibilityStatus() else {
            completion(nil)
            return
        }
        
        if SelectionMonitor.shared.isShowingButton,
           let text = SelectionMonitor.shared.currentSelection,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completion(text)
            return
        }
        
        let app = selectionSourceApplication()
        let bundleID = app?.bundleIdentifier ?? ContextDetector.shared.currentBundleID
        guard !bundleID.isEmpty,
              bundleID != Bundle.main.bundleIdentifier,
              !AppBlocklist.isBlockedForSelection(bundleID) else {
            completion(nil)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let text = SelectionManager.shared.getSelectedText(from: app, allowClipboardFallback: true)
            DispatchQueue.main.async {
                if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completion(t)
                } else {
                    completion(nil)
                }
            }
        }
    }
    
    private func selectionSourceApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            return frontmost
        }
        
        let bundleID = ContextDetector.shared.currentBundleID
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }
    #endif
    
    func queueSelectedTextForAssistant(_ selectedText: String?, presentation: PendingTextPresentation = .input) {
        guard let selectedText,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingSelectedTextForAssistant = PendingAssistantText(text: selectedText, presentation: presentation)
    }
    
    func consumeSelectedTextForAssistant() -> PendingAssistantText? {
        let selectedText = pendingSelectedTextForAssistant
        pendingSelectedTextForAssistant = nil
        return selectedText
    }
    
    private func notifyPendingSelectedTextIfNeeded() {
        guard pendingSelectedTextForAssistant != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: Notification.Name("SideyPendingSelectionAvailable"), object: nil)
        }
    }
    
    func openAssistant(bundleID: String, promptID: String) {
        let targetApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        let targetScreen = targetApp.flatMap { screenForApp($0) }
        pendingAssistantSwitch = (bundleID, promptID)
        DebugLogger.shared.log("Opening assistant from notification for \(bundleID)|\(promptID).", type: .info)
        
        let showAndSwitch = {
            self.showAssistant(targetScreen: targetScreen, reopenMenuBarPopover: true)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                DebugLogger.shared.log("Posting assistant switch for \(bundleID)|\(promptID).", type: .info)
                NotificationCenter.default.post(
                    name: Notification.Name("CXAISwitchSession"),
                    object: nil,
                    userInfo: ["bundleID": bundleID, "promptID": promptID]
                )
            }
        }
        
        closeMenuBarAssistantPopoverIfNeeded()
        
        if let appURL = targetApp?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
                if let error {
                    DebugLogger.shared.log("Failed to activate notification target \(bundleID): \(error.localizedDescription)", type: .error)
                }
                if let app {
                    app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                } else if let targetApp {
                    targetApp.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: showAndSwitch)
            }
        } else {
            if let targetApp {
                targetApp.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: showAndSwitch)
        }
    }
    
    func consumePendingAssistantSwitch() -> (bundleID: String, promptID: String)? {
        let value = pendingAssistantSwitch
        pendingAssistantSwitch = nil
        return value
    }
    
    var usesRegularAssistantWindow: Bool {
        (UserDefaults.standard.string(forKey: "assistantWindowType") ?? "menuBarPopover") == "regularWindow"
    }
    
    var isAssistantVisible: Bool {
        if usesRegularAssistantWindow {
            return assistantWindow?.isVisible == true
        }
        return menuBarAssistantPopover?.isShown == true
    }
    
    func applyAssistantWindowTypePreference() {
        if usesRegularAssistantWindow {
            if menuBarAssistantPopover?.isShown == true {
                menuBarAssistantPopover?.performClose(nil)
            }
        } else {
            if assistantWindow?.isVisible == true {
                assistantWindow?.orderOut(nil)
            }
            DockingManager.shared.iconWindow?.orderOut(nil)
        }
        DockingManager.shared.updatePositions()
    }
    
    func toggleAssistantWindowType() {
        let nextType = usesRegularAssistantWindow ? "menuBarPopover" : "regularWindow"
        UserDefaults.standard.set(nextType, forKey: "assistantWindowType")
        applyAssistantWindowTypePreference()
        SyncManager.shared.syncToCloud()
        
        DispatchQueue.main.async {
            self.showAssistant(reopenMenuBarPopover: true)
        }
    }
    
    func updateMenuBarAssistantPopoverBehavior() {
        menuBarAssistantPopover?.behavior = UserDefaults.standard.bool(forKey: "alwaysOnTop") ? .applicationDefined : .transient
    }
    
    func closeMenuBarAssistantPopoverIfNeeded() {
        if menuBarAssistantPopover?.isShown == true {
            menuBarAssistantPopover?.performClose(nil)
        }
    }
    
    private func showStandardAssistant(targetScreen: NSScreen? = nil, shouldActivate: Bool = true, positionInputAtMouse: Bool = false) {
        if menuBarAssistantPopover?.isShown == true {
            menuBarAssistantPopover?.performClose(nil)
        }
        cursorAssistantPanel?.orderOut(nil)
        
        guard let window = assistantWindow else {
            setupAssistantWindow()
            showStandardAssistant(targetScreen: targetScreen, shouldActivate: shouldActivate, positionInputAtMouse: positionInputAtMouse)
            return
        }
        
        // Step 1: Make the window visible on ALL Spaces first.
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.remove(.moveToActiveSpace)
        
        // Step 2: Move to the target screen (if needed) before making it visible.
        let screen = targetScreen ?? screenForMouseCursor()
        if let screen = screen, window.screen != screen {
            moveWindow(window, toScreen: screen)
        }
        
        // Update docking state BEFORE showing to avoid flash
        DockingManager.shared.updateAssistantState(isVisible: true)
        
        // Step 3: Show the window
        if shouldActivate {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }

        if positionInputAtMouse {
            let mouseLocation = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.alignAssistantInputTopLeft(to: mouseLocation, in: window)
            }
        }
        
        NotificationCenter.default.post(name: Notification.Name("SideyRefreshContext"), object: nil, userInfo: nil)
        
        // Step 4: After the window is visible, anchor it to just this Space
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.collectionBehavior.remove(.canJoinAllSpaces)
            if shouldActivate {
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Anchors against the rendered text input, so layout changes do not affect placement.
    private func alignAssistantInputTopLeft(to mouseLocation: CGPoint, in window: NSWindow) {
        guard let contentView = window.contentView,
              let inputView = firstEditableTextView(in: contentView) else { return }

        let inputFrame = window.convertToScreen(inputView.convert(inputView.bounds, to: nil))
        // The text view sits inside the input field's 8-point SwiftUI padding.
        let inputTopLeft = CGPoint(x: inputFrame.minX - 8, y: inputFrame.maxY + 8)
        let offset = CGPoint(x: mouseLocation.x - inputTopLeft.x, y: mouseLocation.y - inputTopLeft.y)
        let desiredOrigin = CGPoint(x: window.frame.origin.x + offset.x, y: window.frame.origin.y + offset.y)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? window.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.setFrameOrigin(desiredOrigin)
            return
        }

        let maxX = max(visibleFrame.minX, visibleFrame.maxX - window.frame.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - window.frame.height)
        let clampedOrigin = CGPoint(
            x: min(max(desiredOrigin.x, visibleFrame.minX), maxX),
            y: min(max(desiredOrigin.y, visibleFrame.minY), maxY)
        )
        window.setFrameOrigin(clampedOrigin)
    }

    private func firstEditableTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.isEditable {
            return textView
        }
        for subview in view.subviews {
            if let textView = firstEditableTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    private func focusAssistantInput(in window: NSWindow) {
        guard let contentView = window.contentView,
              let inputView = firstEditableTextView(in: contentView) else { return }
        window.makeFirstResponder(inputView)
    }

    
    /// Returns the screen the mouse cursor is currently on. No permissions needed.
    func screenForMouseCursor() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }
    
    /// Returns the screen that the given app's frontmost window is on.
    /// Does NOT filter to on-screen-only so windows in background Spaces are found too.
    /// CGWindowListCopyWindowInfo does not require Accessibility permissions.
    func screenForApp(_ app: NSRunningApplication) -> NSScreen? {
        let pid = app.processIdentifier
        // Omit .optionOnScreenOnly so we also find windows in background Spaces.
        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"],
                  w > 50, h > 50 else { continue }  // skip tiny status-bar/menu windows
            // CGWindow uses top-left origin; convert to Cocoa (bottom-left origin)
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = CGPoint(x: x + w / 2, y: screenHeight - y - h / 2)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        return nil
    }
    
    /// Moves `window` to `screen`, preserving its size and keeping it in a
    /// similar position relative to the screen edges (right-aligned by default).
    private func moveWindow(_ window: NSWindow, toScreen screen: NSScreen) {
        let currentSize = window.frame.size
        let visibleFrame = screen.visibleFrame
        
        // Try to keep the same X/Y offset from the right and top edges, but
        // clamp so the window stays fully within the screen.
        let x = min(visibleFrame.maxX - currentSize.width - 40,
                    max(visibleFrame.minX, visibleFrame.maxX - currentSize.width - 40))
        let y = min(visibleFrame.maxY - currentSize.height - 60,
                    max(visibleFrame.minY, visibleFrame.maxY - currentSize.height - 60))
        
        window.setFrame(NSRect(x: x, y: y, width: currentSize.width, height: currentSize.height),
                        display: true, animate: false)
    }
    
    func showSettings() {
        Aptabase.shared.trackEvent("show_settings")
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "\(L("Sidey")) - \(L("Settings"))"
            window.isReleasedWhenClosed = false
            window.backgroundColor = .windowBackgroundColor
            
            if !window.setFrameUsingName("SettingsWindow") {
                window.center()
            }
            window.setFrameAutosaveName("SettingsWindow")
            
            let settingsView = SettingsView()
            window.contentView = NSHostingView(rootView: settingsView)
            self.settingsWindow = window
        }
        
        if let window = settingsWindow {
            window.collectionBehavior.insert(.moveToActiveSpace)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                window.collectionBehavior.remove(.moveToActiveSpace)
            }
            updateDockIconVisibility()
        }
    }
    
    private func updateDockIconVisibility() {
        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        if showDockIcon {
            NSApplication.shared.setActivationPolicy(.regular)
            return
        }
        
        // Only force show Dock icon when the Settings window is visible
        let isSettingsVisible = settingsWindow?.isVisible ?? false
        
        let currentPolicy = NSApplication.shared.activationPolicy()
        if isSettingsVisible {
            if currentPolicy != .regular {
                NSApplication.shared.setActivationPolicy(.regular)
            }
        } else {
            if currentPolicy != .accessory {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        if launchReady {
            let visible = NSApplication.shared.windows.filter { $0.isVisible && $0.className != "NSMenuWindow" }
            #if APPSTORE
            if usesRegularAssistantWindow && visible.isEmpty {
                showAssistant()
            }
            #else
            if usesRegularAssistantWindow && visible.isEmpty && PermissionManager.shared.checkAccessibilityStatus() {
                showAssistant()
            }
            #endif
            updateDockIconVisibility()
        }
    }
    
    func applicationDidResignActive(_ notification: Notification) {
        updateDockIconVisibility()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showAssistantWithCurrentSelection()
        return true
    }
    
    private func showMenuBarAssistantPopover(allowToggle: Bool = false, forceReopen: Bool = false, positionInputAtMouse: Bool = false) {
        guard let button = statusItem?.button else { return }

        cursorAssistantPanel?.orderOut(nil)
        
        if assistantWindow?.isVisible == true {
            assistantWindow?.orderOut(nil)
        }
        
        if menuBarAssistantPopover == nil {
            let popover = NSPopover()
            popover.behavior = UserDefaults.standard.bool(forKey: "alwaysOnTop") ? .applicationDefined : .transient
            popover.animates = true
            popover.contentSize = menuBarAssistantSize
            popover.contentViewController = NSHostingController(rootView: AssistantWindow(hidesDockingControl: true))
            menuBarAssistantPopover = popover
        }
        
        guard let popover = menuBarAssistantPopover else { return }
        updateMenuBarAssistantPopoverBehavior()
        
        if popover.isShown {
            if allowToggle {
                popover.performClose(nil)
            } else if forceReopen {
                popover.performClose(nil)
                DispatchQueue.main.async { [weak self] in
                    self?.showMenuBarAssistantPopover(positionInputAtMouse: positionInputAtMouse)
                }
            } else {
                if positionInputAtMouse, let popoverWindow = popover.contentViewController?.view.window {
                    alignAssistantInputTopLeft(to: NSEvent.mouseLocation, in: popoverWindow)
                }
                NotificationCenter.default.post(name: Notification.Name("SideyRefreshContext"), object: nil, userInfo: nil)
            }
            return
        }
        
        contextDetector.refresh()
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.contentSize = menuBarAssistantSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if positionInputAtMouse {
            let mouseLocation = NSEvent.mouseLocation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak popover] in
                guard let self, let popoverWindow = popover?.contentViewController?.view.window else { return }
                self.alignAssistantInputTopLeft(to: mouseLocation, in: popoverWindow)
            }
        }
        NotificationCenter.default.post(name: Notification.Name("SideyRefreshContext"), object: nil, userInfo: nil)
        
        DispatchQueue.main.async {
            popover.contentViewController?.view.window?.level = .floating
        }
    }

    /// A cursor-anchored assistant has no Popover arrow, but remains transient like one:
    /// it closes automatically whenever Sidey loses focus.
    private func showCursorAssistantPanel() {
        if menuBarAssistantPopover?.isShown == true {
            menuBarAssistantPopover?.performClose(nil)
        }
        assistantWindow?.orderOut(nil)

        let panel: NSPanel
        if let existingPanel = cursorAssistantPanel {
            panel = existingPanel
        } else {
            let newPanel = CursorAssistantPanel(
                contentRect: NSRect(origin: .zero, size: menuBarAssistantSize),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newPanel.isReleasedWhenClosed = false
            newPanel.isFloatingPanel = true
            newPanel.becomesKeyOnlyIfNeeded = false
            newPanel.isMovableByWindowBackground = true
            newPanel.hidesOnDeactivate = !isCursorAssistantPinned
            newPanel.level = .floating
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            let contentView = NSHostingView(rootView: AssistantWindow(hidesDockingControl: true, showsCloseButton: true))
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            contentView.layer?.cornerRadius = 12
            contentView.layer?.masksToBounds = true
            newPanel.contentView = contentView
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: newPanel,
                queue: .main
            ) { [weak self, weak newPanel] _ in
                guard self?.isCursorAssistantPinned == false else { return }
                newPanel?.orderOut(nil)
            }
            cursorAssistantPanel = newPanel
            panel = newPanel
        }

        let mouseLocation = NSEvent.mouseLocation
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Keep the initial, unpositioned frame invisible until the SwiftUI input has laid out.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.alignAssistantInputTopLeft(to: mouseLocation, in: panel)
            panel.makeKey()
            self.focusAssistantInput(in: panel)
            panel.alphaValue = 1
        }
        NotificationCenter.default.post(name: Notification.Name("SideyRefreshContext"), object: nil, userInfo: nil)
    }
}

struct HotKeyFormatter {
    static func currentHotkeyString() -> String {
        let keyCode = UserDefaults.standard.integer(forKey: "hotKeyKeyCode")
        let modifiers = UserDefaults.standard.integer(forKey: "hotKeyModifiers")
        if keyCode == 0 { return "" }
        
        var parts: [String] = []
        if (modifiers & 256) != 0 { parts.append("⌘") }
        if (modifiers & 2048) != 0 { parts.append("⌥") }
        if (modifiers & 4096) != 0 { parts.append("⌃") }
        if (modifiers & 512) != 0 { parts.append("⇧") }
        
        let keyStr: String
        switch keyCode {
        case 50: keyStr = "·"
        case 49: keyStr = "Space"
        case 36: keyStr = "Enter"
        case 48: keyStr = "Tab"
        case 123: keyStr = "←"
        case 124: keyStr = "→"
        case 125: keyStr = "↓"
        case 126: keyStr = "↑"
        case 0...50:
            let map: [Int: String] = [0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 25:"9", 26:"7", 28:"8", 29:"0", 31:"O", 32:"U", 34:"I", 35:"P", 37:"L", 38:"J", 40:"K", 45:"N", 46:"M"]
            keyStr = map[keyCode] ?? "K(\(keyCode))"
        default: keyStr = "K(\(keyCode))"
        }
        parts.append(keyStr)
        return parts.joined(separator: " + ")
    }
}

extension AppDelegate: NSMenuDelegate {
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusItemIcon()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsDidChange), name: UserDefaults.didChangeNotification, object: nil)
    }
    
    @objc private func userDefaultsDidChange() {
        updateStatusItemIcon()
        applyAssistantWindowTypePreference()
    }
    
    private func updateStatusItemIcon() {
        let iconName = UserDefaults.standard.string(forKey: "menuBarIcon") ?? "brain"
        if iconName == "none" {
            statusItem?.isVisible = false
        } else {
            statusItem?.isVisible = true
            let symbolName = iconName.isEmpty ? "brain" : iconName
            let localizedAppName = L("Sidey")
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: localizedAppName) {
                let config = NSImage.SymbolConfiguration(scale: .medium)
                statusItem?.button?.image = image.withSymbolConfiguration(config)
            } else if let fallback = NSImage(systemSymbolName: "brain", accessibilityDescription: localizedAppName) {
                let config = NSImage.SymbolConfiguration(scale: .medium)
                statusItem?.button?.image = fallback.withSymbolConfiguration(config)
            }
        }
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApplication.shared.currentEvent
        let isRightClick = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) == true)
        
        if isRightClick {
            if menuBarAssistantPopover?.isShown == true && !UserDefaults.standard.bool(forKey: "alwaysOnTop") {
                menuBarAssistantPopover?.performClose(nil)
            }
            if let menu = statusMenu {
                statusItem?.popUpMenu(menu)
            }
        } else {
            if usesRegularAssistantWindow {
                showAssistantWithCurrentSelection()
            } else {
                if menuBarAssistantPopover?.isShown == true {
                    showMenuBarAssistantPopover(allowToggle: true)
                } else {
                    showMenuBarAssistantPopover(allowToggle: true)
                    #if !APPSTORE
                    captureSelectedTextForAssistantAsync { [weak self] text in
                        if let text = text {
                            self?.queueSelectedTextForAssistant(text)
                            self?.notifyPendingSelectedTextIfNeeded()
                        }
                    }
                    #endif
                }
            }
        }
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        let bundleID = ContextDetector.shared.currentBundleID
        let appName = ContextDetector.shared.currentAppName
        let prompts = PromptStore.shared.getPrompts(for: bundleID)

        let hotKeyString = HotKeyFormatter.currentHotkeyString()
        let showItem = NSMenuItem(title: "\(L("Show Assistant")) (\(hotKeyString))", action: #selector(showAssistantAction), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem.separator())
        
        if !prompts.isEmpty {
            let headerItem = NSMenuItem(title: String(format: L("Assistants for %@:"), appName), action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            
            for prompt in prompts {
                let item = NSMenuItem(title: "  " + prompt.name, action: #selector(directSendAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["bundleID": bundleID, "promptID": prompt.id]
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }
        
        let settingsItem = NSMenuItem(title: L("Settings..."), action: #selector(showSettingsAction), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        #if !APPSTORE
        let updateItem = NSMenuItem(title: L("Check for Updates..."), action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        #endif
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: L("Quit Sidey"), action: #selector(quitAction), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    func menuDidClose(_ menu: NSMenu) {
        // No-op
    }
    
    @objc private func directSendAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let bundleID = info["bundleID"],
              let promptID = info["promptID"] else { return }
        
        showAssistantWithCurrentSelection()
        NotificationCenter.default.post(name: Notification.Name("SideyDirectSend"), object: nil, userInfo: ["bundleID": bundleID, "promptID": promptID])
    }
    
    @objc private func showAssistantAction() {
        showAssistantWithCurrentSelection()
    }
    
    @objc private func showSettingsAction() {
        showSettings()
    }
    
    @objc private func toggleAssistantWindowTypeAction() {
        toggleAssistantWindowType()
    }
    
    #if !APPSTORE
    @objc private func checkForUpdatesAction() {
        updaterViewModel.checkForUpdates()
    }
    #endif
    
    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
