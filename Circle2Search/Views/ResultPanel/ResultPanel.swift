// Filename: ResultPanel.swift
import Cocoa
import SwiftUI // Using SwiftUI for the embedded WebView

@MainActor
class ResultPanel: NSObject, NSWindowDelegate {
    
    static let shared = ResultPanel()
    
    private var resultDisplayWindow: NSPanel?
    private var hostingController: NSHostingController<ResultDisplayView>?
    private var webViewModel: WebViewModel! // Will be initialized before first use

    // Store initial dimensions used for URL generation
    private var currentPanelWidth: CGFloat = 500 // Default, matches user's last change
    private var currentPanelHeight: CGFloat = 500 // Default

    private override init() { super.init() }
    
    func presentGoogleQuery(_ query: String) {
        // Use the currentPanelWidth and currentPanelHeight for biw and bih
        let searchURLString = WebViewModel.googleSearchURL(for: query, 
                                                           width: Int(currentPanelWidth),
                                                           height: Int(currentPanelHeight))
        print("ResultPanel: Presenting query: \(query) with URL: \(searchURLString)")
        setupWindowIfNeeded(initialURL: searchURLString, query: query)
    }
    
    // New method to present a URL directly (e.g., from Lens search result)
    func presentLensResult(url: URL) {
        let urlString = url.absoluteString
        // The text for the top bar can be generic, or you might parse parts of the URL if useful
        let queryForDisplay = "Google Lens Result"
        
        print("ResultPanel: Presenting direct URL: \(urlString)")
        
        // This existing method handles creating or updating the window and web view
        // It will use the urlString for the webViewModel.link
        setupWindowIfNeeded(initialURL: urlString, query: queryForDisplay)
    }
    
    func hide() {
        guard let resultDisplayWindow = resultDisplayWindow else { return }
        
        NSAnimationContext.runAnimationGroup({
            $0.duration = 0.15
            resultDisplayWindow.animator().alphaValue = 0.0
        }, completionHandler: {
            resultDisplayWindow.orderOut(nil)
            // Only nil out if we are truly done, not for a potential quick update.
            // However, if hide is called, it implies the panel should go away.
            self.resultDisplayWindow = nil 
            self.hostingController = nil
            // self.webViewModel = nil // If webViewModel should reset when hidden
            print("ResultPanel: Hidden and resources released.")
        })
    }

    private func setupWindowIfNeeded(initialURL: String, query: String) {
        if let existingWindow = resultDisplayWindow, let existingHostingController = hostingController {
            print("ResultPanel: Window already exists. Updating URL and title.")
            // Ensure webViewModel exists (should always be true if window exists)
            guard self.webViewModel != nil else {
                print("Error: webViewModel is nil despite existing window. Recreating.")
                // Fallthrough to recreate logic if something went wrong
                self.resultDisplayWindow = nil // Force recreation
                self.hostingController = nil
                // Recurse or duplicate creation logic - simpler to fallthrough by nilling out window
                return setupWindowIfNeeded(initialURL: initialURL, query: query)
            }

            self.webViewModel.link = initialURL // Update the link on the existing view model
            
            // Create a new ResultDisplayView with the new queryText but the same WebViewModel
            let updatedView = ResultDisplayView(
                webViewModel: self.webViewModel,
                queryText: query, 
                onClose: { [weak self] in self?.hide() }
            )
            existingHostingController.rootView = updatedView // Update the hosting controller's root view
            
            existingWindow.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.15
                existingWindow.animator().alphaValue = 1.0
            }
            return
        }
        
        print("ResultPanel: Setting up new popover-style result window.")

        // Initialize WebViewModel if it doesn't exist (first time setup)
        // Use the panel's initial width/height for the first URL generation
        let initialWidth: CGFloat = 360 // User changed this
        let initialHeight: CGFloat = 600
        self.currentPanelWidth = initialWidth   // Store for future queries if panel not resized
        self.currentPanelHeight = initialHeight // Store for future queries if panel not resized

        if self.webViewModel == nil {
            // Pass the initial dimensions for the very first URL
            let firstURL = WebViewModel.googleSearchURL(for: query, width: Int(initialWidth), height: Int(initialHeight))
            self.webViewModel = WebViewModel(link: firstURL) 
            // initialURL passed to setupWindowIfNeeded already has these dimensions via presentGoogleQuery,
            // but if called directly, webViewModel needs a link.
            // Let's ensure initialURL is used for webViewModel link if it matches the query context.
            self.webViewModel.link = initialURL // This initialURL should be already formatted with w/h
        } else {
            self.webViewModel.link = initialURL // initialURL is already formatted with current w/h
        }
        
        let contentRect = NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight)

        let resultView = ResultDisplayView(
            webViewModel: self.webViewModel, // Pass the managed WebViewModel
            queryText: query, 
            onClose: { [weak self] in self?.hide() }
        )
        hostingController = NSHostingController(rootView: resultView)
        
        resultDisplayWindow = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable], // ADDED .resizable
            backing: .buffered,
            defer: false
        )

        resultDisplayWindow?.isReleasedWhenClosed = true
        resultDisplayWindow?.delegate = self 
        resultDisplayWindow?.level = .floating 
        resultDisplayWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        
        resultDisplayWindow?.isOpaque = false
        resultDisplayWindow?.backgroundColor = .clear
        resultDisplayWindow?.hasShadow = true
        
        resultDisplayWindow?.isMovableByWindowBackground = true
        
        // Setup Auto Layout for the hosting view
        if let hcView = hostingController?.view {
            hcView.translatesAutoresizingMaskIntoConstraints = false
            resultDisplayWindow?.contentView?.addSubview(hcView)
            if let superview = hcView.superview {
                NSLayoutConstraint.activate([
                    hcView.topAnchor.constraint(equalTo: superview.topAnchor),
                    hcView.bottomAnchor.constraint(equalTo: superview.bottomAnchor),
                    hcView.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
                    hcView.trailingAnchor.constraint(equalTo: superview.trailingAnchor)
                ])
            }
        } else {
             resultDisplayWindow?.contentView = hostingController?.view // Fallback if something is unusual
        }
        // hostingController?.view.frame = contentRect // No longer setting fixed frame
        
        resultDisplayWindow?.minSize = NSSize(width: 300, height: 200) // Set a reasonable min size
        
        resultDisplayWindow?.center()
        resultDisplayWindow?.makeKeyAndOrderFront(nil)
        resultDisplayWindow?.alphaValue = 0.0

        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.15
            resultDisplayWindow?.animator().alphaValue = 1.0
        }
    }
    
    // Conformance to NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == resultDisplayWindow {
            print("ResultPanel: Window delegate detected close, releasing resources.")
            resultDisplayWindow = nil 
            hostingController = nil
            // Consider whether webViewModel should be nilled out here too,
            // or if it should persist until a completely new ResultPanel might be needed.
            // If ResultPanel is a singleton, webViewModel could persist.
        }
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
