import SwiftUI
import MetalKit // <-- Import MetalKit

struct OverlayView: View {
    @ObservedObject var overlayManager: OverlayManager // Inject the manager
    var backgroundImage: CGImage?
    let detectedTextRects: [CGRect]? // <-- Add this property
    @State private var path = Path()
    @State private var drawingPoints: [CGPoint] = [] // Keep track for potential analysis/smoothing
    @State private var selectedTextIndices: Set<Int> = [] // <-- ADDED: To track selected text
    @State private var hoveredTextIndex: Int? = nil // NEW: For hover effect
    @State private var showSearchButton = false // For confirming drag selection
    @Binding var showOverlay: Bool // Use binding to allow dismissal from here
    var completion: (Path?, Set<Int>?) -> Void // Path is nil if cancelled, added Set<Int> for selected text indices

    // Environment to detect Dark Mode
    @Environment(\.colorScheme) var colorScheme

    // State for animation timing
    @State private var startDate = Date()

    // --- Shader Configurations (Constants for now) ---
    let noiseUniforms = NoiseUniforms(
        noiseScale: 12.0,
        pulseFrequency: 7.0,
        pulseAmplitude: 0.05,
        scrollSpeed: 900.0
    )
    
    // Calculate topInset for the status bar area - using NSScreen for macOS
    var statusBarInset: Float {
        // Get main screen height
        let screenHeight = NSScreen.main?.frame.height ?? 1000
        
        // Get status bar height - typically around 24-25 points on macOS
        let statusBarHeight: Float = 25.0
        
        // Return as a proportion (0.0-1.0) of screen height
        return Float(statusBarHeight / Float(screenHeight))
    }
    
    var spotlightUniforms: SpotlightUniforms {
        var uniforms = SpotlightUniforms(
            spotlightHeight: 450.0,
            spotlightSpeed: 1000.0,
            // lightModeTint & darkModeTint use defaults defined in MetalBloomView struct
            spotlightBrightness: 1.4  // Increased from 1.15 to 1.4 for more pronounced edge glow
        )
        uniforms.topInset = statusBarInset
        return uniforms
    }
    // --- End Shader Configurations ---

    // Gesture state
    @State private var isDragging = false // Tracks active drawing gesture

    // --- State for ESC key monitor --- 
    @State private var escapeEventMonitor: Any?
    // ---------------------------------

    @FocusState private var isViewFocused: Bool // <-- Add FocusState

    // Add new state variables for animation
    @State private var glowOpacity: Double = 0.0
    @State private var glowScale: CGFloat = 1.0
    @State private var lastDrawingPoint: CGPoint?
    @State private var drawingAnimation: Animation?

    // Add new state variables for selection handles
    @State private var selectionStartHandle: CGPoint?
    @State private var selectionEndHandle: CGPoint?
    @State private var isDraggingHandle: Bool = false
    @State private var draggedHandle: SelectionHandle = .none
    @State private var selectedTextRange: TextSelectionRange?
    
    // ADDED: Struct for text selection range to conform to Equatable
    struct TextSelectionRange: Equatable {
        var start: Int
        var end: Int
    }
    
    enum SelectionHandle {
        case start
        case end
        case none
    }

