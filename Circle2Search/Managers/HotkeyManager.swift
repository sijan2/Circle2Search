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
    
    // --- Double-Shift Detection ---
    private var globalEventMonitor: Any?
    private var lastShiftPressTime: TimeInterval = 0
    private var shiftPressCount: Int = 0
    private let doubleShiftThreshold: TimeInterval = 0.4  // 400ms window for double-tap
    private var useDoubleShiftHotkey: Bool = true  // Enable double-shift by default
    // ------------------------------
    
    // Keys for UserDefaults
    let keyCodeKey = "hotkeyCode"
    let modifiersKey = "hotkeyModifiers"
    let useDoubleShiftKey = "useDoubleShiftHotkey"
    
    // Default hotkey: Command+Shift+S (fallback)
    private let defaultKeyCode: UInt32 = 1  // 'S' key
    private let defaultModifiers: UInt32 = UInt32(cmdKey | shiftKey)
    
    private init() {
        // Load double-shift preference (default: true)
        useDoubleShiftHotkey = UserDefaults.standard.object(forKey: useDoubleShiftKey) == nil ? 
            true : UserDefaults.standard.bool(forKey: useDoubleShiftKey)
        
        // Check if values exist, if not, set default to Command+Shift+S
        if UserDefaults.standard.object(forKey: keyCodeKey) == nil {
            print("HotkeyManager: No hotkey stored, defaulting to Command+Shift+S.")
            UserDefaults.standard.set(Int(defaultKeyCode), forKey: keyCodeKey)
            UserDefaults.standard.set(Int(defaultModifiers), forKey: modifiersKey)
        }
        
        setupCurrentHotkey()
        
        // Always set up double-shift listener if enabled
        if useDoubleShiftHotkey {
            setupDoubleShiftListener()
        }
    }
    
    deinit {
        unregisterCarbonHotkey()
        removeDoubleShiftListener()
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
    
    // MARK: - Double-Shift Detection (like Android Circle to Search)
    
    /// Checks if the app has Accessibility permissions (required for global event monitoring)
    private func checkAccessibilityPermissions() -> Bool {
        // Check if we have accessibility permissions
        let trusted = AXIsProcessTrusted()
        
        if !trusted {
            print("HotkeyManager: Accessibility permissions not granted")
            // Only prompt once - check if we've already prompted
            let hasPromptedKey = "hasPromptedForAccessibility"
            if !UserDefaults.standard.bool(forKey: hasPromptedKey) {
                UserDefaults.standard.set(true, forKey: hasPromptedKey)
                
                // Open System Preferences to Accessibility
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
            }
        }
        
        return trusted
    }
    
    /// Sets up a global event monitor to detect double-shift key press
    private func setupDoubleShiftListener() {
        // Remove existing monitor if any
        removeDoubleShiftListener()
        
        // Check for accessibility permissions first
        guard checkAccessibilityPermissions() else {
            print("HotkeyManager: Cannot setup double-shift listener without Accessibility permissions")
            print("HotkeyManager: Please grant Accessibility permissions in System Settings > Privacy & Security > Accessibility")
            return
        }
        
        // Monitor for flagsChanged events (modifier key changes)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        
        // Also add local monitor for when app is in foreground
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        
        print("HotkeyManager: Double-shift listener activated (press Shift twice quickly to trigger)")
    }
    
    /// Removes the global event monitor for double-shift detection
    private func removeDoubleShiftListener() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
            print("HotkeyManager: Double-shift listener removed")
        }
    }
    
    /// Handles modifier key flag changes to detect double-shift
    private func handleFlagsChanged(_ event: NSEvent) {
        // Check if ONLY shift is pressed (no other modifiers)
        let shiftPressed = event.modifierFlags.contains(.shift)
        let otherModifiers = event.modifierFlags.intersection([.command, .option, .control])
        
        // We only care about shift key DOWN events with no other modifiers
        guard shiftPressed && otherModifiers.isEmpty else {
            // If shift was released or other modifiers are pressed, don't count it
            return
        }
        
        let currentTime = Date().timeIntervalSince1970
        let timeSinceLastPress = currentTime - lastShiftPressTime
        
        if timeSinceLastPress < doubleShiftThreshold {
            // Second shift press within threshold - trigger!
            shiftPressCount += 1
            
            if shiftPressCount >= 2 {
                print("HotkeyManager: Double-Shift detected! Triggering capture...")
                shiftPressCount = 0
                lastShiftPressTime = 0
                
                // Trigger the hotkey action
                DispatchQueue.main.async { [weak self] in
                    self?.hotkeyPressedSubject.send(())
                }
            }
        } else {
            // First press or too slow - start counting
            shiftPressCount = 1
            lastShiftPressTime = currentTime
        }
    }
    
    /// Enable or disable double-shift hotkey
    func setDoubleShiftEnabled(_ enabled: Bool) {
        useDoubleShiftHotkey = enabled
        UserDefaults.standard.set(enabled, forKey: useDoubleShiftKey)
        
        if enabled {
            setupDoubleShiftListener()
        } else {
            removeDoubleShiftListener()
        }
        
        print("HotkeyManager: Double-shift hotkey \(enabled ? "enabled" : "disabled")")
    }
    
    /// Returns whether double-shift hotkey is enabled
    var isDoubleShiftEnabled: Bool {
        return useDoubleShiftHotkey
    }
    
    /// Call this to retry setting up the double-shift listener after permissions are granted
    func retryDoubleShiftSetup() {
        if useDoubleShiftHotkey && globalEventMonitor == nil {
            setupDoubleShiftListener()
        }
    }
    
    /// Check if accessibility permissions are currently granted
    var hasAccessibilityPermissions: Bool {
        return AXIsProcessTrusted()
    }
}

// Helper for FourCharCode (used by Carbon)
extension FourCharCode {
    init(_ string: String) {
        assert(string.count == 4)
        self = string.utf16.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
