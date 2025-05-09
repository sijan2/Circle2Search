import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>() // Store subscriptions

    // --- Hold a persistent instance of CaptureController --- 
    @MainActor private let captureController = CaptureController()
    // -------------------------------------------------------

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy once the app has launched
        NSApp.setActivationPolicy(.accessory)
        
        // Check and prompt for accessibility permissions if needed
        checkAccessibilityPermissions()
        
        // Force-close the settings window if it opens automatically
        DispatchQueue.main.async {
            // Find window by title (Adjust title if you changed it in WindowGroup)
            if let settingsWindow = NSApp.windows.first(where: { $0.title == "Circle2Search Settings" }) {
                print("AppDelegate: Found settings window, closing it.")
                settingsWindow.close()
            }
        }
        print("AppDelegate: Activation policy set to accessory.")

        // Initialize and listen for hotkey presses
        HotkeyManager.shared.hotkeyPressed
            .sink { _ in
                // Make sure this runs on the main thread
                DispatchQueue.main.async { 
                    print("AppDelegate: Hotkey pressed! Triggering capture controller.")
                    print("DEBUG: HOTKEY SINK IS CALLING startCapture()")
                    self.captureController.startCapture()
                }
            }
            .store(in: &cancellables) // Store subscription
        
        // --- Add listener for menu bar trigger ---
        NotificationCenter.default.publisher(for: .menuTriggerCapture)
            .sink { _ in
                 DispatchQueue.main.async { 
                     print("AppDelegate: Menu trigger received! Triggering capture controller.")
                     print("DEBUG: MENU SINK IS CALLING startCapture()")
                     self.captureController.startCapture()
                 }
            }
            .store(in: &cancellables)
        // --------------------------------------

        // --- Add Workspace Change Observer ---
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        print("AppDelegate: Added workspace change observer.")

        // Add observer for application did become active
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAppDidBecomeActive),
                                               name: NSApplication.didBecomeActiveNotification,
                                               object: nil)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Optional: Cleanup before the application terminates.
        print("AppDelegate: Application Will Terminate")
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        
        // Remove observer
        NotificationCenter.default.removeObserver(self,
                                                  name: NSApplication.didBecomeActiveNotification,
                                                  object: nil)
    }
    
    // --- Selector for Workspace Change --- 
    @objc func workspaceDidChange(_ notification: Notification) {
        print("AppDelegate: Workspace changed!")
        // Post our custom notification to be picked up by the main app UI
        NotificationCenter.default.post(name: .workspaceDidChange, object: nil)
    }
    
    /// Check if we have accessibility permissions and prompt the user if needed
    private func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if accessEnabled {
            print("AppDelegate: Accessibility permissions granted")
        } else {
            print("AppDelegate: Accessibility permissions needed - prompt shown")
            // Note: The above AXIsProcessTrustedWithOptions call will show the prompt
            // We can't do much else here as the user must approve manually
        }
    }
    
    // Optional: Prevent app from terminating when last window is closed
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @objc func handleAppDidBecomeActive() {
        print("AppDelegate: Application did become active.")
        // Check if overlayManager is initialized and overlay is visible
        if OverlayManager.shared.isOverlayVisible {
            print("AppDelegate: Overlay is visible, attempting to restore focus.")
            OverlayManager.shared.restoreFocusToOverlay()
        } else {
            print("AppDelegate: Overlay not visible or manager not ready, no focus restoration needed.")
        }
    }
}
