import Cocoa

class KeyAcceptingWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
    
    // Disable focus ring at window level
    override var initialFirstResponder: NSView? {
        get { return nil }
        set { }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            print("KeyAcceptingWindow --- ESC DETECTED")
        }
        super.keyDown(with: event)
    }
}
