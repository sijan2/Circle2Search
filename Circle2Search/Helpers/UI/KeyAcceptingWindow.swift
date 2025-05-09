import Cocoa

class KeyAcceptingWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }

    override func keyDown(with event: NSEvent) {
        print("KeyAcceptingWindow --- keyDown: keyCode \(event.keyCode), characters: \(event.characters ?? "nil")")
        if event.keyCode == 53 { // 53 is the keycode for ESC
            print("KeyAcceptingWindow --- ESC DETECTED AT WINDOW LEVEL")
            // We don't want the window to handle it directly here if the event monitor in OverlayView should.
            // So, we'll pass it on. If the monitor consumes it, fine. If not, super will handle it (or ignore it).
        }
        super.keyDown(with: event) // Important to call super, so events can propagate further if not handled.
    }
}
