import Foundation

func L(_ key: String) -> String {
    var languageCode = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
    
    if languageCode == "system" {
        if let preferred = Locale.preferredLanguages.first {
            if preferred.hasPrefix("zh") {
                languageCode = "zh-Hans"
            } else {
                languageCode = "en"
            }
        } else {
            languageCode = "en"
        }
    }
    
    var bundle = Bundle.module
    
    if languageCode != "system" {
        // Try exact match
        if let path = Bundle.module.path(forResource: languageCode, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            bundle = langBundle
        } 
        // Try lowercased (SwiftPM sometimes lowercases resources)
        else if let path = Bundle.module.path(forResource: languageCode.lowercased(), ofType: "lproj"),
                  let langBundle = Bundle(path: path) {
            bundle = langBundle
        }
        // Specific fallback for zh-Hans
        else if languageCode == "zh-Hans",
                let path = Bundle.module.path(forResource: "zh-hans", ofType: "lproj"),
                let langBundle = Bundle(path: path) {
            bundle = langBundle
        }
    }
    
    return NSLocalizedString(key, tableName: nil, bundle: bundle, value: "", comment: "")
}
