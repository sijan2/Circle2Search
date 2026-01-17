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
    @Published var shouldPauseMetalRendering: Bool = false
    @Published var detailedTextRegions: [DetailedTextRegion] = [] // Published for async OCR updates
    @Published var detectedBarcodes: [DetectableBarcode] = [] // Published for async barcode detection
    @Published var detectedTextData: [DetectedTextData] = [] // Auto-detected URLs, emails, phones in text
    @Published var isResultPanelVisible: Bool = false  // Track if result panel popover is open
    
    /// Set to true when popover closes via user click. First tap after close clears this flag,
    /// second tap actually exits. This prevents the same click from both closing popover AND exiting.
    var needsConfirmTapToExit: Bool = false

    private var overlayWindow: KeyAcceptingWindow?
    var overlayContentView: NSView? // Store the content view (internal access is default)
    private var currentCompletion: ((Path?, String?, CGRect?) -> Void)?
    private var previousActiveApp: NSRunningApplication?
    private var visibilityObservation: NSKeyValueObservation?

    // Function to show the overlay
    func showOverlay(backgroundImage image: CGImage?, previousApp: NSRunningApplication?, completion: @escaping (Path?, String?, CGRect?) -> Void) {
        guard overlayWindow == nil else {
            log.debug("Overlay already shown.")
            return
        }

        currentCompletion = completion
        self.detailedTextRegions = [] // Clear previous regions
        self.detectedBarcodes = [] // Clear previous barcodes
        self.previousActiveApp = previousApp

        // Get screen details
        guard let screen = NSScreen.main else {
            log.error("Error: Could not get main screen.")
            completion(nil, nil, nil)
            return
        }

        // Ensure we actually received an image
        guard let validImage = image else {
             log.warning("OverlayManager: Received nil image for overlay.")
             completion(nil, nil, nil)
             return
        }

        self.isOverlayVisible = true
        self.shouldPauseMetalRendering = false

        // --- Create the SwiftUI View ---
        let swiftUIView = OverlayView(
            overlayManager: self, 
            backgroundImage: validImage,
            showOverlay: Binding(
                get: { self.isOverlayVisible },
                set: { newValue in
                    if !newValue && self.isOverlayVisible { 
                        self.dismissOverlay()
                    }
                    self.isOverlayVisible = newValue
                }
            ),
            completion: { [weak self] path, brushedTextFromOverlay, selectionRect in
                self?.handleSelectionCompletion(path: path, brushedText: brushedTextFromOverlay, selectionRect: selectionRect)
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
        log.debug("OverlayManager: About to make hostingView first responder. Current firstResponder: \(String(describing: overlayWindow?.firstResponder))")
        let MFRSuccess = overlayWindow?.makeFirstResponder(hostingView)
        log.debug("OverlayManager: Attempted to make hostingView first responder. Success: \(String(describing: MFRSuccess)). Current firstResponder: \(String(describing: overlayWindow?.firstResponder))")
        if MFRSuccess == false {
            log.warning("OverlayManager: WARNING - Failed to make hostingView the first responder.")
            // Try making the window itself the first responder as a fallback
            // let windowMFRSuccess = overlayWindow?.makeFirstResponder(overlayWindow)
            // print("OverlayManager: Attempted to make overlayWindow first responder. Success: \(windowMFRSuccess). Current firstResponder: \(String(describing: overlayWindow?.firstResponder))")
        }

        // Activate our app before showing the window to help with focus
        // This might be redundant if makeKeyAndOrderFront does it, but can be a fallback.
        // NSApp.activate(ignoringOtherApps: true)

        log.info("Overlay window shown with SwiftUI view.")

        // Key-Value Observing for window visibility
        self.visibilityObservation = overlayWindow?.observe(\.isVisible, options: [.old, .new]) { [weak self] window, change in
            guard let isVisible = change.newValue else { return }
            if self?.isWindowActuallyVisible != isVisible {
                log.debug("OverlayManager: Window visibility changed. Is visible: \(isVisible)")
                self?.isWindowActuallyVisible = isVisible
                if isVisible {
                    log.debug("OverlayManager: Window is visible (unoccluded). Resuming Metal rendering.")
                    self?.shouldPauseMetalRendering = false
                    // If the app is active and window becomes visible, try to restore focus.
                    // This handles cases where the window might have lost key status while occluded.
                    if NSApp.isActive {
                        log.debug("OverlayManager: App is active, restoring focus due to KVO visibility change.")
                        self?.restoreFocusToOverlay() 
                    }
                } else {
                    log.debug("OverlayManager: Window is NOT visible (occluded). Pausing Metal rendering.")
                    // self?.shouldPauseMetalRendering = true
                }
            }
        }
    }

    // Internal handler called by OverlayView's completion callback
    private func handleSelectionCompletion(path: Path?, brushedText: String?, selectionRect: CGRect?) {
        log.debug("OverlayManager handling completion. Path received: \(path != nil), Brushed Text: \(brushedText ?? "nil"), SelectionRect: \(String(describing: selectionRect))")
        
        // No longer need to combine query from indices here; CaptureController gets the direct text.
        // The `currentDetailedRegions` (previously `currentDetectedTexts`) were used for this combining step.
        // Now, the `brushedText` is the primary piece of information from OverlayView.
        
        currentCompletion?(path, brushedText, selectionRect) // Pass path, brushedText, and selectionRect along

        log.debug("OverlayManager: handleSelectionCompletion finished. Overlay remains visible for further interaction.")
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

        log.info("Dismissing overlay window...")
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

        if currentCompletion != nil {
            log.debug("Dismiss triggered before completion - signalling cancellation.")
            currentCompletion?(nil, nil, nil)
            currentCompletion = nil 
        }
    }

    // Public method to attempt to restore focus when app becomes active
    public func restoreFocusToOverlay() {
        // Delay slightly to allow workspace transition to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in // 100ms delay
            guard let self = self, let window = self.overlayWindow, let view = self.overlayContentView, self.isOverlayVisible else {
                log.debug("OverlayManager: restoreFocusToOverlay (delayed) - Overlay not visible or window/view not set.")
                return
            }

            log.debug("OverlayManager: Attempting to restore focus (delayed). Current App KeyWindow: \(String(describing: NSApp.keyWindow)), OverlayWindow isKey: \(window.isKeyWindow)")
            log.debug("OverlayManager: OverlayWindow canBecomeKey: \(window.canBecomeKey), canBecomeMain: \(window.canBecomeMain)")

            // Forcefully activate our application first
            log.debug("OverlayManager: (Delayed) Activating app ignoring others.")
            NSApp.activate(ignoringOtherApps: true)
            
            log.debug("OverlayManager: Before makeKeyAndOrderFront/orderFrontRegardless (delayed). NSApp.isActive: \(NSApp.isActive), App KeyWindow: \(String(describing: NSApp.keyWindow)), OverlayWindow isKey: \(window.isKeyWindow)")
            window.makeKeyAndOrderFront(nil) // Try to make it key and bring to front
            window.orderFrontRegardless() // More forceful way to bring window to front
            log.debug("OverlayManager: After makeKeyAndOrderFront/orderFrontRegardless (delayed). NSApp.isActive: \(NSApp.isActive), App KeyWindow: \(String(describing: NSApp.keyWindow)), OverlayWindow isKey: \(window.isKeyWindow)")

            // Defer making first responder slightly to allow window key status to settle
            // This inner async is likely still beneficial
            DispatchQueue.main.async {
                if window.isKeyWindow {
                    log.debug("OverlayManager: Window is key (delayed), attempting to make hostingView first responder.")
                    if window.makeFirstResponder(view) {
                        log.debug("OverlayManager: restoreFocusToOverlay - Successfully made hostingView first responder (delayed async).")
                    } else {
                        log.warning("OverlayManager: restoreFocusToOverlay - WARNING - Failed to make hostingView first responder (delayed async).")
                        if window.makeFirstResponder(window) {
                            log.debug("OverlayManager: restoreFocusToOverlay - Successfully made KeyAcceptingWindow first responder (delayed async fallback).")
                        } else {
                            log.warning("OverlayManager: restoreFocusToOverlay - WARNING - Failed to make KeyAcceptingWindow first responder (delayed async fallback).")
                        }
                    }
                } else {
                    log.warning("OverlayManager: restoreFocusToOverlay - Window did NOT become key (delayed), not attempting to make first responder.")
                    log.debug("OverlayManager: One final attempt to activate and make key (delayed).")
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    log.debug("OverlayManager: After final makeKeyAndOrderFront attempt (delayed). App KeyWindow: \(String(describing: NSApp.keyWindow)), OverlayWindow isKey: \(window.isKeyWindow)")
                    if window.isKeyWindow && window.makeFirstResponder(view) {
                        log.debug("OverlayManager: restoreFocusToOverlay - Success on final attempt (delayed async).")
                    } else if window.isKeyWindow && window.makeFirstResponder(window) {
                        log.debug("OverlayManager: restoreFocusToOverlay - KeyAcceptingWindow success on final attempt (delayed async).")
                    } else {
                        log.warning("OverlayManager: restoreFocusToOverlay - All attempts to restore focus failed (delayed).")
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
             self.detailedTextRegions = [] // Clear regions
             self.detectedBarcodes = [] // Clear barcodes
             self.isOverlayVisible = false // Ensure state reflects reality
             self.isWindowActuallyVisible = false // Ensure visibility state is also reset
            //  self.shouldPauseMetalRendering = true // Pause rendering when overlay is cleaned up
             log.info("Overlay window cleaned up.")

             // --- Restore focus to the previous application --- 
             if let appToReactivate = self.previousActiveApp {
                 log.info("OverlayManager: Reactivating previous application: \(String(describing: appToReactivate.localizedName ?? "Unknown"))")
                 appToReactivate.activate()
                 self.previousActiveApp = nil // Clear reference
             }
             // ------------------------------------------------
         }
    }
    
    private init() {} // Make initializer private for singleton

    deinit {
        log.debug("OverlayManager deallocated")
    }
}