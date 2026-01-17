// CaptureController.swift

import SwiftUI
import ScreenCaptureKit
import Vision
import AppKit
import CoreVideo
import CoreGraphics.CGGeometry
import Combine

// Placeholder for Google Cookie - REMOVED as we are testing anonymous upload
// private let googleCookieHeader = "YOUR_COOKIE_STRING_NEEDS_TO_BE_PLACED_HERE_REPLACE_THIS_ENTIRE_STRING"

// Handles the screen capture logic
@MainActor
final class CaptureController: NSObject, ObservableObject {
    // MARK: - Properties
    @Published var isCapturing: Bool = false
    var previousApp: NSRunningApplication?
    private var currentBackgroundImage: CGImage?
    private var currentDetailedTextRegions: [DetailedTextRegion] = []
    private var currentDetectedBarcodes: [DetectableBarcode] = []

    // MARK: - Capture Initiation

    func startCapture() {
        OverlayManager.shared.dismissOverlay()

        guard !isCapturing else {
            log.debug("Capture already active.")
            return
        }

        Task { @MainActor in
            guard await checkAndRequestPermissions() else {
                 log.warning("CaptureController: Permission not granted.")
                 return
            }

            isCapturing = true
            
            do {
                try await captureScreenshot()
            } catch {
                log.error("Error capturing screenshot: \(error)")
            }
            
            isCapturing = false
        }
    }

    // MARK: - Permission Handling

    private func checkAndRequestPermissions() async -> Bool {
        return await PermissionManager.shared.requestScreenRecordingPermission()
    }

    // MARK: - Screenshot Capture (SCScreenshotManager - no screen sharing indicator)

