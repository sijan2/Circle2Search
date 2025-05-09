import SwiftUI
import Carbon

// NSViewRepresentable to wrap the key event capturing view
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onHotkeyRecorded: (UInt32, UInt32) -> Void // Closure to call when hotkey is recorded

    func makeNSView(context: Context) -> RecordingKeyView {
        let view = RecordingKeyView()
        view.onHotkeyRecorded = {
            keyCode, modifiers in
            // Basic validation: require at least one modifier OR check if it's a function key (F1-F20)
            // Or allow specific non-modifier keys like Escape if desired.
            let isFunctionKey = (keyCode >= kVK_F1 && keyCode <= kVK_F20)
            if modifiers > UInt32(0) || isFunctionKey {
                onHotkeyRecorded(keyCode, modifiers)
                isRecording = false // Stop recording after successful capture
            } else {
                print("Invalid hotkey: Requires at least one modifier (Cmd, Opt, Ctrl, Shift) or be a function key (F1-F20).")
                // Optionally provide user feedback here
            }
        }
        view.onCancelRecording = {
            isRecording = false // Allow cancelling via Escape
        }
        
        // Make it focusable immediately
        DispatchQueue.main.async {
             view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: RecordingKeyView, context: Context) {
        // If isRecording becomes true externally, ensure it becomes first responder
         if isRecording && nsView.window?.firstResponder != nsView {
             DispatchQueue.main.async { // Ensure UI updates happen on the main thread
                 nsView.window?.makeFirstResponder(nsView)
             }
         }
    }
}

// Custom NSView to handle key events
class RecordingKeyView: NSView {
    var onHotkeyRecorded: ((UInt32, UInt32) -> Void)?
    var onCancelRecording: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        // Ignore modifier-only key presses
        if event.keyCode >= kVK_Shift && event.keyCode <= kVK_RightCommand { return }
        
        // Cancel recording on Escape key
        if event.keyCode == kVK_Escape {
             onCancelRecording?()
             return
        }
        
        // Extract Carbon modifiers (excluding Caps Lock)
        let carbonModifiers = event.modifierFlags.carbonFlags & ~UInt32(alphaLock)
         
        print("Recorded: KeyCode=\(event.keyCode), Modifiers=\(carbonModifiers)")
        onHotkeyRecorded?(UInt32(event.keyCode), carbonModifiers)
    }
    
    // Draw a visual indicator (optional)
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // You could draw a border or background to indicate it's active
        NSColor.orange.withAlphaComponent(0.3).setFill()
        dirtyRect.fill()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attrs = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 10),
                     NSAttributedString.Key.paragraphStyle: paragraphStyle,
                     NSAttributedString.Key.foregroundColor: NSColor.black]
        let string = "Recording... (Press Esc to cancel)"
        string.draw(with: bounds.insetBy(dx: 5, dy: 5), options: .usesLineFragmentOrigin, attributes: attrs)

    }
}

// Helper extension to convert NSEvent modifier flags to Carbon flags
extension NSEvent.ModifierFlags {
    var carbonFlags: UInt32 {
        var carbonFlags: UInt32 = 0
        if contains(.control) { carbonFlags |= UInt32(controlKey) }
        if contains(.option) { carbonFlags |= UInt32(optionKey) }
        if contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        if contains(.command) { carbonFlags |= UInt32(cmdKey) }
        // Note: We explicitly exclude capsLock: if contains(.capsLock) { carbonFlags |= alphaLock }
        return carbonFlags
    }
}
