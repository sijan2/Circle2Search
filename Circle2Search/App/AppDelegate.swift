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
        
        // Check permissions on launch (non-blocking)
        checkAllPermissions()
        
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
        
        // Listen for permission changes
        Task { @MainActor in
            self.setupPermissionMonitoring()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Optional: Cleanup before the application terminates.
        print("AppDelegate: Application Will Terminate")
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        
        // Stop permission monitoring (run on main actor)
        Task { @MainActor in
            PermissionManager.shared.stopMonitoringPermissions()
        }
        
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
    
    /// Check all required permissions on app launch
    private func checkAllPermissions() {
        Task { @MainActor in
            // Check screen recording permission (non-blocking, just status check)
            let screenRecordingGranted = PermissionManager.shared.checkScreenRecordingPermission()
            print("AppDelegate: Screen recording permission: \(screenRecordingGranted ? "granted" : "not granted")")
            
            // Check accessibility permission (will prompt if not granted)
            let accessibilityGranted = PermissionManager.shared.requestAccessibilityPermission(showPrompt: true)
            print("AppDelegate: Accessibility permission: \(accessibilityGranted ? "granted" : "not granted")")
            
            // If screen recording not granted, show a gentle reminder (not the full alert)
            if !screenRecordingGranted {
                print("AppDelegate: Screen recording permission not granted. Will prompt on first capture attempt.")
            }
        }
    }
    
    /// Set up monitoring for permission state changes
    @MainActor
    private func setupPermissionMonitoring() {
        // Listen for when permissions are granted
        PermissionManager.shared.permissionGranted
            .receive(on: DispatchQueue.main)
            .sink { permissionType in
                switch permissionType {
                case .screenRecording:
                    print("AppDelegate: Screen recording permission was just granted!")
                case .accessibility:
                    print("AppDelegate: Accessibility permission was just granted!")
                }
            }
            .store(in: &cancellables)
        
        // Listen for when permissions are denied
        PermissionManager.shared.permissionDenied
            .receive(on: DispatchQueue.main)
            .sink { permissionType in
                switch permissionType {
                case .screenRecording:
                    print("AppDelegate: Screen recording permission was denied")
                case .accessibility:
                    print("AppDelegate: Accessibility permission was denied")
                }
            }
            .store(in: &cancellables)
    }
    
    // Optional: Prevent app from terminating when last window is closed
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor @objc func handleAppDidBecomeActive() {
        print("AppDelegate: Application did become active.")
        
        // Refresh permission status when app becomes active
        // (in case user granted permission in System Settings)
        PermissionManager.shared.refreshPermissionStatus()
        
        // Check if overlayManager is initialized and overlay is visible
        if OverlayManager.shared.isOverlayVisible {
            print("AppDelegate: Overlay is visible, attempting to restore focus.")
            OverlayManager.shared.restoreFocusToOverlay()
        } else {
            print("AppDelegate: Overlay not visible or manager not ready, no focus restoration needed.")
        }
    }
}
