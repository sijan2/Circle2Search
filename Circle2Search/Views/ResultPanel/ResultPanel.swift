// Filename: ResultPanel.swift
import Cocoa
import SwiftUI // Using SwiftUI for the embedded WebView

@MainActor
class ResultPanel: NSObject, NSWindowDelegate {
    
    static let shared = ResultPanel()
    
    private var resultDisplayWindow: NSWindow?
    private var hostingController: NSHostingController<ResultDisplayView>?
    
    private override init() { super.init() }
    
    func presentGoogleQuery(_ query: String) {
        let searchURLString = "https://www.google.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        print("ResultPanel: Presenting query: \(query) with URL: \(searchURLString)")
        setupWindowIfNeeded(initialURL: searchURLString, query: query)
    }
    
    func hide() {
        guard let resultDisplayWindow = resultDisplayWindow else { return }
        
        NSAnimationContext.runAnimationGroup({
            $0.duration = 0.15
            resultDisplayWindow.animator().alphaValue = 0.0
        }, completionHandler: {
            resultDisplayWindow.orderOut(nil)
            self.resultDisplayWindow = nil 
            self.hostingController = nil
            print("ResultPanel: Hidden and resources released.")
        })
    }

    private func setupWindowIfNeeded(initialURL: String, query: String) {
        if let existingWindow = resultDisplayWindow, let existingHostingController = hostingController {
            print("ResultPanel: Window already exists. Updating URL and bringing to front.")
            existingHostingController.rootView.webViewModel.link = initialURL
            existingWindow.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.15
                existingWindow.animator().alphaValue = 1.0
            }
            return
        }
        
        print("ResultPanel: Setting up new popover-style result window.")

        let initialWidth: CGFloat = 800
        let initialHeight: CGFloat = 600
        let contentRect = NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight)

        let resultView = ResultDisplayView(
            initialURL: initialURL,
            queryText: query, // Pass the original query for initial display if needed
            onClose: { [weak self] in self?.hide() }
        )
        hostingController = NSHostingController(rootView: resultView)
        
        resultDisplayWindow = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless], // Borderless window
            backing: .buffered,
            defer: false
        )

        // resultDisplayWindow?.title = "Search Results for: \(query)" // Title is now in custom header
        resultDisplayWindow?.isReleasedWhenClosed = true
        resultDisplayWindow?.delegate = self 
        resultDisplayWindow?.level = .floating // Keep it above most other windows
        
        resultDisplayWindow?.isOpaque = false
        resultDisplayWindow?.backgroundColor = .clear // Make window background transparent
        resultDisplayWindow?.hasShadow = true        // Give it a shadow like a popover
        resultDisplayWindow?.isMovableByWindowBackground = true // Allow dragging
        
        resultDisplayWindow?.contentView = hostingController?.view
        hostingController?.view.frame = contentRect // Ensure hosting controller's view fills the window
        
        resultDisplayWindow?.minSize = NSSize(width: 400, height: 300)
        
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
            // Ensure resources are cleaned up if closed by other means (though borderless usually isn't closed by system)
            resultDisplayWindow = nil 
            hostingController = nil
        }
    }
}

struct ResultDisplayView: View {
    @StateObject var webViewModel: WebViewModel
    let queryText: String // Original query text for initial display or context
    let onClose: () -> Void
    
    init(initialURL: String, queryText: String, onClose: @escaping () -> Void) {
        _webViewModel = StateObject(wrappedValue: WebViewModel(link: initialURL))
        self.queryText = queryText
        self.onClose = onClose
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom Header
            HStack(alignment: .center) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 8)
                
                Spacer()
                
                Text(webViewModel.didFinishLoading ? (webViewModel.pageTitle.isEmpty ? "Untitled Page" : webViewModel.pageTitle) : "Loading: \(queryText)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Spacer()
                
                Button(action: {
                    if let url = URL(string: webViewModel.link) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Open in Browser")
                    Image(systemName: "safari.fill") // Or your preferred browser icon
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 8)
            }
            .frame(height: 44) // Standard title bar height approx
            .background(Material.ultraThin) // Gives a slightly translucent background
            
            Divider()
            
            SwiftUIWebView(viewModel: webViewModel)
                .edgesIgnoringSafeArea([]) // Allow webview to use full space, but respect header/footer
            
            Divider()
            
            // Status Bar (optional, kept from previous version)
            HStack {
                Text(webViewModel.isLoading ? "Loading..." : (webViewModel.didFinishLoading ? "Loaded" : "Idle"))
                    .font(.caption)
                Spacer()
                ProgressView()
                    .scaleEffect(0.6)
                    .opacity(webViewModel.isLoading ? 1 : 0)
                if webViewModel.didFinishLoading && !webViewModel.isLoading {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Material.ultraThin)
        }
        .background(Color(NSColor.windowBackgroundColor)) // Main background for the popover content
        .cornerRadius(12) // Rounded corners for popover appearance
        // Apply a frame to the VStack to define the popover's content size within the transparent window
        // The window itself is sized by contentRect, this ensures the visual part has correct size & clipping
        .frame(width: 800, height: 600) // Match initial window size
        .clipped() // Ensure content respects rounded corners
    }
}
