import Foundation

// Support both SPM and direct Xcode builds
extension Bundle {
    static var sideyModule: Bundle {
        // 1. Try SPM built-in (always preferred if available)
        #if SWIFT_PACKAGE
        return Bundle.module
        #endif
        
        // 2. Search for the bundle that contains Sidey's unique "prompts.json"
        // This is the most reliable "fingerprint" to distinguish our bundle from system bundles
        for bundle in Bundle.allBundles {
            // Exclude system bundles immediately
            let path = bundle.bundlePath
            if path.hasPrefix("/System") || path.hasPrefix("/Library") || path.hasPrefix("/usr") {
                continue
            }
            
            if bundle.url(forResource: "prompts", withExtension: "json") != nil {
                return bundle
            }
        }
        
        // 3. Fallback to searching for the specific nested SPM bundle by name next to executable
        let rootURL = Bundle.main.bundleURL.deletingLastPathComponent()
        for name in ["Sidey_Sidey.bundle", "Sidey-Sidey.bundle"] {
            if let b = Bundle(url: rootURL.appendingPathComponent(name)) {
                if b.url(forResource: "prompts", withExtension: "json") != nil {
                    return b
                }
            }
        }
        
        return Bundle.main
    }
}

func L(_ key: String) -> String {
    let appLang = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
    let supportedLanguages = ["en", "zh-Hans", "ja", "ko", "de", "fr", "es", "it"]

    func normalizedLanguage(_ identifier: String) -> String {
        let lowercased = identifier.lowercased()
        if lowercased.hasPrefix("zh") { return "zh-Hans" }
        if lowercased.hasPrefix("ja") { return "ja" }
        if lowercased.hasPrefix("ko") { return "ko" }
        if lowercased.hasPrefix("de") { return "de" }
        if lowercased.hasPrefix("fr") { return "fr" }
        if lowercased.hasPrefix("es") { return "es" }
        if lowercased.hasPrefix("it") { return "it" }
        return "en"
    }
    
    let target = appLang == "system" ? normalizedLanguage(Locale.preferredLanguages.first ?? "en") : (supportedLanguages.contains(appLang) ? appLang : normalizedLanguage(appLang))
    
    // Aggressively find the specific .lproj bundle
    func findSpecificBundle() -> Bundle {
        let base = Bundle.sideyModule
        
        // Check base bundle's localizations
        if let p = base.path(forResource: target, ofType: "lproj") ?? base.path(forResource: target.lowercased(), ofType: "lproj"),
           let b = Bundle(path: p) {
            return b
        }
        
        // If not found, manually scan ONLY the app's own directory for the .lproj folder
        let fm = FileManager.default
        let appResources = Bundle.main.bundleURL
        
        if let enumerator = fm.enumerator(at: appResources, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if url.lastPathComponent.lowercased() == "\(target.lowercased()).lproj" {
                    // Double check this is not a system path
                    if !url.path.hasPrefix("/System") && !url.path.hasPrefix("/Library") {
                        if let lb = Bundle(url: url) { return lb }
                    }
                }
            }
        }
        
        return base
    }
    
    let targetBundle = findSpecificBundle()
    let result = targetBundle.localizedString(forKey: key, value: key, table: nil)
    
    // Final check: if result is still the key, try searching ALL bundles specifically for this key in the target language
    if result == key {
        for b in Bundle.allBundles {
            let path = b.bundlePath
            if path.hasPrefix("/System") || path.hasPrefix("/Library") { continue }
            
            if let lp = b.path(forResource: target, ofType: "lproj"), let lb = Bundle(path: lp) {
                let r = lb.localizedString(forKey: key, value: key, table: nil)
                if r != key { return r }
            }
        }
    }
    
    #if DEBUG
    if key == "Sidey" {
        print("[Sidey] Lang: \(appLang), Target: \(target), Result: \(result), Bundle: \(targetBundle.bundlePath)")
    }
    #endif
    
    return result
}
