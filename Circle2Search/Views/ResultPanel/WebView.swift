import SwiftUI
import WebKit
import Combine

@MainActor
public class WebViewModel: ObservableObject {
    @Published public var link: String
    @Published public var isLoading: Bool = false
    @Published public var didFinishLoading: Bool = false
    @Published public var pageTitle: String = "Loading..." // Initialize with a default

    // Static helper to create Google search URL
    public static func googleSearchURL(for query: String, width: Int, height: Int) -> String {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "gsc", value: "2"),
            URLQueryItem(name: "cs", value: "1"), // Defaulting to dark theme (1)
            URLQueryItem(name: "biw", value: String(width)),
            URLQueryItem(name: "bih", value: String(height))
        ]
        // Fallback should also include these if possible, though less critical
        return components?.url?.absoluteString ?? "https://www.google.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&gsc=2&cs=1&biw=\(width)&bih=\(height)" 
    }

    public init(link: String) {
        self.link = link
    }
}

public struct SwiftUIWebView: NSViewRepresentable {
    @ObservedObject var viewModel: WebViewModel
    // It's often better to create the WKWebView instance once and hold it,
    // rather than in makeNSView, if makeNSView can be called multiple times
    // leading to new WKWebView instances. However, for standard Representable
    // lifecycle, makeNSView is for creation, updateNSView for updates.
    // Let's stick to a single instance for this representable.
    private let webViewInstance = WKWebView()

    public init(viewModel: WebViewModel) {
        self.viewModel = viewModel
    }

    public func makeNSView(context: Context) -> WKWebView {
        webViewInstance.navigationDelegate = context.coordinator
        webViewInstance.uiDelegate = context.coordinator // Optional: if you need to handle JS alerts, etc.
        
        // Set a custom user-agent
        webViewInstance.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        // Perform the initial load only if there's a valid URL
        if let url = URL(string: viewModel.link) {
            print("SwiftUIWebView makeNSView: Loading initial URL: \(viewModel.link)")
            webViewInstance.load(URLRequest(url: url))
        } else {
            print("SwiftUIWebView makeNSView: Initial URL is invalid: \(viewModel.link)")
            // Optionally load an error page or blank page
            // webViewInstance.loadHTMLString("<html><body>Invalid URL</body></html>", baseURL: nil)
        }
        return webViewInstance
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let newTargetURL = URL(string: viewModel.link) else {
            print("SwiftUIWebView updateNSView: New target URL string is invalid: \(viewModel.link)")
            return
        }
        
        let currentWebViewURL = nsView.url

        // CAPTCHA/Sorry page loop prevention
        if let currentHost = currentWebViewURL?.host, currentHost.contains("google.com"),
           let currentPath = currentWebViewURL?.path, currentPath.contains("/sorry") {
            // If the current page is a Google "sorry" page, and the target URL's host is also Google
            // (implying viewModel.link is likely the original search), don't attempt to reload immediately.
            // This helps prevent a loop if the viewModel.link hasn't changed to a new, unrelated URL.
            if newTargetURL.host?.contains("google.com") == true {
                 print("SwiftUIWebView updateNSView: On Google CAPTCHA page. Suppressing reload of Google target to prevent loop.")
                 return
            }
        }
        
        // Condition: Load if webView has no URL yet, OR if its URL is different from the new target.
        if currentWebViewURL == nil || currentWebViewURL != newTargetURL {
            // Further check: if it's already loading the new target URL, don't issue another load command.
            // This can happen if makeNSView just started a load, and updateNSView is called immediately after.
            // However, nsView.isLoading might not be true yet if the load command was just issued.
            // A robust check is tricky. The primary guard is `currentWebViewURL != newTargetURL`.
            // If `nsView.url` is non-nil and matches `newTargetURL`, and `nsView.isLoading` is true, we definitely shouldn't reload.
            if nsView.isLoading && currentWebViewURL == newTargetURL {
                print("SwiftUIWebView updateNSView: Already loading target URL: \(newTargetURL.absoluteString)")
            } else {
                print("SwiftUIWebView updateNSView: Loading new or different URL: \(newTargetURL.absoluteString)")
                nsView.load(URLRequest(url: newTargetURL))
            }
        } else {
            print("SwiftUIWebView updateNSView: Target URL \(newTargetURL.absoluteString) is same as current: \(currentWebViewURL?.absoluteString ?? "nil"). No action.")
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }
}

public extension SwiftUIWebView {
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @ObservedObject var viewModel: WebViewModel // Ensure coordinator also observes if needed, or just holds a reference

