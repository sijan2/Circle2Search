// CaptureError.swift
// Circle2Search
//
// Errors specific to the capture process

import Foundation

/// Errors specific to the capture process
enum CaptureError: Error {
    case noDisplaysFound
    case streamCreationFailed
    case frameCaptureFailed
    case permissionDenied
    case captureCancelled
    case imageConversionFailed
}
