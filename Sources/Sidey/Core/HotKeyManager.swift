import Foundation
import Carbon
import AppKit

class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    private var eventHotKeyRef: EventHotKeyRef?
    
    private var keyCode: Int {
        let val = UserDefaults.standard.integer(forKey: "hotKeyKeyCode")
        return val == 0 ? kVK_Space : val
    }
    
    private var modifiers: Int {
        let val = UserDefaults.standard.integer(forKey: "hotKeyModifiers")
        return val == 0 ? Int(cmdKey | optionKey) : val
    }
    
    init() {
        registerHotkey()
    }
    
    func registerHotkey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(fourCharCode: "CXAI")
        hotKeyID.id = 1
        
        if let ref = eventHotKeyRef {
            UnregisterEventHotKey(ref)
        }
        
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        InstallEventHandler(GetApplicationEventTarget(), { nextHandler, theEvent, userData in
            guard let userData = userData else { return noErr }
            let selfPtr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            selfPtr.hotKeyPressed()
            return noErr
        }, 1, &eventType, ptr, nil)
        
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &eventHotKeyRef)
    }
    
    func hotKeyPressed() {
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: Notification.Name("CXAIToggleMainWindow"), object: nil)
        }
    }
}

extension OSType {
    init(fourCharCode: String) {
        var result: OSType = 0
        if let data = fourCharCode.data(using: .macOSRoman) {
            for byte in data {
                result = (result << 8) | OSType(byte)
            }
        }
        self = result
    }
}
