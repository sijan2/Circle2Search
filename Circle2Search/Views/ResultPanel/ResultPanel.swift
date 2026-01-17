// Filename: ResultPanel.swift
import Cocoa
import SwiftUI // Using SwiftUI for the embedded WebView

@MainActor
class ResultPanel: NSObject, NSPopoverDelegate {
    
    static let shared = ResultPanel()
    
    private var popover: NSPopover?
    private var hostingController: NSHostingController<ResultDisplayView>?
    private var webViewModel: WebViewModel! // Will be initialized before first use
    
    // Store the positioning info for the popover
    private var currentSelectionRect: CGRect?

    // Store initial dimensions used for URL generation
    private var currentPanelWidth: CGFloat = 360
    private var currentPanelHeight: CGFloat = 500

    private override init() { super.init() }
    
    func presentGoogleQuery(_ query: String, selectionRect: CGRect? = nil) {
        self.currentSelectionRect = selectionRect
        // Use the currentPanelWidth and currentPanelHeight for biw and bih
        let searchURLString = WebViewModel.googleSearchURL(for: query, 
                                                           width: Int(currentPanelWidth),
                                                           height: Int(currentPanelHeight))
        print("ResultPanel: Presenting query: \(query) with URL: \(searchURLString), selectionRect: \(String(describing: selectionRect))")
        setupPopoverIfNeeded(initialURL: searchURLString, query: query)
    }
    
    // New method to present a URL directly (e.g., from Lens search result)
    func presentLensResult(url: URL, selectionRect: CGRect? = nil) {
        self.currentSelectionRect = selectionRect
        let urlString = url.absoluteString
        // The text for the top bar can be generic, or you might parse parts of the URL if useful
        let queryForDisplay = "Google Lens Result"
        
        print("ResultPanel: Presenting direct URL: \(urlString)")
        
        // This existing method handles creating or updating the window and web view
        // It will use the urlString for the webViewModel.link
        setupPopoverIfNeeded(initialURL: urlString, query: queryForDisplay)
    }
    
    func hide() {
        guard let popover = popover else { return }
        
        popover.performClose(nil)
        self.popover = nil
        self.hostingController = nil
        self.currentSelectionRect = nil
        print("ResultPanel: Popover closed and resources released.")
    }

    private func setupPopoverIfNeeded(initialURL: String, query: String) {
        // Always close existing popover - we need to reposition for new selection
        if popover != nil {
            print("ResultPanel: Closing existing popover to reposition at new selection.")
            popover?.close()
            popover = nil
            hostingController = nil
        }
        
        print("ResultPanel: Creating popover at new position.")

        let initialWidth: CGFloat = 360
        let initialHeight: CGFloat = 500
        self.currentPanelWidth = initialWidth
        self.currentPanelHeight = initialHeight

        // Reuse WebViewModel if it exists (memory efficient), just update URL
        if self.webViewModel == nil {
            self.webViewModel = WebViewModel(link: initialURL)
        } else {
            self.webViewModel.link = initialURL
        }

        let resultView = ResultDisplayView(
            webViewModel: self.webViewModel,
            queryText: query, 
            onClose: { [weak self] in self?.hide() }
        )
        hostingController = NSHostingController(rootView: resultView)
        hostingController?.view.frame = NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight)
        
        popover = NSPopover()
        popover?.contentSize = NSSize(width: initialWidth, height: initialHeight)
        popover?.behavior = .semitransient // Closes on outside click - user's preference
        popover?.animates = true
        popover?.contentViewController = hostingController
        popover?.delegate = self
        
