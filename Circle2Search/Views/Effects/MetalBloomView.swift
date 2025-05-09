// Filename: MetalBloomView.swift
import SwiftUI
import MetalKit

// MARK: - Shared Uniform Structures (Ensure these match .metal files)

// Matches Noise.metal
struct NoiseUniforms {
    var time: Float = 0.0
    var resolution: simd_float2 = .zero
    var noiseScale: Float = 10.0       // Spatial frequency
    var pulseFrequency: Float = 7.0    // Hz (6-8 Hz range)
    var pulseAmplitude: Float = 0.06   // Intensity (0.06)
    var scrollSpeed: Float = 1200.0    // px/s
}

// Matches Spotlight.metal
struct SpotlightUniforms {
    var time: Float = 0.0 // Set dynamically
    var resolution: simd_float2 = .zero // Set dynamically
    var spotlightHeight: Float = 400.0 // px
    var spotlightSpeed: Float = 1200.0 // px/s
    var lightModeTint: simd_float4 = .init(x: 250/255.0, y: 250/255.0, z: 250/255.0, w: 0.07) // rgba(250,250,250,0.07)
    var darkModeTint: simd_float4 = .init(x: 0.0, y: 0.0, z: 0.0, w: 0.12)         // rgba(0,0,0,0.12)
    // Use UInt32 for better Metal buffer alignment/safety
    var isDarkMode: UInt32 = 0 // Set dynamically (0 for light, 1 for dark)
    var spotlightBrightness: Float = 1.2 // 20% brighter under spotlight
    var topInset: Float = 0.0 // Status bar inset proportion (0.0-1.0)
}

// MARK: - MetalBloomView

struct MetalBloomView: NSViewRepresentable {
    // Inputs from SwiftUI
    var isActuallyVisible: Bool // Tracks if the window is visible
    // @Binding var time: Float // REMOVED - Time will be managed by Renderer
    var isDarkMode: Bool // To select the correct tint
    // Pass configurations directly (could be @State in parent view)
    var noiseConfig: NoiseUniforms
    var spotlightConfig: SpotlightUniforms
    @Binding var isPausedBinding: Bool // Control the pause state

    func makeCoordinator() -> Coordinator {
        print("Making Coordinator")
        // Pass initial dark mode state
        return Coordinator(self, isDarkMode: isDarkMode)
    }

    func makeNSView(context: Context) -> MTKView {
        print("Making MTKView")
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator // Coordinator is the delegate
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false // Rely on draw loop
        mtkView.isPaused = isPausedBinding // Set initial pause state

        // DEBUG: Explicitly set alpha and opaque status
        // mtkView.alphaValue = 1.0 // COMMENTED OUT FOR TESTING
        mtkView.layer?.isOpaque = false // REVERTED TO FALSE (was true for debug, original was false)

        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        mtkView.device = defaultDevice
        print("Metal Device: \(defaultDevice.name)")

        // *** Crucial for Transparency ***
        mtkView.layer?.isOpaque = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0) // Fully transparent clear
        mtkView.colorPixelFormat = .bgra8Unorm_srgb // Use sRGB format for gamma correction if needed

        context.coordinator.renderer.loadMetal(device: defaultDevice, metalKitView: mtkView)

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Called when @State or @Binding vars change in the parent SwiftUI view
        if !nsView.isPaused {
            // Pass current resolution from nsView
            let currentResolution = simd_float2(Float(nsView.drawableSize.width), Float(nsView.drawableSize.height))
            context.coordinator.renderer.updateStaticUniforms(
                noiseConfig: noiseConfig,
                spotlightConfig: spotlightConfig,
                isDarkMode: isDarkMode,
                resolution: currentResolution
            )
        }
        
