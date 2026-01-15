import Foundation

// Define custom notification names
extension Notification.Name {
    /// Posted when the active macOS workspace (desktop space) changes.
    static let workspaceDidChange = Notification.Name("com.yourcompany.Circle2Search.workspaceDidChange")
    
    /// Posted when the global hotkey is pressed (handled by AppDelegate).
    static let hotkeyPressedNotification = Notification.Name("com.yourcompany.Circle2Search.hotkeyPressed")
    
    // Keep existing capture notifications if they are used elsewhere,
    // otherwise, they could be removed if only the workspace change matters.
    static let captureComplete = Notification.Name("com.yourcompany.Circle2Search.captureComplete")
    static let captureCancelled = Notification.Name("com.yourcompany.Circle2Search.captureCancelled")

    /// Posted when the menu bar 'Capture Screen' item is clicked.
    static let menuTriggerCapture = Notification.Name("com.yourcompany.Circle2Search.menuTriggerCapture")
}
