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
        // If popover already exists, just update the content
        if let existingPopover = popover, existingPopover.isShown, let existingHostingController = hostingController {
            print("ResultPanel: Popover already shown. Updating URL and title.")
            guard self.webViewModel != nil else {
                print("Error: webViewModel is nil despite existing popover. Recreating.")
                self.popover?.close()
                self.popover = nil
                self.hostingController = nil
                return setupPopoverIfNeeded(initialURL: initialURL, query: query)
            }

            self.webViewModel.link = initialURL
            
            let updatedView = ResultDisplayView(
                webViewModel: self.webViewModel,
                queryText: query, 
                onClose: { [weak self] in self?.hide() }
            )
            existingHostingController.rootView = updatedView
            return
        }
        
        // Close any existing popover before creating new one
        popover?.close()
        popover = nil
        hostingController = nil
        
        print("ResultPanel: Setting up new NSPopover.")

        // Initialize WebViewModel if needed
        let initialWidth: CGFloat = 360
        let initialHeight: CGFloat = 500
        self.currentPanelWidth = initialWidth
        self.currentPanelHeight = initialHeight

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
        
        // Create the popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: initialWidth, height: initialHeight)
        popover?.behavior = .semitransient // Allows interaction but closes on outside click
        popover?.animates = true
        popover?.contentViewController = hostingController
        popover?.delegate = self
        
        // Show the popover anchored to the selection
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

// Assume WebViewModel looks something like this (in a separate file e.g., WebViewModel.swift)
/*
class WebViewModel: ObservableObject {
    @Published var link: String
    @Published var pageTitle: String = "Loading..."
    @Published var didFinishLoading: Bool = false

    init(link: String) {
        self.link = link
    }

    static func googleSearchURL(for query: String) -> String {
        return "https://www.google.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
    }
}
*/

// Assume SwiftUIWebView looks something like this (in a separate file e.g., SwiftUIWebView.swift)
/*
import SwiftUI
import WebKit

struct SwiftUIWebView: NSViewRepresentable {
    @ObservedObject var viewModel: WebViewModel

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if let url = URL(string: viewModel.link) {
            // Only load if the URL is different or if the webView hasn't loaded anything yet
            // This prevents re-loading the same page unnecessarily if other @Published properties change
            if nsView.url?.absoluteString != viewModel.link || nsView.url == nil {
                 print("SwiftUIWebView: Loading new URL: \(viewModel.link)")
                nsView.load(URLRequest(url: url))
            }
        } else {
            print("SwiftUIWebView: Invalid URL: \(viewModel.link)")
            // Optionally load a blank page or an error page
             nsView.loadHTMLString("<html><body><h1>Invalid URL</h1></body></html>", baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SwiftUIWebView

        init(_ parent: SwiftUIWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.viewModel.pageTitle = webView.title ?? "Untitled Page"
                self.parent.viewModel.didFinishLoading = true
                 print("SwiftUIWebView: DidFinishLoading. Title: \(self.parent.viewModel.pageTitle)")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.viewModel.pageTitle = "Failed to Load"
                self.parent.viewModel.didFinishLoading = true
                print("SwiftUIWebView: DidFailNavigation. Error: \(error.localizedDescription)")
            }
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.viewModel.didFinishLoading = false
                self.parent.viewModel.pageTitle = "Loading..." // Reset title on new navigation
                print("SwiftUIWebView: DidStartProvisionalNavigation.")
            }
        }
    }
}
*/

// Extension to allow NSColor initialization from a hex string
// Note: This is a basic implementation for RGB/RGBA hex strings.
// For a production app, a more robust hex color parser might be desired.
/* // This extension should be outside any struct/class if it's a top-level extension
extension NSColor {
    convenience init?(hex: String) {
        let r, g, b, a:
        CGFloat
        let start:
        String.Index
        if hex.hasPrefix("#") {
            start = hex.index(hex.startIndex, offsetBy: 1)
        } else {
            start = hex.startIndex
        }
        let hexColor = String(hex[start...])

        if hexColor.count == 6 {
            let scanner = Scanner(string: hexColor)
            var hexNumber: UInt64 = 0
            if scanner.scanHexInt64(&hexNumber) {
                r = CGFloat((hexNumber & 0xff0000) >> 16) / 255
                g = CGFloat((hexNumber & 0x00ff00) >> 8) / 255
                b = CGFloat(hexNumber & 0x0000ff) / 255
                a = 1.0
                self.init(red: r, green: g, blue: b, alpha: a)
                return
            }
        } else if hexColor.count == 8 {
            let scanner = Scanner(string: hexColor)
            var hexNumber: UInt64 = 0
            if scanner.scanHexInt64(&hexNumber) {
                r = CGFloat((hexNumber & 0xff000000) >> 24) / 255
                g = CGFloat((hexNumber & 0x00ff0000) >> 16) / 255
                b = CGFloat((hexNumber & 0x0000ff00) >> 8) / 255
                a = CGFloat(hexNumber & 0x000000ff) / 255
                self.init(red: r, green: g, blue: b, alpha: a)
                return
            }
        }
        return nil
    }
}
*/
