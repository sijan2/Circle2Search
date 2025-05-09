import Foundation

// Handles uploading image data to Google Lens endpoint
class LensUploader {
    static let shared = LensUploader()
    private init() {}

    private let uploadURL = URL(string: "https://lens.google.com/v3/upload")!
    // Use a generic user agent to mimic a browser
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    enum UploadError: Error {
        case networkError(Error)
        case httpError(statusCode: Int)
        case noRedirectLocation
        case dataConversionError
        case invalidURL
    }

    /// Uploads PNG image data to Google Lens and returns the result URL.
    /// - Parameter pngData: The PNG data of the image to upload.
    /// - Returns: The URL containing the Lens search results, or throws an UploadError.
    func search(pngData: Data) async throws -> URL {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let boundary = "----Circle2SearchBoundary\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Append boundary and headers for the image data part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"encoded_image\"; filename=\"capture.png\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)

        // Append the actual image data
        body.append(pngData)

        // Append the closing boundary
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // Disable automatic redirect handling to capture the 302 status and Location header
        let session = URLSession(configuration: .default, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)

        print("Uploading \(pngData.count) bytes to Lens...")
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            print("Lens upload network error: \(error)")
            throw UploadError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("Invalid response received from Lens upload.")
            throw UploadError.httpError(statusCode: 0)
        }

        print("Lens upload response status code: \(httpResponse.statusCode)")
        
        // Expecting a 302 Found redirect status code
        guard httpResponse.statusCode == 302 else {
            print("Lens upload failed with status: \(httpResponse.statusCode)")
            // You might want to inspect 'data' here for error messages from Google
             if let responseString = String(data: data, encoding: .utf8) {
                 print("Response body: \(responseString)")
             }
            throw UploadError.httpError(statusCode: httpResponse.statusCode)
        }

        // Extract the 'Location' header which contains the results URL
        guard let locationString = httpResponse.value(forHTTPHeaderField: "Location"),
              let resultURL = URL(string: locationString) else {
            print("Lens upload response missing or invalid Location header.")
            throw UploadError.noRedirectLocation
        }

        print("Lens result URL: \(resultURL)")
        return resultURL
    }
}

// Helper delegate to prevent URLSession from automatically following redirects
private class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Prevent the redirect by passing nil to the completion handler
        completionHandler(nil)
    }
}
