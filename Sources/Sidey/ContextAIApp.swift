import SwiftUI
import AppKit
import ServiceManagement
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
        return appLanguage == "system" ? Locale.current : Locale(identifier: appLanguage)
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
            "showDockIcon": true,
            "openAI_BaseURL": "https://api.openai.com/v1"
        ])
        
        setupAssistantWindow()
        setupStatusItem()
        
        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
        
        if let iconURL = Bundle.module.url(forResource: "Mac-512", withExtension: "png", subdirectory: "Assets.xcassets/AppIcon.appiconset"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        
        // Use a small delay to detect manual launch vs login launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !self.launchedAsLoginItem {
                self.showAssistant()
            }
            self.launchReady = true
        }
        
        NotificationCenter.default.addObserver(forName: Notification.Name("CXAIToggleMainWindow"), object: nil, queue: .main) { _ in
            self.showAssistant()
        }
        
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async {
                self.updateDockIconVisibility()
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
        
        let assistantView = AssistantWindow().environment(\.locale, Locale.current)
        window.contentView = NSHostingView(rootView: assistantView)
        self.assistantWindow = window
    }
    
    func showAssistant() {
        guard let window = assistantWindow else {
            setupAssistantWindow()
            showAssistant()
            return
        }
        
        // Always enforce move to active space to handle space transitions reliably
        window.collectionBehavior.insert(.moveToActiveSpace)
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        
        // Clear the behavior after a short delay so it doesn't follow the user permanently
        // unless requested again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.collectionBehavior.remove(.moveToActiveSpace)
        }
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
            
            window.contentView = NSHostingView(rootView: SettingsView().environment(\.locale, Locale.current))
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
            if visible.isEmpty {
                showAssistant()
            }
            updateDockIconVisibility()
        }
    }
    
    func applicationDidResignActive(_ notification: Notification) {
        updateDockIconVisibility()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showAssistant()
        return true
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
        
        if let button = statusItem?.button {
            updateStatusItemIcon()
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            
            // Allow checking for right-click via control-click or rightMouseUp
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsDidChange), name: UserDefaults.didChangeNotification, object: nil)
    }
    
    @objc private func userDefaultsDidChange() {
        updateStatusItemIcon()
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
    
    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            // Show right click menu
            let menu = NSMenu()
            menu.delegate = self
            menuNeedsUpdate(menu)
            
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil) // Blocks until menu is closed
        } else {
            // Left click
            showAssistant()
        }
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hotKeyString = HotKeyFormatter.currentHotkeyString()
        
        let showItem = NSMenuItem(title: "\(L("Show Assistant")) (\(hotKeyString))", action: #selector(showAssistantAction), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        
        let settingsItem = NSMenuItem(title: L("Settings..."), action: #selector(showSettingsAction), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: L("Quit Sidey"), action: #selector(quitAction), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }
    
    @objc private func showAssistantAction() {
        showAssistant()
    }
    
    @objc private func showSettingsAction() {
        showSettings()
    }
    
    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
