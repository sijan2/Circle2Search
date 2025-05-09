import Cocoa
import WebKit

class ResultViewController: NSViewController {
    var webView: WKWebView!

    override func loadView() {
        // Create the web view configuration
        let webConfiguration = WKWebViewConfiguration()
        // Create the web view instance
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.navigationDelegate = self // Optional: Set delegate if needed for navigation events
        webView.uiDelegate = self // Optional: Set delegate if needed for UI events like new windows
        
        // Set the view controller's view to the web view
        self.view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Optional: Initial setup or configuration
        print("ResultViewController loaded.")
    }

    /// Loads the specified URL in the web view.
    /// - Parameter url: The URL to load.
    func loadURL(_ url: URL) {
        let request = URLRequest(url: url)
        DispatchQueue.main.async { // Ensure UI updates on the main thread
            self.webView.load(request)
            print("Loading URL in WebView: \(url)")
        }
    }
}

// Optional: Conform to delegates if needed
extension ResultViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("WebView failed to load: \(error.localizedDescription)")
        // TODO: Show an error message in the webview or window?
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("WebView finished loading.")
    }
}

extension ResultViewController: WKUIDelegate {
    // Handle requests to open new windows (e.g., links with target="_blank")
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Open external links in the default browser
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil // Prevent WKWebView from creating a new window internally
    }
}
