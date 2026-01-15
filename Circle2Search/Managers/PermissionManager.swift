// PermissionManager.swift
// Handles all permission-related logic for Circle2Search

import Foundation
import AppKit
import ScreenCaptureKit
import Combine

/// Manages screen recording and accessibility permissions for macOS
@MainActor
final class PermissionManager: ObservableObject {
    
    // MARK: - Singleton
    static let shared = PermissionManager()
    
    // MARK: - Published Properties
    @Published private(set) var screenRecordingStatus: PermissionStatus = .unknown
    @Published private(set) var accessibilityStatus: PermissionStatus = .unknown
    @Published private(set) var hasPromptedForScreenRecording: Bool = false
    
    // MARK: - Publishers
    let permissionGranted = PassthroughSubject<PermissionType, Never>()
    let permissionDenied = PassthroughSubject<PermissionType, Never>()
    
    // MARK: - Private Properties
    private var permissionCheckTimer: Timer?
    private let userDefaults = UserDefaults.standard
    
    // Keys for UserDefaults
    private enum Keys {
        static let hasPromptedScreenRecording = "PermissionManager.hasPromptedScreenRecording"
        static let hasPromptedAccessibility = "PermissionManager.hasPromptedAccessibility"
        static let lastKnownBundleVersion = "PermissionManager.lastKnownBundleVersion"
    }
    
    // MARK: - Types
    
    enum PermissionType {
        case screenRecording
        case accessibility
    }
    
    enum PermissionStatus: Equatable {
        case unknown
        case notDetermined
        case denied
        case granted
        
        var isGranted: Bool {
            self == .granted
        }
        
        var description: String {
            switch self {
            case .unknown: return "Unknown"
            case .notDetermined: return "Not Determined"
            case .denied: return "Denied"
            case .granted: return "Granted"
            }
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        // Load persisted state
        hasPromptedForScreenRecording = userDefaults.bool(forKey: Keys.hasPromptedScreenRecording)
        
        // Check if this is a new version (which might need re-permission)
        checkForVersionChange()
        
        // Initial permission check
        refreshPermissionStatus()
    }
    
    // MARK: - Public Methods
    
    /// Checks current screen recording permission without prompting
    func checkScreenRecordingPermission() -> Bool {
        let hasPermission = CGPreflightScreenCaptureAccess()
        screenRecordingStatus = hasPermission ? .granted : .denied
        return hasPermission
    }
    
    /// Requests screen recording permission if not already granted
    /// Returns true if permission is granted, false otherwise
    func requestScreenRecordingPermission() async -> Bool {
        // First check if already granted
        if CGPreflightScreenCaptureAccess() {
            print("PermissionManager: Screen recording already granted")
            screenRecordingStatus = .granted
            return true
        }
        
        // Check if we've already prompted and user denied
        if hasPromptedForScreenRecording {
            print("PermissionManager: Already prompted before, checking status...")
            // User was prompted before, just check current status
            let currentStatus = CGPreflightScreenCaptureAccess()
            screenRecordingStatus = currentStatus ? .granted : .denied
            
            if !currentStatus {
                // Permission still denied, show guidance
                showPermissionDeniedAlert()
            }
            return currentStatus
        }
        
        // First time request - this will show the system prompt
        print("PermissionManager: First time requesting screen recording permission")
        let granted = CGRequestScreenCaptureAccess()
        
        // Mark that we've prompted
        hasPromptedForScreenRecording = true
        userDefaults.set(true, forKey: Keys.hasPromptedScreenRecording)
        
        if granted {
            print("PermissionManager: Permission granted by user")
            screenRecordingStatus = .granted
            permissionGranted.send(.screenRecording)
        } else {
            print("PermissionManager: Permission denied by user")
            screenRecordingStatus = .denied
            permissionDenied.send(.screenRecording)
            
            // Show guidance to user
            showPermissionDeniedAlert()
        }
        
        return granted
    }
    
