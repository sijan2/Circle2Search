import CoreImage
import AVFoundation
import AppKit // For NSRect, NSBitmapImageRep, NSImage
import Foundation
import CoreGraphics
import VideoToolbox // For VTCreateCGImageFromCVPixelBuffer

struct ImageUtils {

    /// Creates a CIImage from a CVPixelBuffer.
    static func ciImage(from pixelBuffer: CVPixelBuffer) -> CIImage? {
        return CIImage(cvPixelBuffer: pixelBuffer)
    }

    /// Creates an NSImage from a CIImage.
    /// Useful for debugging or displaying.
    static func nsImage(from ciImage: CIImage) -> NSImage? {
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("Failed to create CGImage from CIImage.")
            return nil
        }
        // Important: NSImage size should be based on CGImage dimensions for correct display
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Converts a CIImage to PNG Data.
    /// - Parameter ciImage: The image to convert.
    /// - Returns: PNG Data or nil if conversion fails.
    static func pngData(from ciImage: CIImage) -> Data? {
        let context = CIContext()
        guard let colorSpace = ciImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
             print("Failed to get color space from CIImage")
             return nil
        }
        // Use kCIFormatRGBA8 for standard PNG compatibility if possible
        // Note: The format might depend on the source CIImage's capabilities.
        // If the image isn't in a renderable format, this might fail.
        return context.pngRepresentation(of: ciImage, 
                                         format: .RGBA8, // Common format for PNG
                                         colorSpace: colorSpace,
                                         options: [:])
        
        // Fallback/Alternative using NSBitmapImageRep if context.pngRepresentation fails:
        /*
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("Failed to create CGImage for PNG conversion")
            return nil
        }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
        */
    }

    /// Crops a CIImage based on a rectangle defined in top-left origin coordinates.
    /// - Parameters:
    ///   - ciImage: The source CIImage (assumed to represent the full screen or buffer).
    ///   - cropRect: The rectangle defining the crop area, with origin at the top-left.
    /// - Returns: A new CIImage containing only the cropped area, or nil if cropping fails.
    static func cropCIImage(ciImage: CIImage, to cropRect: CGRect) -> CIImage? {
        // CIImage's coordinate system has its origin at the bottom-left.
        // The input cropRect has its origin at the top-left (from screen coordinates).
        // We need to convert the top-left rect to Core Image's bottom-left coordinate system.

        let imageExtent = ciImage.extent

        // Clamp the cropRect to the image bounds to prevent crashes if selection goes outside
        // Convert cropRect (top-left origin) to image coordinates (typically 0,0 origin for extent)
        let clampedRect = cropRect.intersection(CGRect(origin: .zero, size: imageExtent.size)) 
        guard !clampedRect.isNull, clampedRect.width > 0, clampedRect.height > 0 else {
            print("Crop rectangle \(cropRect) is outside image extent \(imageExtent) or has zero size after clamping.")
            return nil
        }

        // Convert the clamped, top-left origin rect to Core Image's bottom-left origin
        let ciCropRect = CGRect(
            x: clampedRect.origin.x,
            y: imageExtent.height - clampedRect.origin.y - clampedRect.height,
            width: clampedRect.width,
            height: clampedRect.height
        )
        
        // Check if the calculated ciCropRect is valid within the image extent
        // Perform intersection again in CI coordinates to handle potential floating point issues
        let finalCiCropRect = ciCropRect.intersection(imageExtent)
        guard !finalCiCropRect.isNull, finalCiCropRect.width > 0, finalCiCropRect.height > 0 else {
             print("Calculated Core Image crop rect \(ciCropRect) is outside or invalid within image extent \(imageExtent). Final intersection: \(finalCiCropRect)")
             return nil
        }

        return ciImage.cropped(to: finalCiCropRect)
    }

    /// Convenience function to crop directly from a CVPixelBuffer.
    static func cropPixelBuffer(pixelBuffer: CVPixelBuffer, to cropRect: CGRect) -> CIImage? {
        guard let ciImage = ciImage(from: pixelBuffer) else { return nil }
        return cropCIImage(ciImage: ciImage, to: cropRect)
    }
}

// Extension to create CGImage from CVPixelBuffer
extension CGImage {
    static func create(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        return cgImage
    }
}

// Optional: Extension to convert CVPixelBuffer directly to NSImage
extension NSImage {
    convenience init?(pixelBuffer: CVPixelBuffer) {
        guard let cgImage = CGImage.create(from: pixelBuffer) else {
            return nil
        }
        self.init(cgImage: cgImage, size: NSSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)))
    }
}
