import SwiftUI
import AppKit

struct ScreenshotOverlayView: View {
    var screenshot: NSImage? // The captured screenshot
    @State private var isActivated: Bool = false // Controls glow activation

    var body: some View {
        ZStack {
            if let nsImage = screenshot {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill() // Ensure it covers the whole screen
            } else {
                // Fallback: Show a dark background if screenshot is missing
                Color.black.opacity(0.5)
            }

            // Overlay the noise and glow view
            // NoiseOverlayView now manages its own activation state internally
//            NoiseOverlayView() // Temporarily commented out for testing screenshot quality
        }
        .edgesIgnoringSafeArea(.all)
        .onAppear { 
            // Activate glow slightly after appearing for effect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isActivated = true
            }
        }
        .onDisappear { 
            isActivated = false // Deactivate glow when hidden
        }
        // We might need to pass down other state or notifications if needed
    }
}
