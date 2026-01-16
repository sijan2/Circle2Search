// LensientEffectsController.swift - Android-style shimmer controller
import Foundation
import AppKit
import QuartzCore
import simd
import Combine

// MARK: - State
enum ShimmerState: Int {
    case hidden = 0
    case idle = 1        // Fullscreen shimmer
    case tracking = 2    // Brush tip glow only
}

// MARK: - Spring Physics
struct SpringValue {
    var current: Float
    var target: Float
    var velocity: Float = 0
    let stiffness: Float
    let damping: Float
    
    init(_ initial: Float, stiffness: Float = 800, damping: Float = 0.9) {
        self.current = initial
        self.target = initial
        self.stiffness = stiffness
        self.damping = damping
    }
    
    mutating func step(dt: Float) {
        let displacement = target - current
        let springForce = displacement * stiffness
        velocity = (velocity + springForce * dt) * damping
        current += velocity * dt
    }
    
    mutating func set(_ value: Float) {
        target = value
    }
    
    mutating func snap(_ value: Float) {
        current = value
        target = value
        velocity = 0
    }
}

// MARK: - Controller
@MainActor
final class LensientEffectsController: ObservableObject {
    static let shared = LensientEffectsController()
    
    @Published private(set) var state: ShimmerState = .hidden
    
    // Animated values
    var opacity = SpringValue(0, stiffness: 1200, damping: 0.85)
    var centerX = SpringValue(0, stiffness: 1500, damping: 0.92)  // Fast follow
    var centerY = SpringValue(0, stiffness: 1500, damping: 0.92)
    var trackingAmount = SpringValue(0, stiffness: 2000, damping: 0.85)  // FAST transition to hide fullscreen
    var particleRadius = SpringValue(120, stiffness: 800, damping: 0.9)  // Bigger default
    
    private(set) var viewSize: CGSize = .zero  // In PIXELS (drawable size)
    private(set) var scaleFactor: CGFloat = 2.0  // Retina scale
    private(set) var startTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    
    // Google colors
    let shimmerColors: [SIMD3<Float>] = [
        SIMD3<Float>(0.267, 0.129, 0.588),  // Purple
        SIMD3<Float>(0.027, 0.224, 1.000),  // Blue
        SIMD3<Float>(0.043, 0.518, 0.129),  // Green
        SIMD3<Float>(1.000, 0.698, 0.000),  // Yellow
        SIMD3<Float>(0.933, 0.314, 0.278),  // Red
        SIMD3<Float>(0.027, 0.224, 1.000),
        SIMD3<Float>(0.043, 0.518, 0.129),
        SIMD3<Float>(0.267, 0.129, 0.588)
    ]
    
    private init() {
        startTime = CACurrentMediaTime()
        lastFrameTime = startTime
        // Initialize viewSize from main screen immediately
        if let screen = NSScreen.main {
            let backing = screen.backingScaleFactor
            scaleFactor = backing
            viewSize = CGSize(width: screen.frame.width * backing, height: screen.frame.height * backing)
        }
    }
    
    func setViewSize(_ size: CGSize, scale: CGFloat = 2.0) {
        viewSize = size  // This should be drawable size (pixels)
        scaleFactor = scale
    }
    
    /// Show fullscreen shimmer on trigger
    func showIdle() {
        state = .idle
        startTime = CACurrentMediaTime()
        lastFrameTime = startTime
        
        opacity.snap(0.7)
        trackingAmount.snap(0)  // Fullscreen mode
    }
    
    /// Transition to brush tip glow - fullscreen disappears, only tip glow remains
    func startTracking(at point: CGPoint) {
        state = .tracking
        
        // Convert SwiftUI points to Metal pixels
        // SwiftUI: Y=0 at top, in points
        // Metal: Y=0 at bottom, in pixels
        let pixelX = Float(point.x) * Float(scaleFactor)
        let pixelY = Float(viewSize.height) - (Float(point.y) * Float(scaleFactor))
        
        // Snap position to touch point immediately
        centerX.snap(pixelX)
        centerY.snap(pixelY)
        
        // INSTANT transition: fullscreen vanishes, only tip glow
        trackingAmount.snap(1.0)  // SNAP = instant, no animation!
        particleRadius.snap(60)   // 60px - nice visible size
        opacity.snap(0.95)
    }
    
    /// Update brush tip position while drawing
    func updateTracking(at point: CGPoint) {
        guard state == .tracking else { return }
        // Convert SwiftUI points to Metal pixels
        let pixelX = Float(point.x) * Float(scaleFactor)
        let pixelY = Float(viewSize.height) - (Float(point.y) * Float(scaleFactor))
        // SNAP for instant follow - no spring lag!
        centerX.snap(pixelX)
        centerY.snap(pixelY)
    }
    
    /// Show selection glow (optional - can keep tip glow)
    func showSelection(rect: CGRect) {
        // Keep tracking mode, just update position
        // Convert SwiftUI points to Metal pixels
        let pixelX = Float(rect.midX) * Float(scaleFactor)
        let pixelY = Float(viewSize.height) - (Float(rect.midY) * Float(scaleFactor))
        centerX.set(pixelX)
        centerY.set(pixelY)
        particleRadius.set(Float(max(rect.width, rect.height)) * Float(scaleFactor) * 0.4)
    }
    
    /// Hide everything - called when drawing ends
    func hide() {
        state = .hidden
        opacity.set(0)
    }
    
    var shaderTime: Float {
        Float(CACurrentMediaTime() - startTime)
    }
    
    var baseRadius: Float {
        Float(max(viewSize.width, viewSize.height)) * 0.5
    }
    
    /// Called by Metal renderer each frame - drives spring physics in sync with GPU
    func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrameTime, 1.0/30.0))
        lastFrameTime = now
        
        opacity.step(dt: dt)
        centerX.step(dt: dt)
        centerY.step(dt: dt)
        trackingAmount.step(dt: dt)
        particleRadius.step(dt: dt)
    }
}
