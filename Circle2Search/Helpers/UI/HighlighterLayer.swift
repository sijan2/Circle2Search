// Filename: HighlighterLayer.swift
import Cocoa
import QuartzCore // For CAShapeLayer
import Vision // For VNRecognizedTextObservation

class HighlighterLayer {
    
    private static var currentLayer: CAShapeLayer?
    
    /// Creates and displays a CAShapeLayer highlighting the recognized text observations.
    /// - Parameters:
    ///   - observations: The filtered text observations to highlight.
    ///   - cropOrigin: The origin of the cropped image.
    ///   - croppedImageSize: The size of the cropped image.
    ///   - targetView: The NSView onto which the highlight layer should be added.
    static func show(observations: [VNRecognizedTextObservation], 
                      cropOrigin: CGPoint, 
                      croppedImageSize: CGSize, 
                      targetView: NSView) {
        // Remove previous layer if any
        currentLayer?.removeFromSuperlayer()
        
        guard !observations.isEmpty, let superlayer = targetView.layer else {
            print("HighlighterLayer: No observations or target layer found.")
            return
        }
        
        // --- Path Creation --- 
        let combinedPath = CGMutablePath()
        let cornerRadius: CGFloat = 3.0
        let inset: CGFloat = -2.0 // Negative inset expands the box
        
        for observation in observations {
            // Get bounding box in normalized coordinates (0-1), relative to the CROPPED image
            let normBoundingBox = observation.boundingBox
            
            // 1. Convert normalized rect to pixel coordinates within the CROPPED image
            let croppedPixelRect = VNImageRectForNormalizedRect(normBoundingBox, 
                                                                Int(croppedImageSize.width),
                                                                Int(croppedImageSize.height))
            
            // 2. Translate this pixel rect by the cropOrigin to get coordinates in the FULL image space
            let fullImagePixelRect = croppedPixelRect.offsetBy(dx: cropOrigin.x, dy: cropOrigin.y)
            
            // 3. Convert the rectangle from the full image's coordinate system (bottom-left origin assumed by VNImageRect*) 
            //    to the target view's layer coordinate system (often top-left origin) using the inverse transform.
            let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -targetView.bounds.height)
            let layerRect = fullImagePixelRect.applying(transform)
            
            // Inset and create rounded rect path
            let insetRect = layerRect.insetBy(dx: inset, dy: inset)
            let roundedRectPath = CGPath(roundedRect: insetRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            combinedPath.addPath(roundedRectPath)
        }
        // ---------------------
        
        let layer = CAShapeLayer()
        layer.path = combinedPath // Use the combined path
        layer.fillColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
        layer.strokeColor = nil // No stroke
        layer.opacity = 0.0 // Start transparent for fade-in
        superlayer.addSublayer(layer)
        currentLayer = layer
        
        // Example Fade-in
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0.0
        fadeIn.toValue = 1.0
        fadeIn.duration = 0.08 // 80ms
        layer.opacity = 1.0 // Set final value
        layer.add(fadeIn, forKey: "fadeInOpacity")
    }
    
    /// Removes the currently displayed highlight layer.
    static func hide() {
        currentLayer?.removeFromSuperlayer()
        currentLayer = nil
        print("HighlighterLayer: Hidden.")
    }
    
    // --- Helper Method for Coordinate Transformation ---
    
    /// Converts a VNRecognizedTextObservation's bounding box to a CGRect in the target view's coordinate space (top-left origin).
    private static func viewRectForObservation(_ observation: VNRecognizedTextObservation, 
                                               cropOrigin: CGPoint, 
                                               croppedImageSize: CGSize, 
                                               viewSize: CGSize) -> CGRect {
        let normalizedRect = observation.boundingBox
        
        // 1. Convert normalized rect to pixel coordinates within the CROPPED image
        let croppedPixelRect = VNImageRectForNormalizedRect(normalizedRect, 
                                                            Int(croppedImageSize.width),
                                                            Int(croppedImageSize.height))
        
        // 2. Translate this pixel rect by the cropOrigin to get coordinates in the FULL image space
        let fullImagePixelRect = croppedPixelRect.offsetBy(dx: cropOrigin.x, dy: cropOrigin.y)
        
        // 3. Convert the rectangle from the full image's coordinate system (bottom-left origin assumed by VNImageRect*) 
        //    to the target view's layer coordinate system (often top-left origin) using the inverse transform.
        let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -viewSize.height)
        let layerRect = fullImagePixelRect.applying(transform)
        
        return layerRect
    }
}
