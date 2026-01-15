// LensientRenderer.swift - Simple shimmer renderer
import Foundation
import Metal
import MetalKit
import simd
import AppKit
import SwiftUI

// MARK: - Shader Uniforms
struct ShimmerUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var opacity: Float
    var centerX: Float
    var centerY: Float
    var radius: Float
    var padding1: Float
    var padding2: Float
    var color0: SIMD4<Float>
    var color1: SIMD4<Float>
    var color2: SIMD4<Float>
    var color3: SIMD4<Float>
    var color4: SIMD4<Float>
    var color5: SIMD4<Float>
    var color6: SIMD4<Float>
    var color7: SIMD4<Float>
}

// MARK: - Renderer
@MainActor
class LensientRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    
    weak var effectsController: LensientEffectsController?
    
    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        
        super.init()
        
        setupPipeline()
        setupBuffers()
        self.effectsController = LensientEffectsController.shared
    }
    
    private func setupPipeline() {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunc = library.makeFunction(name: "shimmer_vertex"),
              let fragmentFunc = library.makeFunction(name: "shimmer_fragment") else {
            print("LensientRenderer: Failed to load shaders")
            return
        }
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    
    private func setupBuffers() {
        let vertices: [Float] = [
            -1, -1, 0, 1,
             1, -1, 1, 1,
            -1,  1, 0, 0,
             1,  1, 1, 0
        ]
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * 4, options: .storageModeShared)
        uniformBuffer = device.makeBuffer(length: MemoryLayout<ShimmerUniforms>.stride, options: .storageModeShared)
    }
    
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        Task { @MainActor in
            effectsController?.setViewSize(size)
        }
    }
    
    nonisolated func draw(in view: MTKView) {
        Task { @MainActor in
            performDraw(in: view)
        }
    }
    
    private func performDraw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let pipeline = pipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let controller = effectsController else { return }
        
        let size = view.drawableSize
        let time = controller.shaderTime
        
        // Update uniforms
        if let buffer = uniformBuffer {
            let ptr = buffer.contents().bindMemory(to: ShimmerUniforms.self, capacity: 1)
            let colors = controller.shimmerColors
            
            ptr.pointee = ShimmerUniforms(
                resolution: SIMD2<Float>(Float(size.width), Float(size.height)),
                time: time,
                opacity: controller.opacity,
                centerX: controller.centerX,
                centerY: controller.centerY,
                radius: controller.radius,
                padding1: 0,
                padding2: 0,
                color0: SIMD4<Float>(colors[0], 0),
                color1: SIMD4<Float>(colors[1], 0),
                color2: SIMD4<Float>(colors[2], 0),
                color3: SIMD4<Float>(colors[3], 0),
                color4: SIMD4<Float>(colors[4], 0),
                color5: SIMD4<Float>(colors[5], 0),
                color6: SIMD4<Float>(colors[6], 0),
                color7: SIMD4<Float>(colors[7], 0)
            )
        }
        
        // Clear to fully transparent
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - SwiftUI Wrapper
struct LensientMetalView: NSViewRepresentable {
    @ObservedObject var effectsController = LensientEffectsController.shared
    @Binding var isPaused: Bool
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }
        
        let view = MTKView(frame: .zero, device: device)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        
        // Remove any border/background
        view.wantsLayer = true
        view.layer?.borderWidth = 0
        view.layer?.cornerRadius = 0
        
        if let renderer = LensientRenderer(device: device) {
            view.delegate = renderer
            context.coordinator.renderer = renderer
        }
        
        return view
    }
    
    func updateNSView(_ view: MTKView, context: Context) {
        view.isPaused = isPaused
    }
    
    class Coordinator {
        var renderer: LensientRenderer?
    }
}
