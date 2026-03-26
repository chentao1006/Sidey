import Foundation

#if !APPSTORE
import Sparkle
#endif

class UpdaterViewModel: ObservableObject {
    #if !APPSTORE
    private let controller: SPUStandardUpdaterController
    #endif
    
    @Published var canCheckForUpdates = false
    
    init() {
        #if !APPSTORE
        // The standard controller handles most of the Sparkle logic automatically
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        #else
        // Dummy implementation for App Store
        canCheckForUpdates = false
        #endif
    }
    
    func checkForUpdates() {
        #if !APPSTORE
        controller.checkForUpdates(nil)
        #endif
    }
}

