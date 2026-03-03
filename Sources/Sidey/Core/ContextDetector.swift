import AppKit

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
    
    private init() {
        refresh()
        
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let bundleID = app.bundleIdentifier {
                // Ignore our own app so we don't clear the context when interacting with our AI tool
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
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier {
            if bundleID != Bundle.main.bundleIdentifier {
                self.updateContext(with: app)
            }
        }
    }
}
