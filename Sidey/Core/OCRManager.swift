import AppKit
import Vision
import ScreenCaptureKit

class OCRManager {
    static let shared = OCRManager()
    
    /// Use Vision framework to extract text from a CGImage
    func performOCR(on cgImage: CGImage, completion: @escaping (String) -> Void) {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        let request = VNRecognizeTextRequest { (request, error) in
            if let error = error {
                print("OCR Error: \(error)")
                completion("")
                return
            }
            
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion("")
                return
            }
            
            let recognizedStrings = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            
            completion(recognizedStrings.joined(separator: "\n"))
        }
        
        // Choose .accurate for best results, which may take longer
        request.recognitionLevel = .accurate
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try requestHandler.perform([request])
            } catch {
                print("OCR Request Error: \(error)")
                completion("")
            }
        }
    }
    
    /// Capture the entire screen and extract text
    func captureMainScreenAndOCR(completion: @escaping (String) -> Void) {
        captureScreenAndOCR(for: NSScreen.main ?? NSScreen.screens.first!, completion: completion)
    }
    
    /// Capture a specific screen or app window and extract text
    func captureScreenAndOCR(for screen: NSScreen, targetApp: NSRunningApplication? = nil, completion: @escaping (String) -> Void) {
        if #available(macOS 14.0, *) {
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    
                    let displayID: CGDirectDisplayID
                    if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                        displayID = id
                    } else {
                        displayID = CGMainDisplayID()
                    }
                    
                    guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                        await MainActor.run { self.handleCaptureError(completion: completion) }
                        return
                    }
                    
                    // IF we have a target app, filter the content to ONLY that app's windows
                    let filter: SCContentFilter
                    if let app = targetApp, let scApp = content.applications.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                        // Capture only the windows of this specific application
                        filter = SCContentFilter(display: scDisplay, including: [scApp], exceptingWindows: [])
                    } else {
                        // Capture the whole screen
                        filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
                    }
                    
                    let config = SCStreamConfiguration()
                    // Set scale to 2 for better OCR quality on Retina displays
                    config.width = Int(scDisplay.width)
                    config.height = Int(scDisplay.height)
                    config.showsCursor = false
                    
                    // Capture image
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    
                    await MainActor.run {
                        self.performOCR(on: image, completion: completion)
                    }
                } catch {
                    print("Capture Error: \(error)")
                    await MainActor.run { self.handleCaptureError(completion: completion) }
                }
            }
        } else {
            completion("")
        }
    }
    
    private func handleCaptureError(completion: @escaping (String) -> Void) {
        if !checkScreenRecordingPermission() {
            completion(L("Missing 'Screen Recording' permission. Please grant permission in System Settings > Security & Privacy."))
        } else {
            completion("")
        }
    }
    
    func checkScreenRecordingPermission() -> Bool {
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        } else {
            return true
        }
    }
}