        init(viewModel: WebViewModel) {
            self.viewModel = viewModel
            super.init()
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel.isLoading = true
                viewModel.didFinishLoading = false
                // viewModel.pageTitle = "Loading..." // Title updates on finish or from webView.title directly
                print("Coordinator: WebView didStartProvisionalNavigation for URL: \(webView.url?.absoluteString ?? "pending")")
            }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel.isLoading = false
                viewModel.didFinishLoading = true
                viewModel.pageTitle = webView.title ?? viewModel.link // Use link or a default if title is empty
                if viewModel.pageTitle.isEmpty { viewModel.pageTitle = "Page Loaded" } // Ensure some title
                print("Coordinator: WebView didFinish loading: \(webView.url?.absoluteString ?? "Unknown URL"), Title: \(viewModel.pageTitle)")
            }
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // This delegate method is for errors that occur after a navigation has committed (e.g., network loss during page load).
            Task { @MainActor in
                viewModel.isLoading = false
                viewModel.didFinishLoading = true // Consider it 'finished' but with an error
                viewModel.pageTitle = "Error: \(error.localizedDescription)"
                print("Coordinator: WebView didFail (committed navigation): \(error.localizedDescription)")
            }
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // This delegate method is for errors that occur before a navigation commits (e.g., server not found, SSL error, or cancellation).
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                print("Coordinator: WebView navigation cancelled (NSURLErrorCancelled, code -999). URL: \(webView.url?.absoluteString ?? "pending")")
                // If a navigation is cancelled, it's often because a new one is starting.
                // We might not want to immediately set isLoading to false or show an error
                // if `updateNSView` or `makeNSView` is about to issue a new load command.
                // For now, we'll update the state, but this can be a source of flicker if not handled carefully with `updateNSView` logic.
                // The refined `updateNSView` should ideally prevent most of these programmatic cancellations.
                Task { @MainActor in
                    // viewModel.isLoading = false; // Avoid changing isLoading if a new load is truly imminent.
                                                // If no new load starts, isLoading might remain true incorrectly.
                                                // Let didStartProvisionalNavigation for the *new* load handle isLoading.
                    // viewModel.pageTitle = "Navigation Cancelled" // Avoid changing title for a programmatic cancel
                }
                return
            }
            
            Task { @MainActor in
                viewModel.isLoading = false
                viewModel.didFinishLoading = true // Consider it 'finished' but with an error
                viewModel.pageTitle = "Failed to load: \(error.localizedDescription)"
                print("Coordinator: WebView didFailProvisionalNavigation (non-cancel): \(error.localizedDescription). URL: \(webView.url?.absoluteString ?? "pending")")
            }
        }
        
        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in
                viewModel.isLoading = false
                viewModel.didFinishLoading = true // Treat as finished, but failed
                viewModel.pageTitle = "Web Content Process Terminated"
                print("Coordinator: WebView webContentProcessDidTerminate for URL: \(webView.url?.absoluteString ?? "unknown")")
                // You might want to attempt a reload here or inform the user.
                // webView.reload()
            }
        }
        
        // Example WKUIDelegate method (optional, add if you need to handle JavaScript alerts)
        public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            // Present the alert to the user
            let alert = NSAlert()
            alert.messageText = "JavaScript Alert"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            // For a real app, you'd attach this to a window.
            // alert.beginSheetModal(for: webView.window!, completionHandler: { _ in completionHandler() })
            // If webView.window is not available or you're in a context without a window immediately:
            print("JavaScript Alert: \(message)")
            completionHandler() 
        }
    }
}
