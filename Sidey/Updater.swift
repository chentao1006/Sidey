import Foundation
import Sparkle

class UpdaterViewModel: ObservableObject {
    private let controller: SPUStandardUpdaterController
    
    @Published var canCheckForUpdates = false
    
    init() {
        // The standard controller handles most of the Sparkle logic automatically
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
    
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
