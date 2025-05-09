import Foundation
import AppKit // Use AppKit for NSEvent AND Carbon constants (like cmdKey)
import Carbon // Need Carbon for RegisterEventHotKey AND constants
import Combine

class HotkeyManager {
    static let shared = HotkeyManager()
    
    // Internal subject for sending events
    private let hotkeyPressedSubject = PassthroughSubject<Void, Never>()
    
    // Public publisher that ensures delivery on main thread
    var hotkeyPressed: AnyPublisher<Void, Never> {
        hotkeyPressedSubject
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    // --- Carbon Hotkey Properties ---
    // Define the hotkey ID statically so it's not captured by the C closure
    private static let carbonHotkeyID: EventHotKeyID = { 
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = FourCharCode("htk1") // Unique signature
        hotKeyID.id = 1                      // Unique ID
        return hotKeyID
    }()
    
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    // -----------------------------
    
    // Keys for UserDefaults
    let keyCodeKey = "hotkeyCode"
    let modifiersKey = "hotkeyModifiers"
    
    // Default hotkey: Command+Shift+S
    private let defaultKeyCode: UInt32 = 1  // 'S' key
    private let defaultModifiers: UInt32 = UInt32(cmdKey | shiftKey)
    
    private init() {
        // Check if values exist, if not, set default to Command+Shift+S
        if UserDefaults.standard.object(forKey: keyCodeKey) == nil {
            print("HotkeyManager: No hotkey stored, defaulting to Command+Shift+S.")
            UserDefaults.standard.set(Int(defaultKeyCode), forKey: keyCodeKey)
            UserDefaults.standard.set(Int(defaultModifiers), forKey: modifiersKey)
        }
        setupCurrentHotkey()
    }
    
    deinit {
        unregisterCarbonHotkey()
    }
    
    // Main setup function: Reads UserDefaults and activates the correct listener
    func setupCurrentHotkey() {
        let keyCode = UInt32(UserDefaults.standard.integer(forKey: keyCodeKey))
        let modifiers = UInt32(UserDefaults.standard.integer(forKey: modifiersKey))
        
        // Stop whichever listener might be active before starting the new one
        unregisterCarbonHotkey()
        
        print("HotkeyManager: Setting up Carbon hotkey listener (Code: \(keyCode), Modifiers: \(modifiers)).")
        registerCarbonHotkey(keyCode: keyCode, modifiers: modifiers)
    }
    
    // --- Carbon Hotkey Methods ---
    private func registerCarbonHotkey(keyCode: UInt32, modifiers: UInt32) {
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        // Ensure previous handler is removed before installing a new one
        if eventHandlerRef != nil {
            RemoveEventHandler(eventHandlerRef!)
            eventHandlerRef = nil
        }
        
        // Install handler
        let hotkeyEventHandler: EventHandlerUPP = { 
            (nextHandler, event, userData) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            
            if hkID.signature == HotkeyManager.carbonHotkeyID.signature && hkID.id == HotkeyManager.carbonHotkeyID.id {
                print("Carbon Hotkey Pressed!")
                // Use DispatchQueue.main to safely interact with our Swift objects
                DispatchQueue.main.async {
                    HotkeyManager.shared.hotkeyPressedSubject.send(())
                }
                return OSStatus(noErr) // Explicit cast
            }
            return OSStatus(eventNotHandledErr) // Explicit cast
        }
        
        // Install the handler without passing self as context
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &eventType, nil, &eventHandlerRef)
        
        // Register the hotkey
        let status = RegisterEventHotKey(keyCode, modifiers, HotkeyManager.carbonHotkeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        
        if status != noErr {
            print("HotkeyManager: Error registering Carbon hotkey: \(status)")
            unregisterCarbonHotkey() // Clean up if registration failed
        } else {
            print("HotkeyManager: Carbon hotkey registered successfully.")
        }
    }
    
    private func unregisterCarbonHotkey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            print("HotkeyManager: Carbon hotkey unregistered.")
        }
        if let eventHandlerRef = eventHandlerRef {
             RemoveEventHandler(eventHandlerRef)
             self.eventHandlerRef = nil
        }
    }
    // ---------------------------
    
    // Called by ContentView when a NEW standard hotkey is recorded
    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        print("HotkeyManager: Updating stored hotkey to Code: \(keyCode), Modifiers: \(modifiers)")
        UserDefaults.standard.set(Int(keyCode), forKey: keyCodeKey)
        UserDefaults.standard.set(Int(modifiers), forKey: modifiersKey)
        setupCurrentHotkey() // Stop old listener, start new one based on saved values
    }
}

// Helper for FourCharCode (used by Carbon)
extension FourCharCode {
    init(_ string: String) {
        assert(string.count == 4)
        self = string.utf16.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