    /// Alternative method using ScreenCaptureKit to verify permission
    /// This is more reliable as it actually tests the capture capability
    func verifyScreenCapturePermissionWithSCK() async -> Bool {
        do {
            // Attempting to get shareable content will fail if no permission
            let _ = try await SCShareableContent.current
            print("PermissionManager: SCK verification successful - permission granted")
            screenRecordingStatus = .granted
            return true
        } catch {
            print("PermissionManager: SCK verification failed - \(error.localizedDescription)")
            // This could be due to no permission or other errors
            screenRecordingStatus = .denied
            return false
        }
    }
    
    /// Checks accessibility permission status
    func checkAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        accessibilityStatus = trusted ? .granted : .denied
        return trusted
    }
    
    /// Requests accessibility permission with optional prompt
    func requestAccessibilityPermission(showPrompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() {
            accessibilityStatus = .granted
            return true
        }
        
        if showPrompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            let _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        
        accessibilityStatus = .denied
        return false
    }
    
    /// Refreshes all permission statuses
    func refreshPermissionStatus() {
        let _ = checkScreenRecordingPermission()
        let _ = checkAccessibilityPermission()
        print("PermissionManager: Refreshed - Screen: \(screenRecordingStatus.description), Accessibility: \(accessibilityStatus.description)")
    }
    
    /// Opens System Settings to the Screen Recording pane
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Opens System Settings to the Accessibility pane
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Starts monitoring for permission changes
    func startMonitoringPermissions() {
        // Stop any existing timer
        stopMonitoringPermissions()
        
        // Check permissions every 2 seconds when app is active
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissionStatus()
            }
        }
        print("PermissionManager: Started monitoring permissions")
    }
    
    /// Stops monitoring for permission changes
    func stopMonitoringPermissions() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }
    
    /// Resets the prompted state (useful for testing or after app updates)
    func resetPromptedState() {
        hasPromptedForScreenRecording = false
        userDefaults.set(false, forKey: Keys.hasPromptedScreenRecording)
        userDefaults.set(false, forKey: Keys.hasPromptedAccessibility)
        print("PermissionManager: Reset prompted state")
    }
    
    // MARK: - Private Methods
    
    /// Check if the app version changed (new build might need re-permission)
    private func checkForVersionChange() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let lastKnownVersion = userDefaults.string(forKey: Keys.lastKnownBundleVersion)
        
        if lastKnownVersion != currentVersion {
            print("PermissionManager: Version changed from \(lastKnownVersion ?? "nil") to \(currentVersion)")
            // Don't reset prompted state on version change, but refresh status
            userDefaults.set(currentVersion, forKey: Keys.lastKnownBundleVersion)
        }
    }
    
    /// Shows an alert when permission is denied
    private func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
            Circle2Search needs Screen Recording permission to capture your screen.
            
            To grant permission:
            1. Click "Open System Settings"
            2. Find "Circle2Search" in the list
            3. Toggle it ON
            4. You may need to restart the app
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:
            openScreenRecordingSettings()
            // Start monitoring for when user grants permission
            startMonitoringPermissions()
            
        case .alertSecondButtonReturn:
            // Try again - will re-check permission
            Task {
                let _ = await requestScreenRecordingPermission()
            }
            
        default:
            break
        }
    }
    
    deinit {
        permissionCheckTimer?.invalidate()
    }
}

// MARK: - Convenience Extension for Quick Checks

extension PermissionManager {
    /// Quick check if all required permissions are granted
    var allPermissionsGranted: Bool {
        screenRecordingStatus.isGranted && accessibilityStatus.isGranted
    }
    
    /// Check if screen recording is available (granted)
    var canCaptureScreen: Bool {
        screenRecordingStatus.isGranted
    }
    
    /// Check if accessibility features can be used
    var canUseAccessibility: Bool {
        accessibilityStatus.isGranted
    }
}
