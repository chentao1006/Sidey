import SwiftUI
import ApplicationServices
import ScreenCaptureKit

class DockingState: ObservableObject {
    static let shared = DockingState()
    @Published var isRightSide: Bool = true
    
    private init() {}
}
