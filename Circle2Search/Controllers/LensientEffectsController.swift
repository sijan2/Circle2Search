// LensientEffectsController.swift - Simple shimmer controller
import Foundation
import AppKit
import QuartzCore
import simd
import Combine

// MARK: - Shimmer State
enum ShimmerState {
    case hidden
    case idle
    case tracking
    case selection
}

// MARK: - Lensient Effects Controller
@MainActor
final class LensientEffectsController: ObservableObject {
    static let shared = LensientEffectsController()
    
    // Published state
    @Published private(set) var state: ShimmerState = .hidden
    @Published var opacity: Float = 0.0
    @Published var centerX: Float = 0.0
    @Published var centerY: Float = 0.0
    @Published var rectangleAmount: Float = 0.0
    @Published var rectWidth: Float = 0.0
    @Published var rectHeight: Float = 0.0
    
    private(set) var viewSize: CGSize = .zero
    private var animationTimer: Timer?
    private(set) var startTime: CFTimeInterval = 0
    
    // Targets for animation
    private var opacityTarget: Float = 0.0
    private var centerXTarget: Float = 0.0
    private var centerYTarget: Float = 0.0
    
    // Android shimmer colors from cyvu.java
    let shimmerColors: [SIMD3<Float>] = [
        SIMD3<Float>(0.957, 0.176, 0.149),
        SIMD3<Float>(0.027, 0.431, 1.000),
        SIMD3<Float>(0.043, 0.800, 0.380),
        SIMD3<Float>(1.000, 0.698, 0.000),
        SIMD3<Float>(0.933, 0.302, 0.278),
        SIMD3<Float>(0.027, 0.431, 1.000),
        SIMD3<Float>(0.043, 0.800, 0.380),
        SIMD3<Float>(1.000, 0.698, 0.000)
    ]
    
    let baseRadius: Float = 300.0
    
    // Dynamic radius based on screen size
    var radius: Float {
        // Use larger of width/height to ensure full coverage
        let screenDimension = max(Float(viewSize.width), Float(viewSize.height))
        return screenDimension * 0.5  // Half the screen size for good coverage
    }
    
    private init() {
        startTime = CACurrentMediaTime()
    }
    
    func setViewSize(_ size: CGSize) {
        viewSize = size
        if centerX == 0 && centerY == 0 {
            centerX = Float(size.width) * 0.5
            centerY = Float(size.height) * 0.5
            centerXTarget = centerX
            centerYTarget = centerY
        }
    }
    
    func showIdle() {
        state = .idle
        centerXTarget = Float(viewSize.width) * 0.5
        centerYTarget = Float(viewSize.height) * 0.5
        centerX = centerXTarget
        centerY = centerYTarget
        opacityTarget = 1.0
        startAnimation()
    }
    
    func startTracking(at point: CGPoint) {
        state = .tracking
        centerXTarget = Float(point.x)
        centerYTarget = Float(point.y)
    }
    
    func updateTracking(at point: CGPoint) {
        guard state == .tracking else { return }
        centerXTarget = Float(point.x)
        centerYTarget = Float(point.y)
    }
    
    func showSelection(rect: CGRect) {
        state = .selection
        centerXTarget = Float(rect.midX)
        centerYTarget = Float(rect.midY)
        rectWidth = Float(rect.width)
        rectHeight = Float(rect.height)
        rectangleAmount = 1.0
    }
    
    func hide() {
        state = .hidden
        opacityTarget = 0.0
        startAnimation()
    }
    
    var shaderTime: Float {
        Float(CACurrentMediaTime() - startTime)
    }
    
    private func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }
    
    private func tick() {
        let speed: Float = 0.15
        
        // Lerp towards targets
        opacity += (opacityTarget - opacity) * speed
        centerX += (centerXTarget - centerX) * speed
        centerY += (centerYTarget - centerY) * speed
        
        // Stop if hidden and faded out
        if state == .hidden && opacity < 0.01 {
            opacity = 0
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }
}
