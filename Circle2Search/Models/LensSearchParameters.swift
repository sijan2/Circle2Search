// LensSearchParameters.swift
// Circle2Search
//
// Parameters for Google Lens search requests

import Foundation

/// Parameters for a Google Lens image search request
struct LensSearchParameters {
    let imageData: Data
    let imageName: String // e.g., "capture.jpg" or "capture.png"
    let imageMimeType: String // e.g., "image/jpeg" or "image/png"
    let imageDimensions: (width: Int, height: Int)
    let viewportDimensions: (width: Int, height: Int) // vpw, vph
    let cookieHeader: String? // Optional cookie for authenticated requests
    let languageCode: String = "en" // hl parameter
    let userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"
    let referer: String = "https://www.google.com/"
    let origin: String = "https://www.google.com/"
    let endpointParameter: String = "gsbubb" // ep=gsbubb
}
