// Filename: CropManager.swift
import CoreGraphics
import AppKit // For Path extension if needed

struct CropManager {
    
    /// Crops a CGImage to the bounding box of a given CGPath.
    /// - Parameters:
    ///   - image: The source CGImage.
    ///   - path: The CGPath whose bounding box defines the crop area.
    /// - Returns: A new CGImage containing the cropped portion, or nil if cropping fails.
    static func cropImage(_ image: CGImage, to path: CGPath) -> CGImage? {
        // Get the bounding box of the path in the image's coordinate space
        let bounds = path.boundingBoxOfPath // Assumes path coordinates match image coordinates
        
        // Ensure the bounds are valid and within the image
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let intersection = bounds.intersection(imageRect)
        
        guard !intersection.isNull, intersection.size.width > 0, intersection.size.height > 0 else {
            print("CropManager: Invalid or zero-size crop bounds derived from path.")
            return nil
        }
        
        // Perform the crop
        guard let croppedImage = image.cropping(to: intersection) else {
            print("CropManager: CGImage.cropping(to:) failed.")
            return nil
        }
        
        print("CropManager: Image successfully cropped to \(intersection).")
        return croppedImage
    }
}

// Helper extension (already present in CaptureController, but good to have generally)
// Could be moved to a separate Utilities file if needed.
/*
extension CGPath {
    var boundingBoxOfPath: CGRect {
        return self.boundingBox
    }
}
*/