        showPopover()
    }
    
    private func showPopover() {
        guard let popover = popover else { return }
        
        // Get the overlay view to anchor the popover
        guard let anchorView = OverlayManager.shared.overlayContentView else {
            print("ResultPanel: No overlay content view available for anchoring popover. Falling back to screen center.")
            // Fallback: show in a detached window if no anchor view
            showPopoverDetached()
            return
        }
        
        // Convert selection rect to view coordinates
        var positioningRect: CGRect
        if let selectionRect = currentSelectionRect {
            // The selection rect is in overlay view coordinates (top-left origin from SwiftUI)
            // NSPopover expects the rect in the view's coordinate system
            positioningRect = selectionRect
        } else {
            // No selection rect - position in center of view
            let viewBounds = anchorView.bounds
            positioningRect = CGRect(x: viewBounds.midX - 1, y: viewBounds.midY - 1, width: 2, height: 2)
        }
        
        // Determine preferred edge based on position
        // If selection is in upper half of screen, show below; otherwise show above
        let preferredEdge: NSRectEdge
        if let selectionRect = currentSelectionRect {
            let screenHeight = anchorView.bounds.height
            if selectionRect.midY < screenHeight / 2 {
                preferredEdge = .maxY // Show above (selection is in lower half)
            } else {
                preferredEdge = .minY // Show below (selection is in upper half)
            }
        } else {
            preferredEdge = .maxY
        }
        
        print("ResultPanel: Showing popover at rect: \(positioningRect), edge: \(preferredEdge)")
        popover.show(relativeTo: positioningRect, of: anchorView, preferredEdge: preferredEdge)
    }
    
    private func showPopoverDetached() {
        // Fallback when no anchor view is available - create a temporary window
        guard let popover = popover, let hostingController = hostingController else { return }
        
        // Create a small invisible window at screen center to anchor the popover
        guard let screen = NSScreen.main else { return }
        let screenCenter = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: screenCenter.x - 1, y: screenCenter.y - 1, width: 2, height: 2),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        anchorWindow.isOpaque = false
        anchorWindow.backgroundColor = .clear
        anchorWindow.level = .floating
        anchorWindow.orderFront(nil)
        
        if let contentView = anchorWindow.contentView {
            popover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .maxY)
        }
    }
    
    // MARK: - NSPopoverDelegate
    
    func popoverDidClose(_ notification: Notification) {
        print("ResultPanel: Popover did close (delegate).")
        // Don't nil out everything here - the popover might be closed temporarily
        // Only clean up if we explicitly called hide()
    }
    
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        // Allow the popover to be detached into a separate window
        return true
    }
}

struct ResultDisplayView: View {
    @ObservedObject var webViewModel: WebViewModel // Changed from StateObject
    let queryText: String 
    let onClose: () -> Void
    
    // Initializer now takes WebViewModel
    init(webViewModel: WebViewModel, queryText: String, onClose: @escaping () -> Void) {
        self.webViewModel = webViewModel
        // If queryText is also for the WebViewModel to drive "Loading: query" then it should be set on webViewModel
        // For now, ResultDisplayView just takes it for its own Text view.
        self.queryText = queryText
        self.onClose = onClose
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom Google Search Bar
            HStack(spacing: 8) {
                Image("Google") // Use the asset named "Google"
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    // .foregroundColor(.blue) // Removed, asset will have its own color
                    .padding(.leading, 12)

                Text(queryText) 
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.9)) // Adjusted for dark background
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Spacer() 
            }
            // Increase height and horizontal padding
            .frame(height: 48) // Increased height from 40 to 48
            .background(Color(nsColor: NSColor(hex: "#3F4454", alpha: 1.0) ?? NSColor.black)) 
            .cornerRadius(24) // Increase cornerRadius if height increases, to maintain pill shape (height / 2)
            .padding(.horizontal, 30) // Increased horizontal padding from 10 to 30
            .padding(.top, 10) 
            .padding(.bottom, 6) 

            Divider() 

            SwiftUIWebView(viewModel: webViewModel)
                .edgesIgnoringSafeArea([]) 
            
            // Divider() // The bottom divider was here, let's see if we still need it or if the panel border is enough
        }
        // Change the background of the entire ResultDisplayView content to #101217
        .background(Color(nsColor: NSColor(hex: "#101217", alpha: 1.0) ?? NSColor.controlBackgroundColor)) 
        .cornerRadius(12) 
        .overlay( 
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        .clipped() 
    }
}

