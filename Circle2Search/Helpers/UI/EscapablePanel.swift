import AppKit

/// A custom NSPanel subclass that calls an `onDismiss` closure when the Escape key is pressed.
class EscapablePanel: NSPanel {
    
    /// Closure to be executed when the Escape key is pressed.
    var onDismiss: (() -> Void)?
    
    /// Intercepts the Escape key press (and other cancellation actions).
    override func cancelOperation(_ sender: Any?) {
        print("EscapablePanel: Escape key pressed, calling dismiss handler.")
        // Call the dismiss handler if it's set
        onDismiss?()
    }
    
    // Ensure the panel can become the key window to receive key events.
    override var canBecomeKey: Bool {
        return true
    }
    
    // Optional: Make it the main window as well if needed, though key is usually sufficient
    // override var canBecomeMain: Bool {
    //     return true
    // }
}
