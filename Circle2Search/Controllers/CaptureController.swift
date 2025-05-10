// CaptureController.swift

import SwiftUI
import ScreenCaptureKit
import Vision
import AppKit
import CoreVideo
import CoreGraphics.CGGeometry
import Combine // Needed for Task

// Define this struct, perhaps globally or nested if preferred and accessible
struct DetailedTextRegion: Identifiable, Equatable { // Identifiable if used in SwiftUI lists directly, not strictly needed here
    let id = UUID() // For Identifiable conformance if ever needed
    let recognizedText: VNRecognizedText // The top candidate text object from Vision
    let screenRect: CGRect // The screen-coordinate bounding box for the entire observation
    let normalizedRect: CGRect // The normalized bounding box for the entire observation (0,0 bottom-left)
    // String is directly available via recognizedText.string

    // Equatable conformance
    static func == (lhs: DetailedTextRegion, rhs: DetailedTextRegion) -> Bool {
        // For .onChange, often checking if the underlying data that drives UI has changed is enough.
        // VNRecognizedText is a class, so direct comparison might not be what we want unless we compare its string value and box.
        // For simplicity with .onChange, comparing IDs and normalizedRects can be a good starting point.
        // If more detailed change detection is needed, this can be expanded.
        return lhs.id == rhs.id && lhs.normalizedRect == rhs.normalizedRect && lhs.recognizedText.string == rhs.recognizedText.string
    }
}

// Error specific to capture process
enum CaptureError: Error {
    case noDisplaysFound
    case streamCreationFailed
    case frameCaptureFailed
    case permissionDenied
    case captureCancelled
    case imageConversionFailed
}

