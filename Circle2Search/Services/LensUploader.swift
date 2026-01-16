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
        let session = URLSession(configuration: .default, delegate: NoRedirectSessionDelegate.sharedInstance, delegateQueue: nil)

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

    /// Uploads image data to Google Lens using detailed parameters and returns the result URL.
    func searchWithCustomParameters(params: LensSearchParameters) async throws -> URL {
        var components = URLComponents(string: "https://lens.google.com/v3/upload")
        let currentTimestamp = Int64(Date().timeIntervalSince1970 * 1000)

        components?.queryItems = [
            URLQueryItem(name: "ep", value: params.endpointParameter),
            URLQueryItem(name: "st", value: String(currentTimestamp)),
            URLQueryItem(name: "hl", value: params.languageCode),
            URLQueryItem(name: "vpw", value: String(params.viewportDimensions.width)),
            URLQueryItem(name: "vph", value: String(params.viewportDimensions.height))
        ]

        guard let urlWithParams = components?.url else {
            print("LensUploader: Invalid URL components for custom search.")
            throw UploadError.invalidURL
        }

        var request = URLRequest(url: urlWithParams)
        request.httpMethod = "POST"

        // Set headers
        request.setValue(params.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(params.referer, forHTTPHeaderField: "Referer")
        request.setValue(params.origin, forHTTPHeaderField: "Origin")
        // Conditionally add Cookie header if provided
        if let cookie = params.cookieHeader, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            print("LensUploader: Including Cookie header.")
        } else {
            print("LensUploader: Omitting Cookie header for anonymous attempt.")
        }
        // Note: Other complex headers (Sec-Ch-Ua-*, X-Client-Data, etc.) are omitted for simplicity.
        // The request may work without them, but this could be a point of failure if Google's servers require them.

        // Using a unique boundary is generally safer, but the example uses a fixed one.
        // let boundary = "----Boundary\(UUID().uuidString)"
        // let boundary = "----WebKitFormBoundarys9vi5Rxen77AMYwy" // From your example
        // Generate a unique boundary for each request
        let boundary = "----WebKitFormBoundary\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\\\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Part 1: Image Data
        let boundaryPrefix = "--\\(boundary)\\r\\n"
        body.append(boundaryPrefix.data(using: .utf8)!)
//        print("LensUploader Body Part: \\(boundaryPrefix.replacingOccurrences(of: "\\r\\n", with: "CRLF"))") // Log with CRLF visible

        let part1_disposition_key_name = "encoded_image"
        let part1_filename_val = params.imageName
        let part1_disposition_header_content = "Content-Disposition: form-data; name=\"\\(part1_disposition_key_name)\"; filename=\"\\(part1_filename_val)\"\\r\\n"
        body.append(part1_disposition_header_content.data(using: .utf8)!)
//        print("LensUploader Body Part: \\(part1_disposition_header_content.replacingOccurrences(of: "\\r\\n", with: "CRLF"))")

        let part1_content_type_header_content = "Content-Type: \\(params.imageMimeType)\\r\\n\\r\\n"
        body.append(part1_content_type_header_content.data(using: .utf8)!)
//        print("LensUploader Body Part: \\(part1_content_type_header_content.replacingOccurrences(of: "\\r\\n", with: "CRLF"))")

        body.append(params.imageData)
        print("LensUploader Body Part: [Image Data \\(params.imageData.count) bytes]")
        let crlf = "\\r\\n"
        body.append(crlf.data(using: .utf8)!)
        print("LensUploader Body Part: CRLF")

        // Part 2: Image Dimensions
        let dimensionsString = "\\(params.imageDimensions.width),\\(params.imageDimensions.height)"
        body.append(boundaryPrefix.data(using: .utf8)!)
//        print("LensUploader Body Part: \\(boundaryPrefix.replacingOccurrences(of: "\\r\\n", with: "CRLF"))") // Log with CRLF visible

        let part2_disposition_key_name = "processed_image_dimensions"
        let part2_disposition_header_content = "Content-Disposition: form-data; name=\"\\(part2_disposition_key_name)\"\\r\\n\\r\\n"
        body.append(part2_disposition_header_content.data(using: .utf8)!)
//        print("LensUploader Body Part: \\(part2_disposition_header_content.replacingOccurrences(of: "\\r\\n", with: "CRLF"))")

        body.append(dimensionsString.data(using: .utf8)!)
        print("LensUploader Body Part: \\(dimensionsString)")
        body.append(crlf.data(using: .utf8)!)
        print("LensUploader Body Part: CRLF")

        // Append the closing boundary
        let closingBoundary = "--\\(boundary)--\\r\\n"
        body.append(closingBoundary.data(using: .utf8)!)
//        print("LensUploader Body Part: \\(closingBoundary.replacingOccurrences(of: "\\r\\n", with: "CRLF"))")

        request.httpBody = body
        // Content-Length is usually set automatically by URLSession when httpBody is assigned.
        // If issues arise, uncommenting this might be necessary.
        // request.setValue("\\\(body.count)", forHTTPHeaderField: "Content-Length")

        // Use the NoRedirectSessionDelegate to prevent automatic redirect following
        let session = URLSession(configuration: .default, delegate: NoRedirectSessionDelegate.sharedInstance, delegateQueue: nil)

        print("LensUploader: Uploading \(params.imageData.count) bytes to Lens with custom parameters...")
        
        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            print("LensUploader: Network error (custom search): \(error)")
            throw UploadError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("LensUploader: Invalid response received (custom search).")
            throw UploadError.httpError(statusCode: 0)
        }

        print("LensUploader: Response status code (custom search): \(httpResponse.statusCode)")
        
        // Expecting a 302 Found or 303 See Other redirect status code
        guard httpResponse.statusCode == 302 || httpResponse.statusCode == 303 else {
            print("LensUploader: Upload failed (custom search) with status: \(httpResponse.statusCode)")
             if let responseString = String(data: responseData, encoding: .utf8) {
                 print("LensUploader: Response body (custom search): \(responseString)")
             }
            throw UploadError.httpError(statusCode: httpResponse.statusCode)
        }

        // Extract the 'Location' header which contains the results URL
        guard let locationString = httpResponse.value(forHTTPHeaderField: "Location"),
              let resultURL = URL(string: locationString) else {
            print("LensUploader: Response missing or invalid Location header (custom search).")
            throw UploadError.noRedirectLocation
        }

        print("LensUploader: Lens result URL (custom search): \(resultURL)")
        return resultURL
    }
}

// Helper delegate to prevent URLSession from automatically following redirects
private class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    // Making this a shared instance if preferred, or it can be instantiated per call.
    static let sharedInstance = NoRedirectSessionDelegate()
    private override init() {} // Ensure it's a singleton if using sharedInstance

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Prevent the redirect by passing nil to the completion handler
        completionHandler(nil)
    }
}
