import SwiftUI
import AVFoundation
import Cocoa

// Manages the overlay window which hosts the SwiftUI OverlayView
class OverlayManager: ObservableObject {
    static let shared = OverlayManager()
    
    @Published var showOverlay = false
    @Published var isWindowVisible: Bool = false // KVO observable
    @Published var isOverlayVisible = false
    @Published var isWindowActuallyVisible = true
    @Published var shouldPauseMetalRendering: Bool = false // New property

    private var overlayWindow: KeyAcceptingWindow?
    var overlayContentView: NSView? // Store the content view (internal access is default)
    private var currentCompletion: ((Path?, String?) -> Void)? // UPDATED: Signature for brushedText
    private var previousActiveApp: NSRunningApplication? // Store the app that was active before
    private var currentDetailedRegions: [DetailedTextRegion]? // Store the detailed regions
    private var visibilityObservation: NSKeyValueObservation?

    // Function to show the overlay
    func showOverlay(backgroundImage image: CGImage?, detailedTextRegions: [DetailedTextRegion]?, previousApp: NSRunningApplication?, completion: @escaping (Path?, String?) -> Void) { // UPDATED signature
        guard overlayWindow == nil else {
            print("Overlay already shown.")
            // If needed, you could potentially update the image here
            // by finding the NSHostingView and updating its rootView,
            // but that adds complexity. A simple dismiss/re-show might be easier.
            return
        }

        currentCompletion = completion
        self.currentDetailedRegions = detailedTextRegions // Store detailed regions
        self.previousActiveApp = previousApp

        // Get screen details
        guard let screen = NSScreen.main else {
            print("Error: Could not get main screen.")
            completion(nil, nil)
            return
        }

        // Ensure we actually received an image
        guard let validImage = image else {
             print("OverlayManager: Received nil image for overlay.")
             completion(nil, nil)
             return
        }

        // Set the visibility state to true BEFORE creating the view
        // This ensures the binding passed to OverlayView starts in the correct state
        self.isOverlayVisible = true
        self.shouldPauseMetalRendering = false // For a new overlay, ensure rendering is not paused.

        // --- Create the SwiftUI View ---
        // Pass the CGImage, the binding to isOverlayVisible, and the completion handler
        // Pass self (the OverlayManager instance) as well
        let swiftUIView = OverlayView(
            overlayManager: self, 
            backgroundImage: validImage,
            detailedTextRegions: self.currentDetailedRegions, // Pass detailed regions
            showOverlay: Binding(
                get: { self.isOverlayVisible },
                set: { newValue in
                    if !newValue && self.isOverlayVisible { 
                        self.dismissOverlay()
                    }
                    self.isOverlayVisible = newValue
                }
            ),
            completion: { [weak self] path, brushedTextFromOverlay in // UPDATED: Expecting brushedText
                self?.handleSelectionCompletion(path: path, brushedText: brushedTextFromOverlay)
            }
        )

        // --- Create and Configure Hosting View for SwiftUI ---
        let hostingView = FocusableHostingView(rootView: swiftUIView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.frame = screen.frame
        hostingView.layer?.backgroundColor = CGColor.clear
        hostingView.layer?.borderWidth = 0
        hostingView.layer?.borderColor = nil

        // --- Create the Window ---
        overlayWindow = KeyAcceptingWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // Configure the window
        overlayWindow?.isOpaque = false
        overlayWindow?.backgroundColor = .clear
        overlayWindow?.level = .floating
        overlayWindow?.collectionBehavior = [.managed, .transient, .fullScreenAuxiliary]
        overlayWindow?.contentView = hostingView
        self.overlayContentView = hostingView
        overlayWindow?.hasShadow = false
        overlayWindow?.ignoresMouseEvents = false
        overlayWindow?.autorecalculatesKeyViewLoop = false

        NSApp.activate(ignoringOtherApps: true)
        overlayWindow?.makeKeyAndOrderFront(nil)

        // Attempt to make the hosting view the first responder
        // It's crucial that the view can accept first responder status.
        print("OverlayManager: About to make hostingView first responder. Current firstResponder: \(String(describing: overlayWindow?.firstResponder))")
        let MFRSuccess = overlayWindow?.makeFirstResponder(hostingView)
        print("OverlayManager: Attempted to make hostingView first responder. Success: \(String(describing: MFRSuccess)). Current firstResponder: \(String(describing: overlayWindow?.firstResponder))")
        if MFRSuccess == false {
            print("OverlayManager: WARNING - Failed to make hostingView the first responder.")
            // Try making the window itself the first responder as a fallback
            // let windowMFRSuccess = overlayWindow?.makeFirstResponder(overlayWindow)
            // print("OverlayManager: Attempted to make overlayWindow first responder. Success: \(windowMFRSuccess). Current firstResponder: \(String(describing: overlayWindow?.firstResponder))")
        }

        // Activate our app before showing the window to help with focus
        // This might be redundant if makeKeyAndOrderFront does it, but can be a fallback.
        // NSApp.activate(ignoringOtherApps: true)

        print("Overlay window shown with SwiftUI view.")

        // Key-Value Observing for window visibility
        self.visibilityObservation = overlayWindow?.observe(\.isVisible, options: [.old, .new]) { [weak self] window, change in
            guard let isVisible = change.newValue else { return }
            if self?.isWindowActuallyVisible != isVisible {
                print("OverlayManager: Window visibility changed. Is visible: \(isVisible)")
                self?.isWindowActuallyVisible = isVisible
                if isVisible {
                    print("OverlayManager: Window is visible (unoccluded). Resuming Metal rendering.")
                    self?.shouldPauseMetalRendering = false
                    // If the app is active and window becomes visible, try to restore focus.
                    // This handles cases where the window might have lost key status while occluded.
                    if NSApp.isActive {
                        print("OverlayManager: App is active, restoring focus due to KVO visibility change.")
                        self?.restoreFocusToOverlay() 
                    }
                } else {
                    print("OverlayManager: Window is NOT visible (occluded). Pausing Metal rendering.")
                    // self?.shouldPauseMetalRendering = true
                }
            }
        }
    }

    // Internal handler called by OverlayView's completion callback
    private func handleSelectionCompletion(path: Path?, brushedText: String?) { // UPDATED: Signature for brushedText
        print("OverlayManager handling completion. Path received: \(path != nil), Brushed Text: \(brushedText ?? "nil")")
        
        // No longer need to combine query from indices here; CaptureController gets the direct text.
        // The `currentDetailedRegions` (previously `currentDetectedTexts`) were used for this combining step.
        // Now, the `brushedText` is the primary piece of information from OverlayView.
        
        currentCompletion?(path, brushedText) // Pass path and brushedText along

        print("OverlayManager: handleSelectionCompletion finished. Overlay remains visible for further interaction.")
    }

    // Public function to dismiss the overlay externally if needed
    // Also called internally when ESC is pressed or selection is done/cancelled in OverlayView
    func dismissOverlay() {
        guard overlayWindow != nil else { 
            // If window is already nil, still try to hide result panel just in case it's visible orphaned.
            Task { @MainActor in // Dispatch to main actor
                ResultPanel.shared.hide() // Attempt to hide panel even if overlay window is already gone.
            }
            return 
        }

        print("Dismissing overlay window...")
        Task { @MainActor in // Dispatch to main actor
            ResultPanel.shared.hide() // Hide the result panel when the overlay is dismissed
        }

        // Animate the fade-out (optional)
         NSAnimationContext.runAnimationGroup({ context in
             context.duration = 0.15 // Short fade duration
             overlayWindow?.animator().alphaValue = 0
         }, completionHandler: { [weak self] in
             self?.cleanUpOverlay()
         })

        // If dismissal was triggered externally BEFORE completion, signal cancellation
        if currentCompletion != nil {
            print("Dismiss triggered before completion - signalling cancellation.")
            currentCompletion?(nil, nil) // Signal cancellation (path nil, text nil)
            currentCompletion = nil 
            self.currentDetailedRegions = nil // Clear stored detailed regions
        }
    }

    // Public method to attempt to restore focus when app becomes active
    public func restoreFocusToOverlay() {
        // Delay slightly to allow workspace transition to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in // 100ms delay
            guard let self = self, let window = self.overlayWindow, let view = self.overlayContentView, self.isOverlayVisible else {
                print("OverlayManager: restoreFocusToOverlay (delayed) - Overlay not visible or window/view not set.")
                return
            }

            print("OverlayManager: Attempting to restore focus (delayed). Current App KeyWindow: \(String(describing: NSApp.keyWindow)), OverlayWindow isKey: \(window.isKeyWindow)")
            print("OverlayManager: OverlayWindow canBecomeKey: \(window.canBecomeKey), canBecomeMain: \(window.canBecomeMain)")

            // Forcefully activate our application first
            print("OverlayManager: (Delayed) Activating app ignoring others.")
            NSApp.activate(ignoringOtherApps: true)
            
            print("OverlayManager: Before makeKeyAndOrderFront/orderFrontRegardless (delayed). NSApp.isActive: \(NSApp.isActive), App KeyWindow: \(String(describing: NSApp.keyWindow)), OverlayWindow isKey: \(window.isKeyWindow)")
            window.makeKeyAndOrderFront(nil) // Try to make it key and bring to front
            window.orderFrontRegardless() // More forceful way to bring window to front
            print("OverlayManager: After makeKeyAndOrderFront/orderFrontRegardless (delayed). NSApp.isActive: \(NSApp.isActive), App KeyWindow: \(String(describing: NSApp.keyWindow)), OverlayWindow isKey: \(window.isKeyWindow)")

            // Defer making first responder slightly to allow window key status to settle
            // This inner async is likely still beneficial
            DispatchQueue.main.async {
                if window.isKeyWindow {
                    print("OverlayManager: Window is key (delayed), attempting to make hostingView first responder.")
                    if window.makeFirstResponder(view) {
                        print("OverlayManager: restoreFocusToOverlay - Successfully made hostingView first responder (delayed async).")
                    } else {
                        print("OverlayManager: restoreFocusToOverlay - WARNING - Failed to make hostingView first responder (delayed async).")
                        if window.makeFirstResponder(window) {
                            print("OverlayManager: restoreFocusToOverlay - Successfully made KeyAcceptingWindow first responder (delayed async fallback).")
                        } else {
                            print("OverlayManager: restoreFocusToOverlay - WARNING - Failed to make KeyAcceptingWindow first responder (delayed async fallback).")
                        }
                    }
                } else {
                    print("OverlayManager: restoreFocusToOverlay - Window did NOT become key (delayed), not attempting to make first responder.")
                    print("OverlayManager: One final attempt to activate and make key (delayed).")
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    print("OverlayManager: After final makeKeyAndOrderFront attempt (delayed). App KeyWindow: \(String(describing: NSApp.keyWindow)), OverlayWindow isKey: \(window.isKeyWindow)")
                    if window.isKeyWindow && window.makeFirstResponder(view) {
                        print("OverlayManager: restoreFocusToOverlay - Success on final attempt (delayed async).")
                    } else if window.isKeyWindow && window.makeFirstResponder(window) {
                        print("OverlayManager: restoreFocusToOverlay - KeyAcceptingWindow success on final attempt (delayed async).")
                    } else {
                        print("OverlayManager: restoreFocusToOverlay - All attempts to restore focus failed (delayed).")
                    }
                }
            }
        }
    }