// Handles the screen capture logic
@MainActor
final class CaptureController: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    // MARK: - Properties
    @Published var isStreamActive: Bool = false
    var previousApp: NSRunningApplication?
    private var currentBackgroundImage: CGImage?
    private var stream: SCStream?
    private var continuation: CheckedContinuation<Void, Error>? // For awaiting frame
    private var currentDetailedTextRegions: [DetailedTextRegion] = [] // Store initially detected regions

    // MARK: - Capture Initiation

    /// Checks permissions and starts the screen capture process.
    func startCapture() {
        // ADDED: Explicitly dismiss any existing overlay from OverlayManager
        // This helps ensure its state is clean before we check isStreamActive
        // or try to show a new overlay later.
        OverlayManager.shared.dismissOverlay()

        guard !isStreamActive else {
            print("Capture session already active.")
            return
        }

        // Check for screen capture permissions first.
        Task { @MainActor in // Use MainActor for permission checks/UI
            guard await checkAndRequestPermissions() else {
                 showPermissionAlert() // Show alert if permission denied or not granted yet
                 return
            }

            // Permission granted, proceed with capture setup
            isStreamActive = true
            print("Starting capture process...")

            do {
                try await setupAndStartStream()
                print("Stream setup and started successfully. Waiting for frame...")
                // Now wait for the delegate method to capture the frame
            } catch {
                print("Error starting capture: \(error)")
                self.isStreamActive = false
                // Handle error (e.g., show alert to user)
            }
        }
    }

    // MARK: - Permission Handling (Moved Here)

    /// Checks screen capture permission status and requests if needed.
    /// Returns true if permission is granted, false otherwise.
    private func checkAndRequestPermissions() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            print("Permission already granted.")
            return true
        } else {
            print("Requesting screen capture access...")
            let granted = CGRequestScreenCaptureAccess() // This is synchronous but called from async context
            if granted {
                print("Permission granted by user.")
            } else {
                print("Permission denied by user.")
            }
            return granted
        }
    }

    /// Shows an alert guiding the user to grant screen capture permission.
    @MainActor
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Circle2Search needs permission to record your screen. Please grant access in System Settings > Privacy & Security > Screen Recording."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            // Open Screen Recording settings pane
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }


    // MARK: - Stream Setup and Delegate Methods

    private func setupAndStartStream() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            print("No displays found.")
            throw CaptureError.noDisplaysFound
        }

        let config = SCStreamConfiguration()
        config.width = display.width * 2
        config.height = display.height * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        guard let stream = stream else {
            print("Failed to create SCStream.")
            throw CaptureError.streamCreationFailed
        }

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main) // Process frames on main queue for simplicity initially

        // Use a continuation to wait for the first frame
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            stream.startCapture { [weak self] error in
                if let error = error {
                    print("Stream startCapture failed with error: \(error)")
                    self?.continuation?.resume(throwing: error)
                    self?.continuation = nil // Clear continuation on error
                    DispatchQueue.main.async {
                         self?.isStreamActive = false
                    }
                } else {
                    print("Stream capture started successfully.")
                    // Continuation will be resumed by the delegate when a frame arrives or an error occurs
                }
            }
        }
    }

    // SCStreamDelegate method: Called when a frame is available
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        Task { @MainActor [weak self] in
            self?.handleSampleBuffer(stream: stream, sampleBuffer: sampleBuffer, type: type)
        }
    }

    @MainActor
    private func handleSampleBuffer(stream: SCStream, sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else {
            print("Invalid sample buffer or wrong type received.")
            return
        }

        // Check if we are still waiting for the first frame
        guard continuation != nil else {
            // We already got the frame we needed, ignore subsequent ones for this capture session
            return
        }

        print("Received valid screen sample buffer.")

        // Stop capture immediately after receiving the first valid frame
        stream.stopCapture { [weak self] error in
            if let error = error {
                print("Error stopping stream: \(error)")
                // If stopping fails, try to resume continuation with error?
                self?.continuation?.resume(throwing: CaptureError.captureCancelled) // Indicate failure
            } else {
                print("Stream capture stopped successfully.")
                // If stopping succeeds, proceed with frame processing
                self?.processFrame(sampleBuffer)
            }
            // In either case (success or failure stopping), clear the continuation
            self?.continuation = nil
            DispatchQueue.main.async {
                self?.isStreamActive = false // Mark as inactive
            }
        }
    }

     // Separate function to process the captured frame
    private func processFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let cvImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Failed to get CVPixelBuffer from sample buffer.")
            continuation?.resume(throwing: CaptureError.frameCaptureFailed)
            return
        }

        // Create CGImage from the CVPixelBuffer
        let ciImage = CIImage(cvPixelBuffer: cvImageBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("Failed to create CGImage from CIImage.")
            continuation?.resume(throwing: CaptureError.imageConversionFailed)
            return
        }

        print("Successfully captured frame as CGImage.")
        self.currentBackgroundImage = cgImage
        self.previousApp = NSWorkspace.shared.frontmostApplication // Store the app active *now*

        // Clear regions from any previous run
        self.currentDetailedTextRegions = []

        // Perform initial text rectangle detection BEFORE showing overlay
        Task { [weak self] in
             guard let self = self else { return }
             await self.detectInitialTextRegions(image: cgImage)
             // Convert VNTextObservation.boundingBox to CGRect for the overlay
             let normalizedRects = self.currentDetailedTextRegions.map { $0.normalizedRect }

             if let firstRect = normalizedRects.first {
                 print("CaptureController: Preparing to show overlay. Normalized rects count: \(normalizedRects.count).")
                 print("  First normalizedRect: \(firstRect)")
             }

             // Now show overlay after initial detection is done (or attempted)
             // Ensure this is called on the main thread as it involves UI
             DispatchQueue.main.async {
                 OverlayManager.shared.showOverlay(
                     backgroundImage: self.currentBackgroundImage,
                     detailedTextRegions: self.currentDetailedTextRegions,
                     previousApp: self.previousApp,
                     completion: { [weak self] selectedPath, finalBrushedText in // Expecting String now
                         Task { [weak self] in 
//                             print("CaptureController: Overlay completion: Path: \\(selectedPath != nil), Brushed Text: \\(finalBrushedText ?? "nil")")
                             await self?.handleSelectionCompletion(selectedPath, brushedText: finalBrushedText)
                         }
                 }
             ) 
         }
        } // ADDED: Probable missing '}' for an 'if' block or similar scope within processFrame
 
         // Successfully captured frame, resume continuation
         continuation?.resume(returning: ()) // Indicate success
    }

    // SCStreamDelegate method: Called when the stream stops with an error
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            print("Stream stopped with error: \(error)")
            // Resume the continuation with the error if it's still waiting
            self?.continuation?.resume(throwing: error)
            self?.continuation = nil
            self?.isStreamActive = false
        }
    }


    // MARK: - Path Handling & Analysis (Existing Code)

    // This function is called when the user finishes drawing a path or cancels.
    private func handleSelectionCompletion(_ selectedPath: Path?, brushedText: String?) async {
        if let text = brushedText, !text.isEmpty {
            print("Handling selection based on brushed text: '\\(text)'")
            ResultPanel.shared.presentGoogleQuery(text)
            // No need to crop or re-recognize if OverlayView provides exact text.
            return
        }

        // Fallback to path-based selection if no brushedText, but a path exists
        if let path = selectedPath, let fullImage = self.currentBackgroundImage {
            print("Handling selection based on drawn path (no brushed text provided).")
            await processPathBasedSelection(path, fullImage: fullImage) // processPathBasedSelection may need to be updated if it relies on indices
            return
        }

        print("Handling selection: No brushed text and no valid path, or fullImage is nil.")
        if self.currentBackgroundImage == nil {
             activatePreviousApp()
        }
    }

    // Helper function for the original path-based selection logic
    private func processPathBasedSelection(_ path: Path, fullImage: CGImage) async {
        print("Processing path-based selection logic...")
        let pathBoundsInOverlayCoords = path.boundingRect // These are in overlay's coordinate space
        let imageWidth = CGFloat(fullImage.width)
        let imageHeight = CGFloat(fullImage.height)

        // Placeholder Conversion for path bounds - This needs to be accurate for Vision.
        // Assuming pathBoundsInOverlayCoords are relative to the overlay size which matches screen.
        // Vision expects normalized (0-1) with (0,0) at bottom-left of the image.
        // The OverlayView's path is likely top-left origin based on screen points.
        // This conversion will need careful review based on OverlayView's coordinate system.
        // For now, let's assume path.boundingRect is already somewhat representative of the *area* on the image.
        
        // We need pixel coordinates for cropping. If pathBoundsInOverlayCoords are screen points:
        let cropRectForPath = pathBoundsInOverlayCoords // This IS LIKELY WRONG if path is not in image pixels.
                                                      // For robust solution, path from OverlayView needs to be in normalized image coords or pixels.
        
        print("Path BBox in Overlay Coords (used as crop placeholder): \(cropRectForPath)")


        guard let croppedImage = cropImage(fullImage, pathBoundsInPixelCoords: cropRectForPath) else {
            print("Failed to crop image using path bounds.")
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
                    print("Selected path (for fallback check) intersects with a detected text region: \(region.normalizedRect)")
                    didIntersectWithTextRegion = true
                    break
                }
            }
        }

        if didIntersectWithTextRegion {
            print("Path intersected (fallback check), performing detailed text recognition...")
            await recognizeText(in: croppedImage, directlyRecognizedText: nil)
        } else {
            print("Path did NOT intersect (fallback check) or no regions, falling back to Google Lens.")
            fallbackToGoogleLens(image: croppedImage)
        }
        // State (bg image, regions) should not be cleared here if overlay persists.
        // self.currentBackgroundImage = nil
        // self.currentDetailedTextRegions = []
        // Cleanup UI (activatePreviousApp) is also removed from here.
    }

    // Helper function stub for cropping - needs refinement
    // Expects cropRect in PIXEL coordinates of the image
    func cropImage(_ image: CGImage, pathBoundsInPixelCoords cropRect: CGRect) -> CGImage? {
        print("Cropping image to pixel rect: \(cropRect)")
        // Ensure the cropRect is within the image bounds
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let validCropRect = cropRect.intersection(imageRect).integral // Use integral to avoid subpixel issues

        guard !validCropRect.isNull, validCropRect.width >= 1, validCropRect.height >= 1 else {
            print("Invalid or zero-size crop rectangle after intersection/integral: \(validCropRect)")
            return nil
        }
         guard let cropped = image.cropping(to: validCropRect) else {
             print("CGImage.cropping failed for rect: \(validCropRect).")
             return nil
         }
         print("Cropping successful.")
        return cropped
    }

    // MARK: - Vision Analysis

    /// Performs initial, fast detection of text regions on the full image.
    private func detectInitialTextRegions(image: CGImage) async {
        print("Starting initial text region detection...")
        self.currentDetailedTextRegions = [] // Clear previous results

        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let strongSelf = self else { return } // Safely unwrap self

            let anyResults = request.results

            if let concreteObservations = anyResults as? [VNRecognizedTextObservation] {
                var newDetailedRegions: [DetailedTextRegion] = []
                for observation in concreteObservations {
                    if let topCandidate = observation.topCandidates(1).first {
                        // We need to calculate screenRect here if it's not already done for this observation
                        // Assuming self.currentBackgroundImage is available for dimensions
                        // This part depends on where normalizedRects were previously calculated. 
                        // Let's assume we have a helper or do it inline for now.
                        // The normalizedRect IS observation.boundingBox
                        // The screenRect needs to be calculated based on overlay/canvas size AFTER overlay is shown.
                        // For now, we will pass the observation and its normalizedRect.
                        // OverlayView will be responsible for calculating screenRect for its canvas size.
                        newDetailedRegions.append(DetailedTextRegion(
                            recognizedText: topCandidate,
                            screenRect: .zero, // Placeholder, will be calculated in OverlayView based on its size
                            normalizedRect: observation.boundingBox
                        ))
                    }
                }
                strongSelf.currentDetailedTextRegions = newDetailedRegions // New property in CaptureController

                // ---- REMOVE EXPLORATORY LOGGING or keep if still needed for debug ----
                
            } else {
                strongSelf.currentDetailedTextRegions = []
                if anyResults == nil {
                    print("Vision completion: anyResults was nil.")
                } else {
                    print("Vision completion: anyResults was not nil, but cast failed. Actual type of anyResults: \(type(of: anyResults!))")
                    if let innerArray = anyResults, innerArray.isEmpty {
                        print("Vision completion: anyResults was an empty array of some other type.")
                    } else if let innerArray = anyResults, !innerArray.isEmpty {
                        print("Vision completion: anyResults was non-empty, but elements are not VNRecognizedTextObservation. Type of first element: \(type(of: innerArray.first!))")
                    }
                }
            }
            return
        }
        // Explicitly use VNRequestTextRecognitionLevel
        request.recognitionLevel = VNRequestTextRecognitionLevel.accurate // Changed to .accurate
        request.usesLanguageCorrection = false // Not needed for just finding rects
        // request.minimumTextHeight = 0.01 // Optional: try if .accurate alone doesn't work

        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try requestHandler.perform([request])
            // Log that the perform call has completed. 
            // The actual results/count are logged within the request's completion handler.
            print("VNImageRequestHandler perform complete for initial text detection.")
        } catch {
            print("Failed to perform initial text detection: \(error)")
        }
    }

    // MARK: - Text Recognition

    /// Performs detailed text recognition on the cropped image and presents results.
    private func recognizeText(in croppedImage: CGImage, directlyRecognizedText: String?) async {
        print("Performing detailed text recognition on cropped image...")

        if let directText = directlyRecognizedText, !directText.isEmpty {
            print("Using directly recognized text: '\\(directText)'")
            Task { @MainActor in // Ensure UI updates on main thread
                ResultPanel.shared.presentGoogleQuery(directText)
                // Do NOT activate previous app here, overlay should stay focused with panel
            }
            return // Skip Vision request if we have direct text
        }

        print("No direct text provided or empty, proceeding with Vision recognition...")
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
                print("Vision detailed text recognition found no text.")
                Task { @MainActor in // Ensure UI updates on main thread
                    ResultPanel.shared.presentGoogleQuery("No text found in the selected area.")
                    // OverlayManager.shared.dismissOverlay() // <-- REMOVED: Do not dismiss
                    // self?.activatePreviousApp() // <-- REMOVED: Do not activate previous app
                }
            } else {
                let queryString = recognizedStrings.joined(separator: " ")
                print("Vision recognized text: \\(queryString)")
                Task { @MainActor in // Ensure UI updates on main thread
                    // OverlayManager.shared.dismissOverlay() // <-- REMOVED THIS (already done in previous step, but ensure it's gone)
                    ResultPanel.shared.presentGoogleQuery(queryString)
                    // self?.activatePreviousApp() // <-- REMOVED (already done in previous step, ensure gone)
                }
            }
        }
        
        request.recognitionLevel = VNRequestTextRecognitionLevel.accurate
        
        let handler = VNImageRequestHandler(cgImage: croppedImage, options: [:])
        do {
            try handler.perform([request])
            print("Detailed text recognition request performed (Vision).")
        } catch {
            print("Failed to perform detailed text recognition (Vision handler): \\(error)")
            Task { @MainActor in // Ensure UI updates on main thread
                ResultPanel.shared.presentGoogleQuery("Error processing image for text recognition.")
                 // OverlayManager.shared.dismissOverlay() // <-- REMOVED: Do not dismiss
                 // self?.activatePreviousApp() // <-- REMOVED: Do not activate previous app
            }
        }
    }

    // MARK: - Google Lens Fallback

    /// Encodes the image and opens Google Lens search in the browser.
    private func fallbackToGoogleLens(image: CGImage) {
        print("Falling back to Google Lens search...")
        
        // 1. Encode image data (using JPEG for efficiency)
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            print("Error creating image destination for Google Lens fallback.")
            DispatchQueue.main.async { [weak self] in // Ensure cleanup happens
                 OverlayManager.shared.dismissOverlay()
                 self?.activatePreviousApp()
            }
            return
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            print("Error finalizing image destination for Google Lens fallback.")
             DispatchQueue.main.async { [weak self] in
                 OverlayManager.shared.dismissOverlay()
                 self?.activatePreviousApp()
             }
            return
        }
        let imageData = mutableData as Data
        _ = imageData // Silence unused variable warning until POST is implemented
 
         // 2. Construct Google Lens URL (Basic Reverse Image Search URL)
         // Note: A more specific Lens endpoint might exist but reverse image search is a common fallback.
        var components = URLComponents(string: "https://lens.google.com/uploadbybinary")!
        // Google Lens upload typically uses POST, not a simple GET with data. Direct URL upload is tricky.
        // A more robust way might involve simulating a form submission or finding a specific API if available.
        // Using the standard reverse image search URL as a simpler alternative for now:
        components = URLComponents(string: "https://images.google.com/searchbyimage/upload")!
        
        guard let url = components.url else {
             print("Error creating Google search URL.")
              DispatchQueue.main.async { [weak self] in
                 OverlayManager.shared.dismissOverlay()
                 self?.activatePreviousApp()
             }
            return
        }
        
        // 3. Open URL (This requires handling the upload, which NSWorkspace.open doesn't do directly for POST)
        // The images.google.com URL expects a POST request with the image data.
        // Opening this URL directly will likely just show the upload page.
        // A proper implementation requires making an HTTP POST request.
        // For simplicity here, we'll just open the base Lens page as a placeholder action.
        // You would need URLSession or a library like Alamofire to POST the imageData.
        
        print("Opening Google Lens page (actual image upload requires HTTP POST). URL: \(url.absoluteString)")
        // NSWorkspace.shared.open(url) // This would just open the upload page
        
        // Placeholder: Open main Google Images page instead until POST is implemented
        if let googleImagesUrl = URL(string: "https://images.google.com/") {
             NSWorkspace.shared.open(googleImagesUrl)
        }
        
        
        // 4. Cleanup UI
        DispatchQueue.main.async { [weak self] in
            // OverlayManager.shared.dismissOverlay() // <-- REMOVED THIS
            self?.activatePreviousApp() // Still activate previous app if it's a fallback that opens a browser page.
                                        // User can re-trigger overlay. This might need further thought
                                        // depending on desired UX for fallback.
                                        // For now, keeping activatePreviousApp as it's a distinct action (Lens)
                                        // not an update to the existing panel.
        }
    }

    // MARK: - Helper Functions

    /// Reactivates the application that was active before the overlay was shown.
    func activatePreviousApp() {
        // ... [Existing reactivatePreviousApp logic remains largely the same] ...
         if let app = previousApp {
            print("Reactivating previous app: \(app.localizedName ?? "Unknown")")
            app.activate()
        } else {
            print("No previous app recorded to reactivate.")
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
            print("Failed to get TIFF representation from NSImage for Lens search.")
            return
        }

        // 3. Convert TIFF data to PNG data using NSBitmapImageRep
        guard let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            print("Failed to convert TIFF data to PNG data for Lens search.")
            return
        }

        // Construct Google Lens URL (simplified version, might need POST)
        let urlString = "https://lens.google.com/uploadbyurl?url=data:image/png;base64,\(pngData.base64EncodedString())"

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else {
            print("Failed to create Google Lens URL.")
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
            print("Failed to create CVPixelBuffer, status: \(status)")
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
            print("Failed to create CGContext for CVPixelBuffer")
            CVPixelBufferUnlockBaseAddress(unwrappedPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(unwrappedPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

        return unwrappedPixelBuffer
    }

    deinit {
        print("CaptureController deallocated")
    }
}
