// Filename: VisionQuickFX.swift
import Vision
import AVFoundation // For CVPixelBuffer
import AppKit // For NSBezierPath conversion and NSWorkspace

// Result structure
struct OCRResult {
    let queryString: String
    let observations: [VNRecognizedTextObservation]
    let barcodeURL: URL?
}

actor VisionQuickFX {
    
    static let shared = VisionQuickFX()
    
    private init() {}
    
    /// Analyzes the CVPixelBuffer for text within the lasso path and checks for barcodes.
    /// - Parameters:
    ///   - lassoPath: The user-drawn path in the coordinate system of the buffer (pixels).
    ///   - pixelBuffer: The CVPixelBuffer containing the screen content.
    /// - Returns: An OCRResult containing the query string, observations, and optional barcode URL.
    func analyze(lassoPath: CGPath, pixelBuffer: CVPixelBuffer) async throws -> OCRResult {
        // 1. Perform Barcode Detection (potential early exit)
        if let barcodeURL = try? await detectBarcodeURL(pixelBuffer: pixelBuffer) {
            print("VisionQuickFX: Found barcode URL: \(barcodeURL.absoluteString)")
            // Early exit if barcode URL is found
            return OCRResult(queryString: "", observations: [], barcodeURL: barcodeURL)
        }
        
        // 2. Perform Text Recognition
        let textObservations = try await recognizeText(pixelBuffer: pixelBuffer)
        
        // 3. Filter Observations by Lasso Path and Confidence
        let bufferWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let filteredObservations = filterObservations(
            textObservations,
            by: lassoPath,
            in: CGSize(width: bufferWidth, height: bufferHeight),
            minConfidence: 0.50
        )
        
        // 4. Build Query String
        let queryString = filteredObservations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("VisionQuickFX: Analysis complete. Query: '\(queryString)', Observations: \(filteredObservations.count)")
        
        // Return final result
        return OCRResult(queryString: queryString, observations: filteredObservations, barcodeURL: nil)
    }
    
    // --- Helper Methods --- 
    
    /// Detects barcodes in the pixel buffer and returns the first valid URL found.
    private func detectBarcodeURL(pixelBuffer: CVPixelBuffer) async throws -> URL? {
        let request = VNDetectBarcodesRequest()
        // Optionally configure symbologies if needed: request.symbologies = [.qr, .pdf417, ...]
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        try handler.perform([request])
        
        guard let results = request.results else {
            return nil
        }
        
        for observation in results {
            // Check for payload string value
            if let payload = observation.payloadStringValue,
               let url = URL(string: payload), 
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil { // Basic validation if it looks like a URL
                // Check if the scheme suggests it's a web URL (http/https)
                // You might want more robust URL validation depending on requirements
                if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                     NSWorkspace.shared.open(url)
                     return url
                }
            }
        }
        
        return nil // No suitable barcode URL found
    }
    
    /// Recognizes text in the pixel buffer.
    private func recognizeText(pixelBuffer: CVPixelBuffer) async throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate // Or .fast
        request.usesLanguageCorrection = true
        // Specify languages, "und" allows Vision to auto-detect
        request.recognitionLanguages = ["und"] 
        // As per prompt: minimum height relative to image height
        request.minimumTextHeight = 0.02 
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        try handler.perform([request])
        
        return request.results ?? []
    }
    
    /// Filters text observations based on whether their centroid is inside the lasso path and confidence threshold.
    private func filterObservations(
        _ observations: [VNRecognizedTextObservation],
        by lassoPath: CGPath,
        in bufferSize: CGSize,
        minConfidence: VNConfidence
    ) -> [VNRecognizedTextObservation] {
        
        return observations.filter { observation in
            // Check confidence of the top candidate
            guard let topCandidate = observation.topCandidates(1).first, 
                  topCandidate.confidence >= minConfidence else {
                return false
            }
            
            // Check if centroid is within the lasso path
            let centroid = observation.centroid(in: bufferSize)
            return lassoPath.contains(centroid)
        }
    }
}

// MARK: - VNRecognizedTextObservation Extension

extension VNRecognizedTextObservation {
    /// Calculates the centroid of the observation's bounding box in pixel coordinates (top-left origin).
    /// - Parameter bufferSize: The dimensions of the pixel buffer (width, height).
    /// - Returns: The centroid point.
    func centroid(in bufferSize: CGSize) -> CGPoint {
        // VNRecognizedTextObservation.boundingBox is normalized (0-1) with origin BOTTOM-LEFT.
        let normalizedRect = self.boundingBox
        
        // 1. Convert to pixel coordinates (still bottom-left origin)
        let pixelRect = VNImageRectForNormalizedRect(normalizedRect, Int(bufferSize.width), Int(bufferSize.height))
        
        // 2. Calculate centroid (center) in pixel coordinates (still bottom-left origin)
        // Note: VNImageRectForNormalizedRect might return slightly different rect than direct calculation,
        // but using its result for consistency.
        let centroidX = pixelRect.origin.x + pixelRect.width / 2.0
        let centroidY_bottomLeft = pixelRect.origin.y + pixelRect.height / 2.0
        
        // 3. Convert centroid Y to top-left origin coordinate system
        let centroidY_topLeft = bufferSize.height - centroidY_bottomLeft
        
        return CGPoint(x: centroidX, y: centroidY_topLeft)
    }
}