    // Central cleanup logic
    private func cleanUpOverlay() {
         // Ensure window closure happens on the main thread
         DispatchQueue.main.async { [weak self] in
             guard let self = self, let window = self.overlayWindow else { return }
             // --- Stop Observing --- 
             self.visibilityObservation?.invalidate()
             self.visibilityObservation = nil
             // ---------------------

             // Hide and release the window
             window.contentViewController = nil // Clear the hosting controller
             window.contentView = nil // Explicitly break reference to content view as well
             window.delegate = nil   // Break delegate cycle if any
             window.orderOut(nil)    // Remove window from screen
             self.overlayWindow = nil // Release reference to NSWindow
             self.overlayContentView = nil // Clear content view reference
             self.currentCompletion = nil // Clear completion handler
             self.currentDetailedRegions = nil // Clear stored detailed regions
             self.isOverlayVisible = false // Ensure state reflects reality
             self.isWindowActuallyVisible = false // Ensure visibility state is also reset
            //  self.shouldPauseMetalRendering = true // Pause rendering when overlay is cleaned up
             print("Overlay window cleaned up.")

             // --- Restore focus to the previous application --- 
             if let appToReactivate = self.previousActiveApp {
                 print("OverlayManager: Reactivating previous application: \(String(describing: appToReactivate.localizedName ?? "Unknown"))")
                 appToReactivate.activate()
                 self.previousActiveApp = nil // Clear reference
             }
             // ------------------------------------------------
         }
    }
    
    private init() {} // Make initializer private for singleton

    deinit {
        print("OverlayManager deallocated")
    }
}