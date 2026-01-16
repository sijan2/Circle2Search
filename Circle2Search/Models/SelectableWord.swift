// SelectableWord.swift
// Circle2Search
//
// Represents a selectable word from OCR with position information

import Foundation

/// Represents a selectable word from OCR with screen position information
struct SelectableWord: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let screenRect: CGRect       
    let normalizedRect: CGRect   // Original normalized rect from Vision for this word/segment
    let globalIndex: Int         // Unique index in the flattened list of all words
    let sourceRegionIndex: Int   // Index of the parent DetailedTextRegion
    let sourceWordSwiftRange: Range<String.Index> // Range within the source region's full string
}