        // Update isPaused based on the binding
        if nsView.isPaused != isPausedBinding {
            nsView.isPaused = isPausedBinding
            print("MetalBloomView: Setting isPaused to \(isPausedBinding)")
        }
        // No need to call setNeedsDisplay if enableSetNeedsDisplay is false
    }

    // MARK: - Coordinator Class
    public class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalBloomView
        var renderer: Renderer

        init(_ parent: MetalBloomView, isDarkMode: Bool) {
            self.parent = parent
            self.renderer = Renderer(parent, isDarkMode: isDarkMode)
            super.init()
            print("Coordinator initialized for MetalBloomView")
        }

        deinit {
            print("MetalBloomView.Coordinator deallocated.")
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer.mtkView(view, drawableSizeWillChange: size)
        }

        public func draw(in view: MTKView) {
            renderer.draw(in: view)
        }
    }

    // MARK: - Renderer Class
    class Renderer {
        var parent: MetalBloomView
        var device: MTLDevice!
        var commandQueue: MTLCommandQueue!
        var noisePipelineState: MTLRenderPipelineState!
        var spotlightPipelineState: MTLRenderPipelineState!
        var noiseTexture: MTLTexture! // Intermediate texture for noise output

        // Uniform buffers
        var noiseUniformsBuffer: MTLBuffer!
        var spotlightUniformsBuffer: MTLBuffer!

        // Vertex buffer (simple quad)
        var vertexBuffer: MTLBuffer!
        // x, y, u, v (texture coordinates)
        let vertexData: [Float] = [
            -1.0, -1.0, 0.0, 1.0, // Bottom Left
             1.0, -1.0, 1.0, 1.0, // Bottom Right
            -1.0,  1.0, 0.0, 0.0, // Top Left
             1.0,  1.0, 1.0, 0.0  // Top Right
        ]

        let isDarkModeInitially: Bool // <<< Declaration added here

        private var startDate: Date? // For internal time management

        init(_ parent: MetalBloomView, isDarkMode: Bool) {
            print("Renderer Init, DarkMode: \(isDarkMode)")
            self.parent = parent
            self.isDarkModeInitially = isDarkMode // Store initial dark mode state
            // Metal setup that doesn't require MTKView can go here or be deferred to loadMetal
        }

        deinit {
            print("Renderer deallocated")
            // Explicitly nil out Metal objects to help ARC and ensure resources are released
            noisePipelineState = nil
            spotlightPipelineState = nil
            noiseTexture = nil
            noiseUniformsBuffer = nil
            spotlightUniformsBuffer = nil
            vertexBuffer = nil
            commandQueue = nil
            device = nil
            print("Renderer Metal objects nilled out")
        }

        func loadMetal(device: MTLDevice, metalKitView: MTKView) {
            print("Loading Metal Resources")
            self.device = device
            self.commandQueue = device.makeCommandQueue()!

            // Load Shaders from default library (ensure .metal files are in target)
            guard let library = device.makeDefaultLibrary() else {
                 fatalError("Could not load default Metal library. Ensure shaders are compiled and linked.")
            }
            
            // ** IMPORTANT: Ensure this vertex shader exists in one of your .metal files! **
            /* 
            // ----- Add to Noise.metal or Spotlight.metal or Common.metal ----- 
            #include <metal_stdlib>
            using namespace metal;

            struct VertexData {
                float4 position [[position]];
                float2 texCoord;
            };

            // Simple vertex shader passing through position and tex coords
            vertex VertexData vertex_passthrough(uint vertexID [[vertex_id]],
                                                 constant packed_float4* vertex_array [[buffer(0)]])
            {
                VertexData out;
                // vertex_array contains xyuv components packed into float4
                float4 data = vertex_array[vertexID];
                out.position = float4(data.xy, 0.0, 1.0); // xy = position
                out.texCoord = data.zw;                 // zw = texCoord
                return out;
            }
            // ----- End of vertex shader code ----- 
            */
            guard let passthroughVertexFunction = library.makeFunction(name: "vertex_passthrough"),
                  let noiseFragmentFunction = library.makeFunction(name: "noise_fragment"),
                  let spotlightFragmentFunction = library.makeFunction(name: "spotlight_fragment") else {
                fatalError("Could not find shader functions (vertex_passthrough, noise_fragment, spotlight_fragment). Check names and compilation.")
            }
            print("Shader functions loaded successfully.")

             // Create vertex buffer
             let dataSize = vertexData.count * MemoryLayout<Float>.stride
             // Use storageModeShared so CPU and GPU can access (though we only write once)
             vertexBuffer = device.makeBuffer(bytes: vertexData, length: dataSize, options: [.storageModeShared])

            // Create Noise Pipeline State
            let noisePipelineDescriptor = MTLRenderPipelineDescriptor()
            noisePipelineDescriptor.vertexFunction = passthroughVertexFunction
            noisePipelineDescriptor.fragmentFunction = noiseFragmentFunction
            noisePipelineDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm // Render noise to intermediate texture (non-sRGB OK for data)
            noisePipelineDescriptor.colorAttachments[0].isBlendingEnabled = false // Noise pass overwrites texture

            do {
                noisePipelineState = try device.makeRenderPipelineState(descriptor: noisePipelineDescriptor)
                 print("Noise pipeline state created.")
            } catch {
                fatalError("Failed to create noise pipeline state: \(error)")
            }

            // Create Spotlight Pipeline State
            let spotlightPipelineDescriptor = MTLRenderPipelineDescriptor()
            spotlightPipelineDescriptor.vertexFunction = passthroughVertexFunction // Reuse vertex shader
            spotlightPipelineDescriptor.fragmentFunction = spotlightFragmentFunction
            spotlightPipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat // Render to view's drawable (sRGB)

            // *** Setup Blending for Transparency ***
            // Restore blending
            spotlightPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true // WAS false for debug
            
            spotlightPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            spotlightPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            spotlightPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            spotlightPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            spotlightPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one // Result alpha = SrcAlpha
            spotlightPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            

            do {
                spotlightPipelineState = try device.makeRenderPipelineState(descriptor: spotlightPipelineDescriptor)
                print("Spotlight pipeline state created.")
            } catch {
                fatalError("Failed to create spotlight pipeline state: \(error)")
            }

            // Allocate uniform buffers (size needs to match shader struct)
             // Use storageModeShared for CPU updates
             noiseUniformsBuffer = device.makeBuffer(length: MemoryLayout<NoiseUniforms>.stride, options: .storageModeShared)
             spotlightUniformsBuffer = device.makeBuffer(length: MemoryLayout<SpotlightUniforms>.stride, options: .storageModeShared)
             print("Uniform buffers allocated.")

            // Perform an initial update to ensure buffers have valid data (without time)
            let initialResolution = simd_float2(Float(metalKitView.drawableSize.width), Float(metalKitView.drawableSize.height))
            updateStaticUniforms(noiseConfig: parent.noiseConfig, spotlightConfig: parent.spotlightConfig, isDarkMode: parent.isDarkMode, resolution: initialResolution)
            
            // Initialize start date for time-based animation
            self.startDate = Date()
        }

        // Called from updateNSView when SwiftUI state changes (for non-time critical updates)
        func updateStaticUniforms(noiseConfig: NoiseUniforms, spotlightConfig: SpotlightUniforms, isDarkMode: Bool, resolution: simd_float2) {
            print("Renderer.updateStaticUniforms called") // Renamed and time removed
            // Update Noise Uniforms buffer
             var currentNoiseUniforms = noiseConfig // Start with base config from parent
             currentNoiseUniforms.resolution = resolution // Set current resolution
             // Assuming noiseUniformsBuffer is non-nil after loadMetal
             let noisePtr = noiseUniformsBuffer.contents().bindMemory(to: NoiseUniforms.self, capacity: 1)
             noisePtr.pointee = currentNoiseUniforms // Copy data to buffer

             // Update Spotlight Uniforms buffer
             var currentSpotlightUniforms = spotlightConfig // Start with base config
             currentSpotlightUniforms.isDarkMode = isDarkMode ? 1 : 0
             currentSpotlightUniforms.resolution = resolution // Set current resolution
             // Assuming spotlightUniformsBuffer is non-nil after loadMetal
             let spotlightPtr = spotlightUniformsBuffer.contents().bindMemory(to: SpotlightUniforms.self, capacity: 1)
             spotlightPtr.pointee = currentSpotlightUniforms // Copy data to buffer
        }

        // Creates or resizes the intermediate texture used for the noise pass output
        func ensureNoiseTexture(size: CGSize) {
             guard size.width > 0 && size.height > 0 else {
                  print("Skipping texture creation for zero size.")
                  return
             }
             let width = Int(size.width)
             let height = Int(size.height)

             // Check if texture exists and has the correct dimensions
             if noiseTexture == nil || noiseTexture.width != width || noiseTexture.height != height {
                  let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                       pixelFormat: .rgba8Unorm, // Match noise pipeline output format
                       width: width,
                       height: height,
                       mipmapped: false)
                  // Usage: Render target for noise pass, sampled in spotlight pass
                  descriptor.usage = [.shaderRead, .renderTarget]
                  descriptor.storageMode = .private // GPU optimal

                  guard let newTexture = device.makeTexture(descriptor: descriptor) else {
                       print("Error: Could not create noise texture") // Use non-fatal error logging ideally
                       noiseTexture = nil // Ensure it's nil if creation fails
                       return
                  }
                  noiseTexture = newTexture
                  noiseTexture.label = "Noise Intermediate Texture"
                  print("Created/Resized noise texture to: \(width)x\(height)")
             }
        }

        // MARK: - MTKViewDelegate Methods

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            print("MTKView size changing to: \(size)")
            // Ensure the intermediate texture is resized accordingly
            ensureNoiseTexture(size: size)

             // Update the resolution uniform in both buffers immediately
             let currentSizeVec = simd_float2(Float(size.width), Float(size.height))
             // Assuming buffers are non-nil after loadMetal
             let noisePtr = noiseUniformsBuffer.contents().bindMemory(to: NoiseUniforms.self, capacity: 1)
             noisePtr.pointee.resolution = currentSizeVec
             let spotlightPtr = spotlightUniformsBuffer.contents().bindMemory(to: SpotlightUniforms.self, capacity: 1)
             spotlightPtr.pointee.resolution = currentSizeVec
        }

        public func draw(in view: MTKView) {
            // ---- START DEBUG PRINT ----
            print("MetalBloomView.Renderer.draw(in:) CALLED - Frame Start")
            // ----  END DEBUG PRINT  ----

            guard let startDate = self.startDate else {
                print("MetalBloomView.Renderer.draw(in:) - startDate not set, skipping frame.")
                return
            }
            let currentTime = Float(Date().timeIntervalSince(startDate))
            // print("MetalBloomView.Renderer.draw(in:) called, time: \(currentTime)") // Updated debug log

            // Ensure drawing on the main thread if Metal objects are accessed/modified,
            // or ensure all Metal setup and drawing is thread-safe.
            // MTKView's delegate methods are typically called on the main thread.
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let noiseTexture = self.noiseTexture, // Ensure intermediate texture is valid
                  let noiseUniformsBuffer = self.noiseUniformsBuffer, // Ensure buffers are valid
                  let spotlightUniformsBuffer = self.spotlightUniformsBuffer,
                  let vertexBuffer = self.vertexBuffer else {
                 print("MetalBloomView.Renderer.draw(in:) - Draw skipped - missing critical resources (drawable, commandBuffer, textures, or buffers)") // UNCOMMENTED
                 return // Don't draw if resources aren't ready
            }

            let size = view.drawableSize
             guard size.width > 0 && size.height > 0 else { return } // Don't draw if size is invalid

             // --- Update Time Uniforms Directly ---
             // Assuming buffers are non-nil after loadMetal
             let noiseTimePtr = noiseUniformsBuffer.contents().bindMemory(to: NoiseUniforms.self, capacity: 1)
             noiseTimePtr.pointee.time = currentTime

             let spotlightTimePtr = spotlightUniformsBuffer.contents().bindMemory(to: SpotlightUniforms.self, capacity: 1)
             spotlightTimePtr.pointee.time = currentTime
             // --- End Update Time Uniforms ---

             // Ensure resolution uniforms are correct for this frame's size
             let currentSizeVec = simd_float2(Float(size.width), Float(size.height))
             // Assuming buffers are non-nil after loadMetal
             let noiseResPtr = noiseUniformsBuffer.contents().bindMemory(to: NoiseUniforms.self, capacity: 1)
             if noiseResPtr.pointee.resolution != currentSizeVec {
                 noiseResPtr.pointee.resolution = currentSizeVec
             }

             let spotlightResPtr = spotlightUniformsBuffer.contents().bindMemory(to: SpotlightUniforms.self, capacity: 1)
             if spotlightResPtr.pointee.resolution != currentSizeVec {
                 spotlightResPtr.pointee.resolution = currentSizeVec
             }
              
             // --- Pass 1: Render Noise to Texture ---
             let noisePassDescriptor = MTLRenderPassDescriptor()
             noisePassDescriptor.colorAttachments[0].texture = noiseTexture
             noisePassDescriptor.colorAttachments[0].loadAction = .clear // Start fresh each frame
             noisePassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
             noisePassDescriptor.colorAttachments[0].storeAction = .store // Keep result for next pass

             guard let noiseEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: noisePassDescriptor) else { return }
             noiseEncoder.label = "Noise Render Encoder"
             noiseEncoder.setRenderPipelineState(noisePipelineState)
             noiseEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0) // Vertex buffer at index 0
             // We need to pass vertex data structure to the passthrough shader
             // The shader expects `constant packed_float4* vertex_array [[buffer(0)]]`
             // Let's re-evaluate the vertex buffer setup and shader input.
             // For now, assuming vertex data is correctly structured for the vertex shader.
             // Pass uniforms to fragment shader
             noiseEncoder.setFragmentBuffer(noiseUniformsBuffer, offset: 0, index: 0) // Noise uniforms at index 0
             noiseEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
             noiseEncoder.endEncoding()

             // --- Pass 2: Render Spotlight (using Noise Texture) to Drawable ---
             // Get the descriptor for the final render pass targeting the view's drawable
             guard let spotlightPassDescriptor = view.currentRenderPassDescriptor else { return }
             // Descriptor already configures texture = drawable.texture
             // We set load/store actions for our needs
             spotlightPassDescriptor.colorAttachments[0].loadAction = .clear // Clear with MTKView's clear color (transparent)
             spotlightPassDescriptor.colorAttachments[0].storeAction = .store // Display the result

             guard let spotlightEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: spotlightPassDescriptor) else { return }
             spotlightEncoder.label = "Spotlight Render Encoder"
             spotlightEncoder.setRenderPipelineState(spotlightPipelineState)
             spotlightEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0) // Reuse vertex buffer
             spotlightEncoder.setFragmentBuffer(spotlightUniformsBuffer, offset: 0, index: 0) // Spotlight uniforms at index 0
             spotlightEncoder.setFragmentTexture(noiseTexture, index: 0) // Pass noise texture at index 0
             spotlightEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
             spotlightEncoder.endEncoding()

             // --- Finalize ---
             commandBuffer.present(drawable) // Schedule presentation
             commandBuffer.commit() // Submit commands to GPU

            // ---- START DEBUG PRINT ----
            print("MetalBloomView.Renderer.draw(in:) - Frame End, Command Buffer Committed")
            // ----  END DEBUG PRINT  ----
        }
    }
}
