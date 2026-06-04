import SwiftUI
import AppKit
import ServiceManagement
import Carbon
import Carbon


@main
struct SideyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("menuBarIcon") private var menuBarIcon = "brain"
    
    init() {
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
    private let updaterViewModel = UpdaterViewModel()
    private let menuBarAssistantSize = NSSize(width: 320, height: 540)
    private var pendingAssistantSwitch: (bundleID: String, promptID: String)?
    private var pendingSelectedTextForAssistant: String?
    
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
        
        // Initialize Selection Monitoring and Floating Button
        _ = FloatingButtonManager.shared
        SelectionMonitor.shared.start()
        
        // Use a small delay to detect manual launch vs login launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !self.launchedAsLoginItem {
                self.showAssistant()
                
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
            self.showAssistantWithCurrentSelection()
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
    
    func showAssistant(targetScreen: NSScreen? = nil, shouldActivate: Bool = true, reopenMenuBarPopover: Bool = false) {
        if usesRegularAssistantWindow {
            showStandardAssistant(targetScreen: targetScreen, shouldActivate: shouldActivate)
        } else {
            showMenuBarAssistantPopover(forceReopen: reopenMenuBarPopover)
        }
    }
    
    func showAssistantWithCurrentSelection(targetScreen: NSScreen? = nil, shouldActivate: Bool = true, reopenMenuBarPopover: Bool = false) {
        queueSelectedTextForAssistant(captureSelectedTextForAssistant())
        showAssistant(targetScreen: targetScreen, shouldActivate: shouldActivate, reopenMenuBarPopover: reopenMenuBarPopover)
        notifyPendingSelectedTextIfNeeded()
    }
    
    private func captureSelectedTextForAssistant() -> String? {
        if SelectionMonitor.shared.isShowingButton,
           let text = SelectionMonitor.shared.currentSelection,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        
        let app = selectionSourceApplication()
        let bundleID = app?.bundleIdentifier ?? ContextDetector.shared.currentBundleID
        guard !bundleID.isEmpty,
              bundleID != Bundle.main.bundleIdentifier,
              !AppBlocklist.isBlockedForSelection(bundleID) else {
            return nil
        }
        
        guard let text = SelectionManager.shared.getSelectedText(from: app, allowClipboardFallback: true),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
    
    private func selectionSourceApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            return frontmost
        }
        
        let bundleID = ContextDetector.shared.currentBundleID
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }
    
    func queueSelectedTextForAssistant(_ selectedText: String?) {
        guard let selectedText,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingSelectedTextForAssistant = selectedText
    }
    
    func consumeSelectedTextForAssistant() -> String? {
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
    
    private func showStandardAssistant(targetScreen: NSScreen? = nil, shouldActivate: Bool = true) {
        if menuBarAssistantPopover?.isShown == true {
            menuBarAssistantPopover?.performClose(nil)
        }
        
        guard let window = assistantWindow else {
            setupAssistantWindow()
            showStandardAssistant(targetScreen: targetScreen, shouldActivate: shouldActivate)
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
            if usesRegularAssistantWindow && visible.isEmpty {
                showAssistant()
            }
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
    
    private func showMenuBarAssistantPopover(allowToggle: Bool = false, forceReopen: Bool = false) {
        guard let button = statusItem?.button else { return }
        
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
                    self?.showMenuBarAssistantPopover()
                }
            } else {
                NotificationCenter.default.post(name: Notification.Name("SideyRefreshContext"), object: nil, userInfo: nil)
            }
            return
        }
        
        contextDetector.refresh()
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.contentSize = menuBarAssistantSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NotificationCenter.default.post(name: Notification.Name("SideyRefreshContext"), object: nil, userInfo: nil)
        
        DispatchQueue.main.async {
            popover.contentViewController?.view.window?.level = .floating
        }
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
                let selectedText = menuBarAssistantPopover?.isShown == true ? nil : captureSelectedTextForAssistant()
                queueSelectedTextForAssistant(selectedText)
                showMenuBarAssistantPopover(allowToggle: true)
                notifyPendingSelectedTextIfNeeded()
            }
        }
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        let bundleID = ContextDetector.shared.currentBundleID
        let appName = ContextDetector.shared.currentAppName
        let prompts = PromptStore.shared.getPrompts(for: bundleID)
        
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
        
        let hotKeyString = HotKeyFormatter.currentHotkeyString()
        
        let showItem = NSMenuItem(title: "\(L("Show Assistant")) (\(hotKeyString))", action: #selector(showAssistantAction), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        
        let switchWindowTypeTitle = usesRegularAssistantWindow ? L("Switch to Menu Bar Popover") : L("Switch to Regular Window")
        let switchWindowTypeItem = NSMenuItem(title: switchWindowTypeTitle, action: #selector(toggleAssistantWindowTypeAction), keyEquivalent: "")
        switchWindowTypeItem.target = self
        menu.addItem(switchWindowTypeItem)
        
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