    var body: some View {
        // Use TimelineView to drive the animation at ~60fps
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !overlayManager.isWindowActuallyVisible)) { timeline in
            // Calculate elapsed time for shaders
//            let time = Float(timeline.date.timeIntervalSince(startDate))

            ZStack {
                // --- Metal Bloom Effect (Layer 1: Background) ---
                // MOVED TO TOP FOR DEBUGGING
                /*
                GeometryReader { geometry in
                    MetalBloomView(
                        isActuallyVisible: overlayManager.isWindowActuallyVisible,
                        // time: .constant(time), // Pass the calculated time
                        isDarkMode: colorScheme == .dark,
                        noiseConfig: noiseUniforms,
                        spotlightConfig: spotlightUniforms,
                        isPausedBinding: $overlayManager.shouldPauseMetalRendering // <-- ADDED THIS
                    )
                    .edgesIgnoringSafeArea(.all) // Ensure it fills the view
                    .allowsHitTesting(false) // Don't block gestures for layers above
                }
                */

                // Detect Escape key press anywhere in the overlay
                Color.clear // Occupy space to attach shortcut
                    .keyboardShortcut(.escape, modifiers: [])
                    .onTapGesture { /* Optional: Define action if needed */ }
                    .allowsHitTesting(false) // Don't interfere with drawing

                // --- Background Image (Layer 2) ---
                if let bgImage = backgroundImage {
                    Image(decorative: bgImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill) // Or .fit depending on desired look
                        .edgesIgnoringSafeArea(.all)
                        .allowsHitTesting(false) // Don't block gestures
                } else {
                    // Fallback if image loading fails, still allows bloom to show
                    Color.black.opacity(0.01)
                        .edgesIgnoringSafeArea(.all)
                        .allowsHitTesting(false)
                }

                // --- Drawing Canvas & Overlay (Layer 3) ---
                GeometryReader { canvasGeometryProxy in // NEW: GeometryReader for Canvas
                    Canvas { context, size in // Updated: Canvas now uses canvasGeometryProxy internally
                        // Log received data and canvas size
                        // print("OverlayView Canvas: Received detectedTextRects count: \(detectedTextRects?.count ?? 0)")
                        // print("OverlayView Canvas: Canvas size: \(canvasGeometryProxy.size)")

                        // --- Draw Detected Text Rectangles (for debugging) ---
                        if let rects = detectedTextRects {
                            // print("OverlayView Canvas: Drawing \(rects.count) detected text rectangles.")
                            for (index, normalizedRect) in rects.enumerated() {
                                // Convert normalized rect to screen coordinates
                                let screenRect = CGRect(
                                    x: normalizedRect.origin.x * canvasGeometryProxy.size.width,
                                    y: (1 - normalizedRect.origin.y - normalizedRect.height) * canvasGeometryProxy.size.height, // Adjust Y for SwiftUI coords
                                    width: normalizedRect.width * canvasGeometryProxy.size.width,
                                    height: normalizedRect.height * canvasGeometryProxy.size.height
                                )
                                // print("  OverlayView Canvas: Drawing rect \(index) at screenRect: \(screenRect) from normalizedRect: \(normalizedRect)")
                                
                                // Create a path for the rectangle and fill it
                                var rectPath = Path()
                                rectPath.addRect(screenRect)
                                // context.fill(rectPath, with: .color(.yellow.opacity(0.3))) // REMOVED: Yellow debug highlight

                                // Draw blue highlight if this text is selected
                                if selectedTextIndices.contains(index) {
                                    context.fill(rectPath, with: .color(.blue.opacity(0.4))) // NEW: Blue selection highlight
                                    // Add a subtle glow effect for selected text
                                    context.addFilter(.shadow(color: .blue.opacity(0.3), radius: 2))
                                    context.stroke(rectPath, with: .color(.blue.opacity(0.6)), lineWidth: 1)
                                }
                            }
                        }
                        // --- End Debug Drawing ---
                        
                        if !path.isEmpty {
                            // Calculate time for animation from the TimelineView's date
                            let currentTime = timeline.date.timeIntervalSince(startDate)

                            // Pulsing effect parameters - ADJUSTED FOR MORE NOTICEABLE EFFECT
                            let pulseFrequency: Double = 1.8 // Slightly faster frequency
                            let minOpacity: Double = 0.2   // Lower minimum opacity
                            let maxOpacity: Double = 0.9   // Higher maximum opacity
                            
                            // Calculate current opacity based on a sine wave
                            let pulse = (sin(currentTime * 2 * .pi * pulseFrequency) + 1) / 2 // Normalizes sine to 0-1 range
                            let animatedGlowOpacity = minOpacity + (maxOpacity - minOpacity) * pulse

                            // Draw the magical glow effect with animated opacity
                            let glowPath = path.strokedPath(StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                            context.addFilter(.blur(radius: 3)) // Keep blur constant or animate it too
                            context.stroke(glowPath, with: .color(.cyan.opacity(animatedGlowOpacity)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                            
                            // Draw the main stroke with gradient
                            let gradient = Gradient(colors: [
                                .cyan.opacity(0.8),
                                .blue.opacity(0.6),
                                .purple.opacity(0.4)
                            ])
                            context.stroke(path, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)), 
                                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            
                            // Draw the glowing tip at the end of the path
                            if let lastPoint = lastDrawingPoint {
                                let tipSize: CGFloat = 12.0
                                let animatedTipOpacity = 0.6 + 0.4 * pulse // Link tip opacity to pulse
                                let tipPath = Path(ellipseIn: CGRect(x: lastPoint.x - tipSize/2, 
                                                                    y: lastPoint.y - tipSize/2, 
                                                                    width: tipSize, 
                                                                    height: tipSize))
                                context.addFilter(.blur(radius: 2))
                                context.fill(tipPath, with: .color(.cyan.opacity(animatedTipOpacity)))
                            }
                        }

                        // Draw selected text with native-like selection
                        if let rects = detectedTextRects, let range = selectedTextRange {
                            // Draw selection background
                            for index in range.start...range.end {
                                if index < rects.count {
                                    let normalizedRect = rects[index]
                                    let screenRect = CGRect(
                                        x: normalizedRect.origin.x * canvasGeometryProxy.size.width,
                                        y: (1 - normalizedRect.origin.y - normalizedRect.height) * canvasGeometryProxy.size.height,
                                        width: normalizedRect.width * canvasGeometryProxy.size.width,
                                        height: normalizedRect.height * canvasGeometryProxy.size.height
                                    )
                                    
                                    // Draw selection background
                                    let selectionPath = Path(roundedRect: screenRect, cornerRadius: 2)
                                    context.fill(selectionPath, with: .color(.blue.opacity(0.3)))
                                    
                                    // Draw selection handles if this is the start or end text
                                    if index == range.start {
                                        drawSelectionHandle(at: CGPoint(x: screenRect.minX, y: screenRect.midY), context: context)
                                    }
                                    if index == range.end {
                                        drawSelectionHandle(at: CGPoint(x: screenRect.maxX, y: screenRect.midY), context: context)
                                    }
                                }
                            }
                        }
                    }
                    .gesture(dragGesture(canvasSize: canvasGeometryProxy.size))
                    .gesture(handleDragGesture(canvasSize: canvasGeometryProxy.size))
                    .onContinuousHover { phase in // NEW: Handle hover
                        switch phase {
                        case .active(let location):
                            updateHoveredTextIndex(at: location, in: canvasGeometryProxy.size) // UPDATED to use canvasGeometryProxy
                        case .ended:
                            hoveredTextIndex = nil
                        }
                    }
                    .gesture( // NEW: Handle tap for single text box selection
                        TapGesture()
                            .onEnded { _ in
                                if let tappedIndex = hoveredTextIndex {
                                    print("Tapped on text box index: \(tappedIndex)")
                                    selectedTextIndices = [tappedIndex] // Select only this one
                                    confirmSelection() // And immediately search
                                }
                            }
                    )
                    // ADDED: .onAppear and .onChange to manage handle state updates
                    .onAppear {
                        updateAndStoreHandlePositions(currentSelectionRange: selectedTextRange, canvasSize: canvasGeometryProxy.size)
                    }
                    .onChange(of: selectedTextRange) { _, newRange in
                        updateAndStoreHandlePositions(currentSelectionRange: newRange, canvasSize: canvasGeometryProxy.size)
                    }
                    .edgesIgnoringSafeArea(.all)
                } // END: GeometryReader for Canvas

                // --- UI Elements (Layer 4 - Optional) ---
                // Remove the VStack with the Search Selection button entirely

                // --- Metal Bloom Effect (MOVED TO TOP FOR DEBUGGING) ---
                GeometryReader { geometry in
                    MetalBloomView(
                        isActuallyVisible: overlayManager.isWindowActuallyVisible,
                        isDarkMode: colorScheme == .dark,
                        noiseConfig: noiseUniforms,
                        spotlightConfig: spotlightUniforms,
                        isPausedBinding: $overlayManager.shouldPauseMetalRendering
                    )
                    .edgesIgnoringSafeArea(.all)
                    .allowsHitTesting(false)
                }

            }
            // Apply ESC key listener to the ZStack or TimelineView
            .onAppear {
                print("OverlayView: .onAppear called. Setting up monitors.")
                // Initial setup when view appears
                setupEscapeKeyMonitor()
                isViewFocused = true // <-- Attempt to claim focus
            }
            .onDisappear {
                removeEscapeKeyMonitor()
            }
            .onChange(of: showOverlay) { oldValue, newValue in
                // We only care when the overlay is *shown* (newValue is true)
                if newValue == true {
                    // Reset state when shown
                    print("OverlayView state reset on show.")
                    path = Path()
                    drawingPoints = []
                    selectedTextIndices = [] // <-- ADDED: Clear previous selections
                    isDragging = false
                    startDate = Date() // Reset animation timer
                }
            }

        } // End TimelineView
        .focusable(true) // <-- Make the ZStack focusable
        .edgesIgnoringSafeArea(.all) // Ensure TimelineView fills screen
        .background(TransparentWindowView()) // Necessary for click-through if window is shaped
    }

    // Separate function for ESC key monitoring setup
    func setupEscapeKeyMonitor() {
        // Use a local monitor to avoid capturing all system key events
        // Check if a monitor already exists to avoid adding multiple
        if escapeEventMonitor == nil {
            escapeEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event -> NSEvent? in
                if event.keyCode == 53 { // 53 is the keycode for ESC
                    print("ESC key pressed - Cancelling Overlay")
                    cancelSelection()
                    return nil // Consume the event to prevent beeps/etc.
                }
                return event // Return other events unmodified
            }
            print("OverlayView: Escape key monitor ADDED.")
        }
    }

    // --- Function to remove the ESC key monitor --- 
    func removeEscapeKeyMonitor() {
        if let monitor = escapeEventMonitor {
            NSEvent.removeMonitor(monitor)
            escapeEventMonitor = nil
            print("OverlayView: Escape key monitor REMOVED.")
        }
    }
    // --------------------------------------------

    // MODIFIED: Changed from var to func to accept canvasSize
    func dragGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if !isDragging && !isDraggingHandle {
                    path = Path()
                    drawingPoints = []
                    selectedTextIndices = []
                    selectedTextRange = nil
                    selectionStartHandle = nil
                    selectionEndHandle = nil
                    path.move(to: value.startLocation)
                    drawingPoints.append(value.startLocation)
                    isDragging = true
                    
                    withAnimation(.easeInOut(duration: 0.3)) {
                        glowOpacity = 1.0
                        glowScale = 1.2
                    }
                }
                
                if isDragging {
                    path.addLine(to: value.location)
                    drawingPoints.append(value.location)
                    lastDrawingPoint = value.location
                    
                    // Update text selection
                    updateTextSelection(at: value.location, canvasSize: canvasSize)
                }
            }
            .onEnded { value in
                if path.boundingRect.width < 10 && path.boundingRect.height < 10 {
                    cancelSelection()
                } else {
                    // Finalize selection
                    if let range = selectedTextRange {
                        selectedTextIndices = Set(range.start...range.end)
                        confirmSelection() // <-- This triggers the search and hides the brush
                    }
                }
            }
    }

    // Helper function to update selected text indices with improved intersection logic
    func updateSelectedTextIndices(drawnPath: Path, canvasSize: CGSize) {
        guard let rects = detectedTextRects else { return }
        
        // Create a buffer zone around the drawn path for better selection
        let bufferWidth: CGFloat = 5.0
        let bufferedPath = drawnPath.strokedPath(StrokeStyle(lineWidth: bufferWidth, lineCap: .round, lineJoin: .round))
        
        // Convert SwiftUI Path to CGPath for intersection testing
        let cgPath = bufferedPath.cgPath
        
        // Create a new set for this update
        var newSelectedIndices = Set<Int>()
        
        for (index, normalizedRect) in rects.enumerated() {
            // Convert normalized rect to screen coordinates
            let textScreenRect = CGRect(
                x: normalizedRect.origin.x * canvasSize.width,
                y: (1 - normalizedRect.origin.y - normalizedRect.height) * canvasSize.height,
                width: normalizedRect.width * canvasSize.width,
                height: normalizedRect.height * canvasSize.height
            )
            
            // Check if the paths intersect using CGPath's contains method
            if cgPath.contains(textScreenRect.origin) || 
               cgPath.contains(CGPoint(x: textScreenRect.maxX, y: textScreenRect.maxY)) ||
               cgPath.contains(CGPoint(x: textScreenRect.minX, y: textScreenRect.maxY)) ||
               cgPath.contains(CGPoint(x: textScreenRect.maxX, y: textScreenRect.minY)) {
                newSelectedIndices.insert(index)
            }
        }
        
        // Update the selected indices
        selectedTextIndices = newSelectedIndices
    }

    // Called when the user confirms the selection (e.g., clicks the button)
    func confirmSelection() {
        isDragging = false // Hide brush
        path = Path() // Clear the brush
        completion(path, selectedTextIndices) // Pass the completed path and selected text indices back
        showOverlay = false // Dismiss the overlay
    }

    // Enhanced cancel function to also hide highlights/panel
    // Called when the user cancels (e.g., presses ESC or makes tiny drag)
    func cancelSelection() {
        print("Selection Cancelled")
        isDragging = false
        path = Path() // Clear the path visually
        drawingPoints = []
        selectedTextIndices = [] // <-- ADDED: Clear previous selections

        // Hide UI elements managed by other controllers
        HighlighterLayer.hide()
        // Use MainActor because ResultPanel manipulates UI
        Task { @MainActor in 
            ResultPanel.shared.hide()
        }
        
        completion(nil, nil) // Indicate cancellation
        showOverlay = false // Dismiss the overlay
    }

    private func updateHoveredTextIndex(at location: CGPoint, in size: CGSize) {
        if let rects = detectedTextRects {
            for (index, rect) in rects.enumerated() {
                let denormalizedRect = CGRect(
                    x: rect.origin.x * size.width,
                    y: (1 - rect.origin.y - rect.height) * size.height, // Adjust for bottom-left origin
                    width: rect.width * size.width,
                    height: rect.height * size.height
                )
                if denormalizedRect.contains(location) {
                    hoveredTextIndex = index
                    return
                }
            }
            hoveredTextIndex = nil
        }
    }

    // Function to draw selection handles
    private func drawSelectionHandle(at point: CGPoint, context: GraphicsContext) {
        let handleSize: CGFloat = 12
        let handlePath = Path(ellipseIn: CGRect(x: point.x - handleSize/2,
                                              y: point.y - handleSize/2,
                                              width: handleSize,
                                              height: handleSize))
        context.fill(handlePath, with: .color(.blue))
        context.stroke(handlePath, with: .color(.white), lineWidth: 1)
    }
    
    // Add helper function for CGPoint distance calculation
    private func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }
    
    // Handle drag gesture for selection handles
    // MODIFIED: Changed from var to func to accept canvasSize
    private func handleDragGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDraggingHandle {
                    // Determine which handle is being dragged
                    if let startHandle = selectionStartHandle,
                       distance(value.startLocation, startHandle) < 20 {
                        draggedHandle = .start
                        isDraggingHandle = true
                    } else if let endHandle = selectionEndHandle,
                              distance(value.startLocation, endHandle) < 20 {
                        draggedHandle = .end
                        isDraggingHandle = true
                    }
                }
                
                if isDraggingHandle {
                    // Update selection based on handle drag
                    updateSelectionForHandleDrag(at: value.location, canvasSize: canvasSize)
                }
            }
            .onEnded { _ in
                isDraggingHandle = false
                draggedHandle = .none
            }
    }
    
    // Update selection based on handle drag
    private func updateSelectionForHandleDrag(at location: CGPoint, canvasSize: CGSize) {
        guard let rects = detectedTextRects else { return }
        
        // Find the text box closest to the drag location
        var closestIndex = -1
        var minDistance = CGFloat.infinity
        
        for (index, normalizedRect) in rects.enumerated() {
            let screenRect = CGRect(
                x: normalizedRect.origin.x * canvasSize.width,
                y: (1 - normalizedRect.origin.y - normalizedRect.height) * canvasSize.height,
                width: normalizedRect.width * canvasSize.width,
                height: normalizedRect.height * canvasSize.height
            )
            
            let rectCenter = CGPoint(x: screenRect.midX, y: screenRect.midY)
            let currentDistance = distance(location, rectCenter)
            if currentDistance < minDistance {
                minDistance = currentDistance
                closestIndex = index
            }
        }
        
        if closestIndex >= 0 {
            if draggedHandle == .start {
                selectedTextRange = TextSelectionRange(start: closestIndex, end: selectedTextRange?.end ?? closestIndex)
            } else if draggedHandle == .end {
                selectedTextRange = TextSelectionRange(start: selectedTextRange?.start ?? closestIndex, end: closestIndex)
            }
            
            // Update selected indices for highlighting
            if let range = selectedTextRange {
                selectedTextIndices = Set(range.start...range.end)
            }
        }
    }
    
    // Update text selection based on current drawing position
    private func updateTextSelection(at location: CGPoint, canvasSize: CGSize) {
        guard let rects = detectedTextRects else { return }
        
        // Find the text box under the current position
        for (index, normalizedRect) in rects.enumerated() {
            let screenRect = CGRect(
                x: normalizedRect.origin.x * canvasSize.width,
                y: (1 - normalizedRect.origin.y - normalizedRect.height) * canvasSize.height,
                width: normalizedRect.width * canvasSize.width,
                height: normalizedRect.height * canvasSize.height
            )
            
            if screenRect.contains(location) {
                if selectedTextRange == nil {
                    selectedTextRange = TextSelectionRange(start: index, end: index)
                } else {
                    selectedTextRange = TextSelectionRange(start: selectedTextRange!.start, end: index)
                }
                if let range = selectedTextRange {
                    selectedTextIndices = Set(range.start...range.end)
                }
                break
            }
        }
    }

    // ADDED: New method to update handle positions
    private func updateAndStoreHandlePositions(currentSelectionRange: TextSelectionRange?, canvasSize: CGSize) {
        guard canvasSize != .zero, let rects = self.detectedTextRects, !rects.isEmpty else {
            if self.selectionStartHandle != nil { self.selectionStartHandle = nil }
            if self.selectionEndHandle != nil { self.selectionEndHandle = nil }
            return
        }

        guard let range = currentSelectionRange else {
            if self.selectionStartHandle != nil { self.selectionStartHandle = nil }
            if self.selectionEndHandle != nil { self.selectionEndHandle = nil }
            return
        }

        var newStartHandle: CGPoint? = nil
        if range.start >= 0 && range.start < rects.count {
            let normalizedStartRect = rects[range.start]
            let startScreenRect = CGRect(
                x: normalizedStartRect.origin.x * canvasSize.width,
                y: (1 - normalizedStartRect.origin.y - normalizedStartRect.height) * canvasSize.height,
                width: normalizedStartRect.width * canvasSize.width,
                height: normalizedStartRect.height * canvasSize.height
            )
            newStartHandle = CGPoint(x: startScreenRect.minX, y: startScreenRect.midY)
        }

        var newEndHandle: CGPoint? = nil
        if range.end >= 0 && range.end < rects.count {
            let normalizedEndRect = rects[range.end]
            let endScreenRect = CGRect(
                x: normalizedEndRect.origin.x * canvasSize.width,
                y: (1 - normalizedEndRect.origin.y - normalizedEndRect.height) * canvasSize.height,
                width: normalizedEndRect.width * canvasSize.width,
                height: normalizedEndRect.height * canvasSize.height
            )
            newEndHandle = CGPoint(x: endScreenRect.maxX, y: endScreenRect.midY)
        }
        
        if self.selectionStartHandle != newStartHandle {
            self.selectionStartHandle = newStartHandle
        }
        if self.selectionEndHandle != newEndHandle {
            self.selectionEndHandle = newEndHandle
        }
    }
}

// Helper for click-through background if needed (optional)
struct TransparentWindowView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Configure view properties if necessary, e.g., layer properties
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Preview Provider - Needs adjustments for Bindings
struct OverlayView_Previews: PreviewProvider {
    // Create a dummy state for the binding
    @State static var previewShowOverlay = true
    // Use the singleton instance for the preview
    static var previewManager = OverlayManager.shared

    static var previews: some View {
        // Provide a dummy image or nil
        let dummyImage: CGImage? = nil // Or create a sample CGImage for preview

        OverlayView(
            overlayManager: previewManager, // <-- Pass the dummy manager
            backgroundImage: dummyImage,
            detectedTextRects: nil, // <-- Add new parameter for preview (can be nil or sample data)
            showOverlay: $previewShowOverlay // Pass the dummy binding
        ) { selectedPath, selectedIndices in
            if let path = selectedPath {
                print("Preview completed with path: \(path.boundingRect), selected indices: \(String(describing: selectedIndices))")
            } else {
                print("Preview cancelled")
            }
            previewShowOverlay = false // Simulate dismissal
        }
    }
}