    private func captureScreenshot() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.noDisplaysFound
        }

        let config = SCStreamConfiguration()
        config.width = display.width * 2
        config.height = display.height * 2
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        
        // Single screenshot - no stream, no screen sharing indicator
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        
        log.info("Screenshot captured.")
        self.currentBackgroundImage = cgImage
        self.previousApp = NSWorkspace.shared.frontmostApplication
        self.currentDetailedTextRegions = []

        // Show overlay immediately
        NSCursor.crosshair.set()
        OverlayManager.shared.showOverlay(
            backgroundImage: self.currentBackgroundImage,
            previousApp: self.previousApp,
            completion: { [weak self] selectedPath, finalBrushedText, selectionRect in
                Task { [weak self] in 
                    await self?.handleSelectionCompletion(selectedPath, brushedText: finalBrushedText, selectionRect: selectionRect)
                }
            }
        )

        // Run OCR in background
        Task.detached(priority: .userInitiated) { [weak self, cgImage] in
            await self?.detectInitialTextRegions(image: cgImage)
        }
        
        // Run barcode detection in parallel (lower priority)
        Task.detached(priority: .utility) { [weak self, cgImage] in
            await self?.detectBarcodes(image: cgImage)
        }
    }

    // MARK: - Path Handling & Analysis

    private func handleSelectionCompletion(_ selectedPath: Path?, brushedText: String?, selectionRect: CGRect?) async {
        NSCursor.arrow.set()

        log.debug("CaptureController: handleSelectionCompletion entered.")
        if let path = selectedPath {
            log.debug("  - selectedPath is: not nil, BoundingRect: \(path.boundingRect)")
        } else {
            log.debug("  - selectedPath is: nil")
        }
        log.debug("  - brushedText is: '\(brushedText ?? "nil")'")
        log.debug("  - selectionRect is: \(String(describing: selectionRect))")

        if let text = brushedText, !text.isEmpty {
            log.info("Handling selection based on brushed text: '\(text)'")
            ResultPanel.shared.presentGoogleQuery(text, selectionRect: selectionRect)
            return
        }

        if let path = selectedPath, let fullImage = self.currentBackgroundImage {
            log.debug("Handling selection based on drawn path (brushedText was nil or empty).")
            await processPathBasedSelection(path, fullImage: fullImage)
            return
        }

        log.debug("Handling selection: No brushed text and no valid path, or fullImage is nil. Cleaning up.")
        if self.currentBackgroundImage == nil {
             activatePreviousApp()
        }
    }

    private func processPathBasedSelection(_ path: Path, fullImage: CGImage) async {
        log.debug("Processing path-based selection logic...")
        let pathBoundsInOverlayCoords = path.boundingRect
        let imageWidth = CGFloat(fullImage.width)
        let imageHeight = CGFloat(fullImage.height)
        
        // MARK: Coordinate Conversion
        // The overlay uses screen points (NSScreen.main.frame)
        // The screenshot is captured at 2x scale (display.width * 2, display.height * 2)
        // Therefore we need to scale path coordinates by 2 to get pixel coordinates
        
        guard let screen = NSScreen.main else {
            log.error("Could not get main screen for coordinate conversion")
            ResultPanel.shared.presentGoogleQuery("Error: Could not determine screen")
            return
        }
        
        let screenWidth = screen.frame.width
        let screenHeight = screen.frame.height
        
        // Calculate scale factors from screen points to image pixels
        let scaleX = imageWidth / screenWidth
        let scaleY = imageHeight / screenHeight
        
        // Convert overlay coordinates to pixel coordinates
        // Note: SwiftUI/AppKit origin is top-left, but CGImage origin is bottom-left
        // The path Y coordinates need to be flipped
        let pixelX = pathBoundsInOverlayCoords.origin.x * scaleX
        let pixelY = (screenHeight - pathBoundsInOverlayCoords.origin.y - pathBoundsInOverlayCoords.height) * scaleY
        let pixelWidth = pathBoundsInOverlayCoords.width * scaleX
        let pixelHeight = pathBoundsInOverlayCoords.height * scaleY
        
        let cropRectForPath = CGRect(x: pixelX, y: pixelY, width: pixelWidth, height: pixelHeight)
        
        log.debug("Path BBox in screen points: \(pathBoundsInOverlayCoords)")
        log.debug("Crop rect in pixels: \(cropRectForPath)")


        guard let croppedImage = cropImage(fullImage, pathBoundsInPixelCoords: cropRectForPath) else {
            log.warning("Failed to crop image using path bounds.")
            // If overlay is meant to stay, don't activate previous app here directly
            // activatePreviousApp() 
            // self.currentBackgroundImage = nil // Don't clear if overlay stays
            ResultPanel.shared.presentGoogleQuery("Error: Could not crop selection.")
            return
        }

        // For path-based, we don't have pre-confirmed text, so always run full recognition.
        // The didIntersectWithTextRegion logic can be a hint, but selectedIndices method is more direct.
        
        // Let's simplify: if we are in path-based, we try to recognize text from the crop.
        // The 'didIntersectWithTextRegion' check can be less critical if selectedIndices handles direct text hits.
        var didIntersectWithTextRegion = false
        let normalizedPathBoundingBox = CGRect( // For intersection check with Vision regions
            x: cropRectForPath.origin.x / imageWidth,
            y: (imageHeight - cropRectForPath.origin.y - cropRectForPath.height) / imageHeight, // Flip Y for Vision
            width: cropRectForPath.width / imageWidth,
            height: cropRectForPath.height / imageHeight
        ).standardized
        
        if !currentDetailedTextRegions.isEmpty {
            for region in currentDetailedTextRegions {
                if normalizedPathBoundingBox.intersects(region.normalizedRect) {
                    log.debug("Selected path (for fallback check) intersects with a detected text region: \(region.normalizedRect)")
                    didIntersectWithTextRegion = true
                    break
                }
            }
        }

        if didIntersectWithTextRegion {
            log.debug("Path intersected (fallback check), performing detailed text recognition...")
            await recognizeText(in: croppedImage, directlyRecognizedText: nil)
        } else {
            log.debug("Path did NOT intersect (fallback check) or no regions, falling back to Google Lens.")
            await fallbackToGoogleLens(image: croppedImage)
        }
        // State (bg image, regions) should not be cleared here if overlay persists.
        // self.currentBackgroundImage = nil
        // self.currentDetailedTextRegions = []
        // Cleanup UI (activatePreviousApp) is also removed from here.
    }

    // Helper function stub for cropping - needs refinement
    // Expects cropRect in PIXEL coordinates of the image
    func cropImage(_ image: CGImage, pathBoundsInPixelCoords cropRect: CGRect) -> CGImage? {
        log.debug("Cropping image to pixel rect: \(cropRect)")
        // Ensure the cropRect is within the image bounds
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let validCropRect = cropRect.intersection(imageRect).integral // Use integral to avoid subpixel issues

        guard !validCropRect.isNull, validCropRect.width >= 1, validCropRect.height >= 1 else {
            log.warning("Invalid or zero-size crop rectangle after intersection/integral: \(validCropRect)")
            return nil
        }
         guard let cropped = image.cropping(to: validCropRect) else {
             log.warning("CGImage.cropping failed for rect: \(validCropRect).")
             return nil
         }
         log.debug("Cropping successful.")
        return cropped
    }

    // MARK: - Vision Analysis

    /// Performs barcode and QR code detection on the full image.
    private func detectBarcodes(image: CGImage) async {
        log.debug("Starting barcode detection (background)...")
        
        let request = VNDetectBarcodesRequest { [weak self] request, error in
            guard let strongSelf = self else { return }
            
            guard let observations = request.results as? [VNBarcodeObservation], error == nil else {
                log.debug("Barcode detection: no results or error: \(error?.localizedDescription ?? "unknown")")
                return
            }
            
            let screenSize = NSScreen.main?.frame.size ?? .zero
            let barcodes = observations.map { DetectableBarcode(from: $0, screenSize: screenSize) }
            
            strongSelf.currentDetectedBarcodes = barcodes
            
            Task { @MainActor in
                OverlayManager.shared.detectedBarcodes = barcodes
                log.info("Barcode detection complete: \(barcodes.count) found")
            }
        }
        
        // Limit to common symbologies for performance
        request.symbologies = [.qr, .microQR, .ean13, .ean8, .code128, .code39, .dataMatrix, .pdf417, .aztec]
        
        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try requestHandler.perform([request])
            log.debug("VNImageRequestHandler perform complete for barcode detection.")
        } catch {
            log.error("Failed to perform barcode detection: \(error)")
        }
    }

    /// Performs initial, fast detection of text regions on the full image.
    private func detectInitialTextRegions(image: CGImage) async {
        log.debug("Starting initial text region detection (background)...")

        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let strongSelf = self else { return }

            let anyResults = request.results

            if let concreteObservations = anyResults as? [VNRecognizedTextObservation] {
                var newDetailedRegions: [DetailedTextRegion] = []
                for observation in concreteObservations {
                    if let topCandidate = observation.topCandidates(1).first {
                        newDetailedRegions.append(DetailedTextRegion(
                            recognizedText: topCandidate,
                            screenRect: .zero,
                            normalizedRect: observation.boundingBox
                        ))
                    }
                }
                strongSelf.currentDetailedTextRegions = newDetailedRegions
                
                // Update OverlayManager on main thread
                Task { @MainActor in
                    OverlayManager.shared.detailedTextRegions = newDetailedRegions
                    log.info("OCR complete: \(newDetailedRegions.count) regions found")
                    
                    // Run data detection for URLs, emails, phones (low priority)
                    if !newDetailedRegions.isEmpty {
                        let detectedData = TextDataDetector.shared.extractDataFromRegions(newDetailedRegions)
                        OverlayManager.shared.detectedTextData = detectedData
                        if !detectedData.isEmpty {
                            log.info("Data detection: found \(detectedData.count) regions with URLs/emails/phones")
                        }
                    }
                }
            } else {
                strongSelf.currentDetailedTextRegions = []
                Task { @MainActor in
                    OverlayManager.shared.detailedTextRegions = []
                }
            }
        }
        request.recognitionLevel = VNRequestTextRecognitionLevel.fast
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true  // Auto-detect language for multi-language support

        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try requestHandler.perform([request])
            log.debug("VNImageRequestHandler perform complete for initial text detection.")
        } catch {
            log.error("Failed to perform initial text detection: \(error)")
        }
    }

    // MARK: - Text Recognition

    /// Performs detailed text recognition on the cropped image and presents results.
    private func recognizeText(in croppedImage: CGImage, directlyRecognizedText: String?) async {
        log.debug("Performing detailed text recognition on cropped image...")

        if let directText = directlyRecognizedText, !directText.isEmpty {
            log.debug("Using directly recognized text: '\\(directText)'")
            Task { @MainActor in // Ensure UI updates on main thread
                ResultPanel.shared.presentGoogleQuery(directText)
                // Do NOT activate previous app here, overlay should stay focused with panel
            }
            return // Skip Vision request if we have direct text
        }

        log.debug("No direct text provided or empty, proceeding with Vision recognition...")
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
//                print("Error during Vision text recognition or no observations: \\(error?.localizedDescription ?? "No details")")
                Task { @MainActor in // Ensure UI updates on main thread
                    ResultPanel.shared.presentGoogleQuery("Vision Error: Could not recognize text.")
                    // OverlayManager.shared.dismissOverlay() // <-- REMOVED: Do not dismiss
                    // self?.activatePreviousApp() // <-- REMOVED: Do not activate previous app
                }
                return
            }
            
            let recognizedStrings = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            
            if recognizedStrings.isEmpty {
                log.debug("Vision detailed text recognition found no text.")
                Task { @MainActor in // Ensure UI updates on main thread
                    ResultPanel.shared.presentGoogleQuery("No text found in the selected area.")
                    // OverlayManager.shared.dismissOverlay() // <-- REMOVED: Do not dismiss
                    // self?.activatePreviousApp() // <-- REMOVED: Do not activate previous app
                }
            } else {
                let queryString = recognizedStrings.joined(separator: " ")
                log.info("Vision recognized text: \\(queryString)")
                Task { @MainActor in // Ensure UI updates on main thread
                    // OverlayManager.shared.dismissOverlay() // <-- REMOVED THIS (already done in previous step, but ensure it's gone)
                    ResultPanel.shared.presentGoogleQuery(queryString)
                    // self?.activatePreviousApp() // <-- REMOVED (already done in previous step, ensure gone)
                }
            }
        }
        
        request.recognitionLevel = VNRequestTextRecognitionLevel.accurate
        request.usesLanguageCorrection = true              // Enable language correction for accuracy
        request.automaticallyDetectsLanguage = true        // Auto-detect language for multi-language support
        
        let handler = VNImageRequestHandler(cgImage: croppedImage, options: [:])
        do {
            try handler.perform([request])
            log.debug("Detailed text recognition request performed (Vision).")
        } catch {
            log.error("Failed to perform detailed text recognition (Vision handler): \\(error)")
            Task { @MainActor in // Ensure UI updates on main thread
                ResultPanel.shared.presentGoogleQuery("Error processing image for text recognition.")
                 // OverlayManager.shared.dismissOverlay() // <-- REMOVED: Do not dismiss
                 // self?.activatePreviousApp() // <-- REMOVED: Do not activate previous app
            }
        }
    }
    
    /// Performs focused text recognition using regionOfInterest for better accuracy on brush selections
    /// - Parameters:
    ///   - image: The full captured image
    ///   - normalizedRect: The region to focus on in normalized coordinates (0-1, origin at bottom-left)
    /// - Returns: Array of recognized text observations within the region
    private func recognizeTextInRegion(image: CGImage, normalizedRect: CGRect) async -> [VNRecognizedTextObservation] {
        log.debug("Performing focused OCR in region: \(normalizedRect)")
        
        // Ensure valid region
        let clampedRect = CGRect(
            x: max(0, min(1, normalizedRect.origin.x)),
            y: max(0, min(1, normalizedRect.origin.y)),
            width: min(1 - normalizedRect.origin.x, normalizedRect.width),
            height: min(1 - normalizedRect.origin.y, normalizedRect.height)
        )
        
        guard clampedRect.width > 0.01, clampedRect.height > 0.01 else {
            log.debug("Region too small for focused OCR, returning empty")
            return []
        }
        
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                    log.debug("Focused OCR failed: \(error?.localizedDescription ?? "unknown")")
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: observations)
            }
            
            // Use accurate recognition for focused regions
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            
            // KEY: Focus recognition on the brush selection area
            request.regionOfInterest = clampedRect
            
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                log.error("Focused OCR handler failed: \(error)")
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - Google Lens Fallback

    /// Encodes the image and opens Google Lens search in the browser.
    private func fallbackToGoogleLens(image: CGImage) async {
        log.info("Falling back to Google Lens search with new uploader...")
        
        // 1. Encode image data (using JPEG for efficiency)
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            log.error("Error creating image destination for Google Lens fallback.")
            // Ensure ResultPanel is handled if an error occurs before calling it
            // OverlayManager.shared.dismissOverlay() // Consider if dismiss is always right here
            // activatePreviousApp() // Consider if always right
            return
        }
        // Using a moderate compression quality
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            log.error("Error finalizing image destination for Google Lens fallback.")
            // OverlayManager.shared.dismissOverlay()
            // activatePreviousApp()
            return
        }
        let imageData = mutableData as Data
        
        // 2. Prepare parameters for LensUploader
        let imageDimensions = (width: image.width, height: image.height)
        
        // Use main screen dimensions for viewport parameters as a default
        // Ideally, this would be the dimensions of the screen the capture occurred on.
        let mainScreenRect = NSScreen.main?.frame ?? NSRect.zero
        let viewportDims = (width: Int(mainScreenRect.width), height: Int(mainScreenRect.height))

        let lensParams = LensSearchParameters(
            imageData: imageData,
            imageName: "capture.jpg", // Or generate a unique name if desired
            imageMimeType: "image/jpeg",
            imageDimensions: imageDimensions,
            viewportDimensions: viewportDims,
            cookieHeader: nil // Testing anonymous upload
            // Other parameters like languageCode will use defaults from LensSearchParameters
        )

        // 3. Call LensUploader
        do {
            log.debug("CaptureController: Calling LensUploader.searchWithCustomParameters...")
            let resultURL = try await LensUploader.shared.searchWithCustomParameters(params: lensParams)
            log.info("CaptureController: LensUploader returned URL: \\(resultURL)")
            
            // 4. Present result in ResultPanel
            // The ResultPanel should handle its own visibility and not require explicit dismissal of overlay here.
            // OverlayManager.shared.dismissOverlay() // Let ResultPanel/OverlayView manage this interaction
            ResultPanel.shared.presentLensResult(url: resultURL)
            
            // Do NOT activatePreviousApp() here if the ResultPanel is now the focus.
            // The user interaction flow changes; they are now looking at results in-app.

        } catch {
            log.error("Error during LensUploader.searchWithCustomParameters: \\(error)")
            // Present an error message in the panel or an alert
            let errorMessage = "Failed to get Lens results: \\(error.localizedDescription)"
            ResultPanel.shared.presentGoogleQuery(errorMessage) // Using presentGoogleQuery for error text for now
            // activatePreviousApp() // Still might not want to activate previous if error shown in panel
        }
    }

    // MARK: - Helper Functions

    /// Reactivates the application that was active before the overlay was shown.
    func activatePreviousApp() {
        // ... [Existing reactivatePreviousApp logic remains largely the same] ...
         if let app = previousApp {
            log.info("Reactivating previous app: \(app.localizedName ?? "Unknown")")
            app.activate()
        } else {
            log.debug("No previous app recorded to reactivate.")
        }
        previousApp = nil
    }

    /// Sends the provided CGImage to Google Lens search.
    @MainActor
    func searchImageWithGoogleLens(image: CGImage) async {
        // ... [Existing searchImageWithGoogleLens logic] ...
         // 1. Convert CGImage to NSImage
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))

        // 2. Get TIFF representation from NSImage
        guard let tiffData = nsImage.tiffRepresentation else {
            log.error("Failed to get TIFF representation from NSImage for Lens search.")
            return
        }

        // 3. Convert TIFF data to PNG data using NSBitmapImageRep
        guard let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            log.error("Failed to convert TIFF data to PNG data for Lens search.")
            return
        }

        // Construct Google Lens URL (simplified version, might need POST)
        let urlString = "https://lens.google.com/uploadbyurl?url=data:image/png;base64,\(pngData.base64EncodedString())"

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else {
            log.error("Failed to create Google Lens URL.")
        }
    }

    private func createPixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        // ... [Existing createPixelBuffer logic] ...
         let width = cgImage.width
        let height = cgImage.height
        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA // Match stream format
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options as CFDictionary, &pixelBuffer)

        guard status == kCVReturnSuccess, let unwrappedPixelBuffer = pixelBuffer else {
            log.error("Failed to create CVPixelBuffer, status: \(status)")
            return nil
        }

        CVPixelBufferLockBaseAddress(unwrappedPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        let pixelData = CVPixelBufferGetBaseAddress(unwrappedPixelBuffer)

        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: pixelData,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(unwrappedPixelBuffer),
                                      space: rgbColorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) // BGRA format
        else {
            log.error("Failed to create CGContext for CVPixelBuffer")
            CVPixelBufferUnlockBaseAddress(unwrappedPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(unwrappedPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

        return unwrappedPixelBuffer
    }

    deinit {
        log.debug("CaptureController deallocated")
    }
}
