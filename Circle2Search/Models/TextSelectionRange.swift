// TextSelectionRange.swift
// Circle2Search
//
// Represents a range of selected text indices

import Foundation

/// Represents a range of selected text indices (start to end)
struct TextSelectionRange: Equatable {
    var start: Int
    var end: Int
}

/// Represents which selection handle is being interacted with
enum SelectionHandle {
    case start
    case end
    case none
}
