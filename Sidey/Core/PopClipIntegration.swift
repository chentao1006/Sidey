import AppKit
import Foundation

enum PopClipIntegration {
    private static let bundleIdentifiers = [
        "com.pilotmoon.popclip",
        "com.pilotmoon.popclip-setapp"
    ]
    private static let extensionIdentifier = "com.chentao1006.sidey.popclip"
    private static let extensionInstalledKey = "isSideyPopClipExtensionInstalled"
    static let installStateDidChangeNotification = Notification.Name("SideyPopClipInstallStateDidChange")
    
    static var installedApplicationURL: URL? {
        for bundleIdentifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url
            }
        }
        
        let systemAppURL = URL(fileURLWithPath: "/Applications/PopClip.app")
        if FileManager.default.fileExists(atPath: systemAppURL.path) {
            return systemAppURL
        }
        
        let localAppURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/PopClip.app")
        return FileManager.default.fileExists(atPath: localAppURL.path) ? localAppURL : nil
    }
    
    static var applicationIcon: NSImage? {
        guard let installedApplicationURL else { return nil }
        return NSWorkspace.shared.icon(forFile: installedApplicationURL.path)
    }
    
    static var isPopClipInstalled: Bool {
        installedApplicationURL != nil
    }
    
    static var isExtensionInstalled: Bool {
        if UserDefaults.standard.bool(forKey: extensionInstalledKey) {
            return true
        }
        
        if let stagedExtensionURL, FileManager.default.fileExists(atPath: stagedExtensionURL.path) {
            return true
        }
        
        if FileManager.default.fileExists(atPath: installedExtensionURL.path) {
            return true
        }
        
        guard let extensionURLs = try? FileManager.default.contentsOfDirectory(
            at: popClipExtensionsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        
        return extensionURLs.contains { extensionURL in
            let configURL = extensionURL.appendingPathComponent("Config.json")
            guard let data = try? Data(contentsOf: configURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let identifier = json["identifier"] as? String else {
                return false
            }
            return identifier == extensionIdentifier
        }
    }
    
    static func installExtension() {
        do {
            let extensionURL = try preparedExtensionURL()
            openExtension(extensionURL)
        } catch {
            showInstallError(error)
        }
    }
    
    private static func openExtension(_ extensionURL: URL) {
        if let installedApplicationURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([extensionURL], withApplicationAt: installedApplicationURL, configuration: configuration) { _, error in
                if let error {
                    showInstallError(error)
                } else {
                    markExtensionInstalled()
                }
            }
        } else if !NSWorkspace.shared.open(extensionURL) {
            showInstallError(NSError(
                domain: "Sidey.PopClipIntegration",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "macOS could not open Sidey.popclipext."]
            ))
        } else {
            markExtensionInstalled()
        }
    }
    
    private static func preparedExtensionURL() throws -> URL {
        guard let sourceExtensionURL else {
            throw NSError(
                domain: "Sidey.PopClipIntegration",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Sidey.popclipext was not found in the app bundle."]
            )
        }
        
        let destinationDirectoryURL = try applicationSupportPopClipDirectoryURL()
        let destinationExtensionURL = destinationDirectoryURL.appendingPathComponent("Sidey.popclipext", isDirectory: true)
        
        if FileManager.default.fileExists(atPath: destinationExtensionURL.path) {
            try FileManager.default.removeItem(at: destinationExtensionURL)
        }
        try FileManager.default.copyItem(at: sourceExtensionURL, to: destinationExtensionURL)
        return destinationExtensionURL
    }
    
    private static func applicationSupportPopClipDirectoryURL() throws -> URL {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = applicationSupportURL
            .appendingPathComponent("Sidey", isDirectory: true)
            .appendingPathComponent("PopClip", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
    
    private static var popClipExtensionsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PopClip/Extensions", isDirectory: true)
    }
    
    private static var installedExtensionURL: URL {
        popClipExtensionsDirectoryURL.appendingPathComponent("Sidey.popclipext", isDirectory: true)
    }
    
    private static var stagedExtensionURL: URL? {
        guard let applicationSupportURL = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        
        return applicationSupportURL
            .appendingPathComponent("Sidey", isDirectory: true)
            .appendingPathComponent("PopClip", isDirectory: true)
            .appendingPathComponent("Sidey.popclipext", isDirectory: true)
    }
    
    private static var sourceExtensionURL: URL? {
        if let resourceURL = Bundle.main.resourceURL {
            let bundledExtensionURL = resourceURL
                .appendingPathComponent("PopClip", isDirectory: true)
                .appendingPathComponent("Sidey.popclipext", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundledExtensionURL.path) {
                return bundledExtensionURL
            }
        }
        
        let sourceExtensionURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PopClip", isDirectory: true)
            .appendingPathComponent("Sidey.popclipext", isDirectory: true)
        return FileManager.default.fileExists(atPath: sourceExtensionURL.path) ? sourceExtensionURL : nil
    }
    
    private static func showInstallError(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Unable to install PopClip plugin"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
    
    private static func markExtensionInstalled() {
        DispatchQueue.main.async {
            UserDefaults.standard.set(true, forKey: extensionInstalledKey)
            NotificationCenter.default.post(name: installStateDidChangeNotification, object: nil)
        }
    }
}
