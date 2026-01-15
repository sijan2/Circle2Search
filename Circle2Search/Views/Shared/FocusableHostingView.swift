import SwiftUI
import AppKit

class FocusableHostingView<Content: View>: NSHostingView<Content> {
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    // Disable focus ring
    override func drawFocusRingMask() {
        // Don't draw anything
    }
    
    override var focusRingMaskBounds: NSRect {
        return .zero
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        print("FocusableHostingView: becomeFirstResponder() called. super.becomeFirstResponder() returned: \(didBecome). Explicitly returning true.")
        return true // Ensure we report success if super does or even if it doesn't, if we intend to handle events
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        print("FocusableHostingView: resignFirstResponder() called. super.resignFirstResponder() returned: \(didResign).")
        return didResign
    }

    override func keyDown(with event: NSEvent) {
        print("FocusableHostingView --- keyDown: keyCode \(event.keyCode), characters: \(event.characters ?? "nil"), charactersIgnoringModifiers: \(event.charactersIgnoringModifiers ?? "nil")")
        if event.keyCode == 53 { // ESC key
            print("FocusableHostingView --- ESC DETECTED")
            // We could choose to handle it here, or let it propagate.
            // For now, just log and let OverlayView's monitor or KeyAcceptingWindow handle it.
        }
        // It's important to call super.keyDown if you're not fully handling the event,
        // to allow propagation up the responder chain or to default behaviors.
        // However, if this view is intended to be the primary handler or if SwiftUI content
        // needs to see it via .onKeyPress, careful consideration is needed.
        // If OverlayView's .onKeyPress or local monitor handles it, we might not need to call super
        // or call it conditionally.
        // For now, let's call super to maintain default propagation if not handled by SwiftUI below this NSHostingView.
        super.keyDown(with: event)
    }

    // Optional: To see if mouse events are being captured if needed for focus
    /*
    override func mouseDown(with event: NSEvent) {
        print("FocusableHostingView --- mouseDown")
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    */

    // Designated Initializer - satisfies the NSHostingView requirement
    required init(rootView: Content) {
        super.init(rootView: rootView)
        // Any specific default setup for FocusableHostingView can go here
    }

    // Convenience Initializer for setting frame, used by OverlayManager
    convenience init(rootView: Content, frame: NSRect = .zero) {
        self.init(rootView: rootView) // Calls the designated initializer of this class
        if frame != .zero { // Check if frame is explicitly provided and non-zero
            self.frame = frame
        }
        // If frame is .zero, it will use whatever frame was set by self.init(rootView: rootView)
        // or its super.init(rootView: rootView) chain.
    }

    @objc required dynamic init?(coder aDecoder: NSCoder) {
        // If not supporting NIBs/Storyboards for this custom view
        fatalError("init(coder:) has not been implemented for FocusableHostingView")
    }
}
