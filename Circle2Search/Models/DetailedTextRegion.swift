// DetailedTextRegion.swift
// Circle2Search
//
// Represents a detected text region from OCR with bounding box information

import Foundation
import Vision

/// Represents a detected text region from OCR with bounding box information
struct DetailedTextRegion: Identifiable, Equatable {
    let id = UUID()
    let recognizedText: VNRecognizedText // The top candidate text object from Vision
    let screenRect: CGRect // The screen-coordinate bounding box for the entire observation
    let normalizedRect: CGRect // The normalized bounding box for the entire observation (0,0 bottom-left)
    // String is directly available via recognizedText.string

    // Equatable conformance
    static func == (lhs: DetailedTextRegion, rhs: DetailedTextRegion) -> Bool {
        return lhs.id == rhs.id && lhs.normalizedRect == rhs.normalizedRect && lhs.recognizedText.string == rhs.recognizedText.string
    }
}
