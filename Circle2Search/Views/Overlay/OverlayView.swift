import SwiftUI
import MetalKit
import Vision

// MARK: - Ripple Effect Modifier
struct RippleModifier: ViewModifier {
    var size: CGSize
    var elapsedTime: TimeInterval
    var duration: TimeInterval

    func body(content: Content) -> some View {
        let shader = ShaderLibrary.Ripple(
            .float2(size),
            .float(elapsedTime)
        )

        content.visualEffect { view, _ in
            view.layerEffect(
                shader,
                maxSampleOffset: CGSize(width: 20, height: 20),
                isEnabled: elapsedTime < duration
            )
        }
    }
}

struct RippleEffect<T: Equatable>: ViewModifier {
    var size: CGSize
    var trigger: T
    var duration: TimeInterval = 1.2

    func body(content: Content) -> some View {
        content.keyframeAnimator(
            initialValue: 0.0,
            trigger: trigger
        ) { view, elapsedTime in
            view.modifier(RippleModifier(
                size: size,
                elapsedTime: elapsedTime,
                duration: duration
            ))
        } keyframes: { _ in
            MoveKeyframe(0.0)
            LinearKeyframe(duration, duration: duration)
        }
    }
}

struct OverlayView: View {
    
    // MARK: - Environment
    
    @Environment(\.colorScheme) var colorScheme
    
    // MARK: - Dependencies
    
    @ObservedObject var overlayManager: OverlayManager
    var backgroundImage: CGImage?
    @Binding var showOverlay: Bool
    var completion: (Path?, String?, CGRect?) -> Void
    
    // MARK: - Drawing State
    
    @State var path = Path()
    @State var lastDrawingPoint: CGPoint?
    @State var isDragging = false
    
    // MARK: - Selection State
    
    @State var brushedSelectedText: String = ""
    @State var activeSelectionWordRects: [CGRect] = []
    @State var selectedTextIndices: Set<Int> = []
    @State var hoveredTextIndex: Int? = nil
    @State var allSelectableWords: [SelectableWord] = []
    
    // MARK: - Handle Selection State
    
    @State var isHandleSelectionActive: Bool = false
    @State var isDraggingHandle: Bool = false
    @State var draggedHandleType: SelectionHandle = .none
    @State var selectedTextRange: TextSelectionRange?
    @State var startHandleWordGlobalIndex: Int?
    @State var endHandleWordGlobalIndex: Int?
    @State var currentSelectionStartHandleRect: CGRect? 
    @State var currentSelectionEndHandleRect: CGRect?  
    @State var currentHandleSelectionRects: [CGRect] = [] 
    @State var textForCurrentHandleSelection: String = ""
    @State var selectionStartHandle: CGPoint?
    @State var selectionEndHandle: CGPoint?
    
    // MARK: - Animation State
    
    @State private var appearRippleTrigger: Int = 0
    @State private var screenCenter: CGPoint = .zero
    @State private var startDate = Date()
    @State private var glowOpacity: Double = 0.0
    @State private var glowScale: CGFloat = 1.0
    @State private var drawingAnimation: Animation?
    @State var rippleOrigin: CGPoint = .zero
    @State var rippleTrigger: Int = 0
    
    // MARK: - UI State
    
    @State private var showSearchButton = false
    @State var escapeEventMonitor: Any?
    @FocusState private var isViewFocused: Bool
    
    // MARK: - Throttling (Performance)
    
    @State private var lastSelectionUpdateTime: Date = .distantPast
    private let selectionUpdateThrottleInterval: TimeInterval = 0.016
    @State private var lastHoverUpdateTime: Date = .distantPast
    private let hoverUpdateThrottleInterval: TimeInterval = 0.033
    
    // MARK: - Constants
    
    private let androidStrokeWidth: CGFloat = 6.0
    private let androidStrokeColor = Color.white
    
    // MARK: - View Layers
    
    /// Drawing canvas layer with Android Circle to Search style brush
    private var drawingCanvasLayer: some View {
        GeometryReader { canvasGeometryProxy in 
            Canvas { context, size in 
                // Android Circle to Search brush style:
                // - White stroke with subtle outer glow
                // - 6dp stroke width
                // - Round caps and joins
                // - Slight blur for soft edge effect
                if !path.isEmpty {
                    // Priority 7: Lighter glow - double stroke instead of blur filter
                    let glowStyle = StrokeStyle(lineWidth: androidStrokeWidth + 6, lineCap: .round, lineJoin: .round)
                    context.stroke(path, with: .color(.white.opacity(0.2)), style: glowStyle)
                    
                    // Main stroke - solid white like Android
                    let mainStyle = StrokeStyle(lineWidth: androidStrokeWidth, lineCap: .round, lineJoin: .round)
                    context.stroke(path, with: .color(androidStrokeColor), style: mainStyle)
                    
                    // Drawing tip indicator (subtle)
                    if let lastPoint = lastDrawingPoint, isDragging {
                        let tipSize: CGFloat = androidStrokeWidth + 2
                        let tipPath = Path(ellipseIn: CGRect(
                            x: lastPoint.x - tipSize/2, 
                            y: lastPoint.y - tipSize/2, 
                            width: tipSize, 
                            height: tipSize
                        ))
                        context.fill(tipPath, with: .color(.white.opacity(0.9)))
                    }
                }
            }
            .gesture(dragGesture(canvasSize: canvasGeometryProxy.size))
            .gesture(handleDragGesture(canvasSize: canvasGeometryProxy.size))
            .onContinuousHover { phase in 
                switch phase {
                case .active(let location):
                    updateHoveredTextIndex(at: location, in: canvasGeometryProxy.size)
                case .ended:
                    hoveredTextIndex = nil
                }
            }
            .gesture( 
                TapGesture()
                    .onEnded { _ in
                        if let tappedGlobalIndex = hoveredTextIndex, tappedGlobalIndex < allSelectableWords.count {
                            let tappedWord = allSelectableWords[tappedGlobalIndex]
                            self.brushedSelectedText = tappedWord.text
                            self.activeSelectionWordRects = [tappedWord.screenRect] // For confirmSelection
                            log.debug("Tapped on word: \(tappedWord.text)")
                            confirmSelection() // This will set up handle selection for the single tapped word
                        }
                    }
            )
            .onChange(of: overlayManager.detailedTextRegions) { _, newRegions in
                processSelectableWords(canvasProxySize: canvasGeometryProxy.size)
            }
            .onChange(of: canvasGeometryProxy.size) { _, newSize in
                processSelectableWords(canvasProxySize: newSize)
            }
            .onAppear {
                processSelectableWords(canvasProxySize: canvasGeometryProxy.size)
            }
            .edgesIgnoringSafeArea(.all)
        }
    }

    // Android-style vignette: very subtle, just frames the content
    // Android lens_gleam_default_scrim_color: #1a000000 = 10% black max
    private var vignetteOverlay: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let centerX = size.width / 2
                let centerY = size.height / 2
                let maxRadius = sqrt(centerX * centerX + centerY * centerY)
                
                // Very subtle vignette - Android uses only ~10% at edges
                let gradient = Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.6),
                    .init(color: .black.opacity(0.03), location: 0.8),
                    .init(color: .black.opacity(0.08), location: 1.0)
                ])
                
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        gradient,
                        center: CGPoint(x: centerX, y: centerY),
                        startRadius: 0,
                        endRadius: maxRadius
                    )
                )
            }
        }
        .edgesIgnoringSafeArea(.all)
        .allowsHitTesting(false)
    }
    
    // MARK: - Body
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Layer 1: Screenshot background with ripple effect
                if let bgImage = backgroundImage {
                    Image(decorative: bgImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .modifier(RippleEffect(
                            size: geometry.size,
                            trigger: appearRippleTrigger
                        ))
                        .edgesIgnoringSafeArea(.all)
                        .allowsHitTesting(false)
                }
                
                // Layer 2: Android-style vignette (dark edges, clear center)
                vignetteOverlay

                // Layer 3: Drawing canvas for scribble
                drawingCanvasLayer

                // Layer 4: Shimmer effect
                LensientMetalView(
                    isPaused: $overlayManager.shouldPauseMetalRendering
                )
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(false)
            }
            .onAppear {
                screenCenter = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                // Trigger ripple immediately on appear
                appearRippleTrigger += 1
                MainActor.assumeIsolated {
                    LensientEffectsController.shared.showIdle()
                }
            }
        }
        .onAppear {
            setupEscapeKeyMonitor()
            isViewFocused = true 
        }
        .onDisappear {
            removeEscapeKeyMonitor()
            MainActor.assumeIsolated {
                LensientEffectsController.shared.hide()
            }
        }
        .onChange(of: showOverlay) { _, newValue in
            if newValue == true {
                resetAllSelectionStates() 
                startDate = Date()
                MainActor.assumeIsolated {
                    LensientEffectsController.shared.showIdle()
                }
            } else {
                MainActor.assumeIsolated {
                    LensientEffectsController.shared.hide()
                }
            }
        }
        .focusable(false)
        .focusEffectDisabled()
        .edgesIgnoringSafeArea(.all)
        .background(TransparentWindowView())
    }

    // MARK: - Lifecycle
    
    func setupEscapeKeyMonitor() {
        // Check if a monitor already exists to avoid adding multiple
        if escapeEventMonitor == nil {
            escapeEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event -> NSEvent? in
                if event.keyCode == 53 { // 53 is the keycode for ESC
                    log.debug("ESC key pressed - Cancelling Overlay")
                    cancelSelection()
                    return nil // Consume the event to prevent beeps/etc.
                }
                return event // Return other events unmodified
            }
            log.debug("OverlayView: Escape key monitor ADDED.")
        }
    }

    // --- Function to remove the ESC key monitor --- 
    func removeEscapeKeyMonitor() {
        if let monitor = escapeEventMonitor {
            NSEvent.removeMonitor(monitor)
            escapeEventMonitor = nil
            log.debug("OverlayView: Escape key monitor REMOVED.")
        }
    }
    // --------------------------------------------

    // MARK: - Gestures
    
    func dragGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                // If a handle is already being dragged, don't start a new brush stroke
                if self.isDraggingHandle { return }

                // If handles are active, check if this drag started on a handle
                if self.isHandleSelectionActive {
                    let handleTouchRadius: CGFloat = 20 // Same as in handleDragGesture
                    if let startRect = self.currentSelectionStartHandleRect {
                        let handleCenter = CGPoint(x: startRect.minX, y: startRect.midY)
                        if distance(value.startLocation, handleCenter) < handleTouchRadius {
                            // This drag is likely for the start handle, let handleDragGesture take it
                            return 
                        }
                    }
                    if let endRect = self.currentSelectionEndHandleRect {
                        let handleCenter = CGPoint(x: endRect.maxX, y: endRect.midY)
                        if distance(value.startLocation, handleCenter) < handleTouchRadius {
                            // This drag is likely for the end handle, let handleDragGesture take it
                            return
                        }
                    }
                }

                // If not dragging a handle and no handle was targeted by this drag's start:
                if !isDragging { // Start of a new brush stroke
                    resetAllSelectionStates() // This will set isHandleSelectionActive = false
                    isDragging = true
                    path.move(to: value.startLocation)
                    lastDrawingPoint = value.startLocation
                    
                    // Start tracking shimmer at touch point
                    MainActor.assumeIsolated {
                        LensientEffectsController.shared.startTracking(at: value.startLocation)
                    }
                }
                
                // Priority 3: Distance threshold to reduce path complexity
                if let last = lastDrawingPoint, distance(last, value.location) < 2.0 { return }
                
                path.addLine(to: value.location)
                lastDrawingPoint = value.location
                
                // Update shimmer position - Priority 4: Direct call, no Task
                MainActor.assumeIsolated {
                    LensientEffectsController.shared.updateTracking(at: value.location)
                }
                
                updateBrushedTextSelection(drawnPath: self.path, canvasProxySize: canvasSize)
            }
            .onEnded { value in
                if self.isDraggingHandle { 
                    isDragging = false 
                    return
                }
                isDragging = false

                if !brushedSelectedText.isEmpty {
                    log.debug("OverlayView: Drag ended. Brushed text found: '\(brushedSelectedText)'. Confirming text selection.")
                    // Show subtle monochrome shimmer to indicate "still active"
                    MainActor.assumeIsolated {
                        LensientEffectsController.shared.showAmbient()
                    }
                    confirmSelection() 
                } else if !self.path.isEmpty {
                    log.debug("OverlayView: Drag ended. No brushed text, but a path was drawn. Completing with path for area selection.")
                    // Show ambient for image selection too
                    MainActor.assumeIsolated {
                        LensientEffectsController.shared.showAmbient()
                    }
                    let pathBounds = self.path.boundingRect
                    let pathToReturn = self.path
                    resetAllSelectionStates()
                    completion(pathToReturn, nil, pathBounds)
                } else {
                    log.debug("OverlayView: Drag ended. No brushed text and no significant path drawn. Resetting.")
                    // Hide completely when nothing selected
                    MainActor.assumeIsolated {
                        LensientEffectsController.shared.hide()
                    }
                    completion(nil, nil, nil)
                    resetAllSelectionStates()
                }
            }
    }

    // Optimized: Uses precomputed allSelectableWords instead of Vision API calls per drag
    func updateBrushedTextSelection(drawnPath: Path, canvasProxySize: CGSize) {
        let now = Date()
        guard now.timeIntervalSince(lastSelectionUpdateTime) >= selectionUpdateThrottleInterval else { return }
        lastSelectionUpdateTime = now
        
        guard !drawnPath.isEmpty, !allSelectableWords.isEmpty else {
            if !brushedSelectedText.isEmpty { brushedSelectedText = "" }
            if !activeSelectionWordRects.isEmpty { activeSelectionWordRects = [] }
            return
        }

        // Priority 2: Use simple boundingRect instead of expensive strokedPath().cgPath.boundingBox
        let brushBounds = drawnPath.boundingRect.insetBy(dx: -15, dy: -15)
        
        var newBrushedText = ""
        var newWordRects: [CGRect] = []
        
        // Priority 1: Iterate precomputed words - NO Vision API calls!
        for word in allSelectableWords {
            if brushBounds.intersects(word.screenRect) {
                if !newBrushedText.isEmpty { newBrushedText.append(" ") }
                newBrushedText.append(word.text)
                newWordRects.append(word.screenRect)
            }
        }
        
        if self.brushedSelectedText != newBrushedText {
            self.brushedSelectedText = newBrushedText
        }
        if self.activeSelectionWordRects != newWordRects {
            self.activeSelectionWordRects = newWordRects
        }
    }

    // MARK: - Selection Logic
    
    func confirmSelection() {
        let textToSend = isHandleSelectionActive ? textForCurrentHandleSelection : brushedSelectedText
        let selectionBounds = activeSelectionWordRects.reduce(CGRect.null) { $0.union($1) }
        completion(self.path, textToSend.isEmpty ? nil : textToSend, selectionBounds.isNull ? nil : selectionBounds)
        
        // Trigger ripple effect at the center of the selection
        if !activeSelectionWordRects.isEmpty {
            let selectionCenter = activeSelectionWordRects.reduce(CGRect.null) { $0.union($1) }
            if !selectionCenter.isNull {
                rippleOrigin = CGPoint(x: selectionCenter.midX, y: selectionCenter.midY)
                rippleTrigger += 1
            }
        } else if let lastPoint = lastDrawingPoint {
            // Fallback to last drawing point
            rippleOrigin = lastPoint
            rippleTrigger += 1
        }
        
        if !textToSend.isEmpty {
            isHandleSelectionActive = true
            // Set up for handle interaction
            textForCurrentHandleSelection = textToSend // Text selected by brush OR handles
            
            // activeSelectionWordRects is from the LAST brush stroke or tap
            // currentHandleSelectionRects should become these if transitioning from brush
            if !isDraggingHandle { // Only update from brush if not already in handle drag
                 currentHandleSelectionRects = activeSelectionWordRects
            }

            if !currentHandleSelectionRects.isEmpty {
                currentSelectionStartHandleRect = currentHandleSelectionRects.first
                currentSelectionEndHandleRect = currentHandleSelectionRects.last
                
                // Correctly get globalIndex
                if let firstRect = currentSelectionStartHandleRect,
                   let startIndexInAllWords = allSelectableWords.firstIndex(where: { $0.screenRect == firstRect }) {
                    startHandleWordGlobalIndex = allSelectableWords[startIndexInAllWords].globalIndex
                } else {
                    startHandleWordGlobalIndex = nil
                }
                
                if let lastRect = currentSelectionEndHandleRect,
                   let endIndexInAllWords = allSelectableWords.firstIndex(where: { $0.screenRect == lastRect }) {
                    endHandleWordGlobalIndex = allSelectableWords[endIndexInAllWords].globalIndex
                } else {
                    endHandleWordGlobalIndex = nil
                }

            } else { // Should not happen if textToSend is not empty from brush
                isHandleSelectionActive = false 
            }
            
            // Clear brush-specific states
            self.path = Path()
            // activeSelectionWordRects are now stored in currentHandleSelectionRects or were used
            
            log.debug("OverlayView: Confirmed. Handle selection active. Text: '\(self.textForCurrentHandleSelection)'")
        } else {
            isHandleSelectionActive = false
            resetAllSelectionStates() 
            log.debug("OverlayView: Confirmed. No text to activate handles.")
        }
    }

    // Enhanced cancel function to also hide highlights/panel
    // Called when the user cancels (e.g., presses ESC or makes tiny drag)
    func cancelSelection() {
        resetAllSelectionStates()
        Task { @MainActor in ResultPanel.shared.hide() }
        completion(nil, nil, nil)
        showOverlay = false
    }

    private func resetAllSelectionStates() {
        isDragging = false
        path = Path()
        brushedSelectedText = ""
        activeSelectionWordRects = []
        isHandleSelectionActive = false
        startHandleWordGlobalIndex = nil
        endHandleWordGlobalIndex = nil
        currentSelectionStartHandleRect = nil
        currentSelectionEndHandleRect = nil
        currentHandleSelectionRects = []
        textForCurrentHandleSelection = ""
        selectedTextIndices = []
        hoveredTextIndex = nil
    }

    // Optimized hover detection using precomputed allSelectableWords
    private func updateHoveredTextIndex(at location: CGPoint, in size: CGSize) {
        // Throttle hover updates to ~30fps for performance
        let now = Date()
        guard now.timeIntervalSince(lastHoverUpdateTime) >= hoverUpdateThrottleInterval else {
            return
        }
        lastHoverUpdateTime = now
        
        // Use precomputed word rects for O(n) lookup with cached coordinates
        // This avoids recalculating screen rects from normalized each frame
        for word in allSelectableWords {
            if word.screenRect.contains(location) {
                if hoveredTextIndex != word.globalIndex {
                    hoveredTextIndex = word.globalIndex
                }
                return
            }
        }
        
        // Fallback to nil if no word found
        if hoveredTextIndex != nil {
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
    
    // MARK: - Helpers
    
    private func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }
    
    // Handle drag gesture for selection handles
    // MODIFIED: Changed from var to func to accept canvasSize
    private func handleDragGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard self.isHandleSelectionActive else { return } // Only care if handles are supposed to be active
                // if self.isDragging { return } // This might be too restrictive if dragGesture starts first briefly

                let handleTouchRadius: CGFloat = 20 
                if !self.isDraggingHandle { // Try to initiate a handle drag
                    if let startRect = self.currentSelectionStartHandleRect {
                        let handleCenter = CGPoint(x: startRect.minX, y: startRect.midY)
                        if distance(value.startLocation, handleCenter) < handleTouchRadius {
                            self.isDraggingHandle = true
                            self.draggedHandleType = .start
                            self.isDragging = false // Explicitly stop brush dragging mode
                            self.path = Path() 
                            log.debug("HandleDrag: Started dragging START handle")
                            // No need to call updateSelectionViaHandleDrag here yet, wait for actual movement
                            return // Successfully started handle drag
                        }
                    }
                    if let endRect = self.currentSelectionEndHandleRect {
                        let handleCenter = CGPoint(x: endRect.maxX, y: endRect.midY)
                        if distance(value.startLocation, handleCenter) < handleTouchRadius {
                            self.isDraggingHandle = true
                            self.draggedHandleType = .end
                            self.isDragging = false // Explicitly stop brush dragging mode
                            self.path = Path()
                            log.debug("HandleDrag: Started dragging END handle")
                            return // Successfully started handle drag
                        }
                    }
                    // If no handle was hit by startLocation, this drag is not for a handle
                    if !self.isDraggingHandle { return } 
                }
                
                // This will only be reached if isDraggingHandle was true from start or became true above
                if self.isDraggingHandle {
                    self.updateSelectionViaHandleDrag(newLocation: value.location, 
                                                      draggedHandle: self.draggedHandleType, 
                                                      canvasSize: canvasSize)
                }
            }
            .onEnded { value in
                if self.isDraggingHandle {
                     self.updateSelectionViaHandleDrag(newLocation: value.location, 
                                                      draggedHandle: self.draggedHandleType, 
                                                      canvasSize: canvasSize)
                    if !self.textForCurrentHandleSelection.isEmpty {
                        let handleSelectionBounds = self.currentHandleSelectionRects.reduce(CGRect.null) { $0.union($1) }
                        self.completion(nil, self.textForCurrentHandleSelection, handleSelectionBounds.isNull ? nil : handleSelectionBounds)
                    }
                    // else { // If selection became empty via handles, it might revert to no selection
                    //    self.isHandleSelectionActive = false
                    //    resetAllSelectionStates()
                    // }
                    self.isDraggingHandle = false
                    self.draggedHandleType = .none
                }
            }
    }
    
    private func updateSelectionViaHandleDrag(newLocation: CGPoint, draggedHandle: SelectionHandle, canvasSize: CGSize) {
        guard isHandleSelectionActive, !allSelectableWords.isEmpty else { return }

        var closestWordGlobalIndexToDragLocation: Int? = nil
        var minDistSqToDragLocation: CGFloat = .greatestFiniteMagnitude

        // Find the word whose center is closest to the current drag location
        for word in allSelectableWords {
            let wordCenter = CGPoint(x: word.screenRect.midX, y: word.screenRect.midY)
            let distSq = pow(wordCenter.x - newLocation.x, 2) + pow(wordCenter.y - newLocation.y, 2)
            if distSq < minDistSqToDragLocation {
                minDistSqToDragLocation = distSq
                closestWordGlobalIndexToDragLocation = word.globalIndex
            }
        }
        
        guard let targetGlobalIndexForDraggedHandle = closestWordGlobalIndexToDragLocation else { return }

        var newTentativeStartGlobalIndex: Int
        var newTentativeEndGlobalIndex: Int

        if draggedHandle == .start {
            newTentativeStartGlobalIndex = targetGlobalIndexForDraggedHandle
            newTentativeEndGlobalIndex = self.endHandleWordGlobalIndex ?? targetGlobalIndexForDraggedHandle // Anchor to old end or target if old end is nil
        } else { // .end or .none (though .none shouldn't happen if isDraggingHandle is true)
            newTentativeStartGlobalIndex = self.startHandleWordGlobalIndex ?? targetGlobalIndexForDraggedHandle // Anchor to old start or target
            newTentativeEndGlobalIndex = targetGlobalIndexForDraggedHandle
        }

        // Ensure start <= end
        if newTentativeStartGlobalIndex > newTentativeEndGlobalIndex {
            (newTentativeStartGlobalIndex, newTentativeEndGlobalIndex) = (newTentativeEndGlobalIndex, newTentativeStartGlobalIndex)
        }
        
        // Only update if the range actually changed to avoid unnecessary redraws/calculations
        if self.startHandleWordGlobalIndex == newTentativeStartGlobalIndex && self.endHandleWordGlobalIndex == newTentativeEndGlobalIndex {
            return
        }

        self.startHandleWordGlobalIndex = newTentativeStartGlobalIndex
        self.endHandleWordGlobalIndex = newTentativeEndGlobalIndex

        var tempText = ""
        var tempRects: [CGRect] = []
        var needsSpace = false

        if let startIdx = self.startHandleWordGlobalIndex, let endIdx = self.endHandleWordGlobalIndex, startIdx <= endIdx {
            for i in startIdx...endIdx {
                // Ensure index is within bounds of allSelectableWords
                if i >= 0 && i < allSelectableWords.count {
                    let word = allSelectableWords[i]
                    if needsSpace && !tempText.isEmpty && !tempText.hasSuffix(" ") {
                        tempText.append(" ")
                    }
                    tempText.append(word.text)
                    tempRects.append(word.screenRect)
                    needsSpace = true
                }
            }
        }
        
        self.textForCurrentHandleSelection = tempText
        self.currentHandleSelectionRects = tempRects
        
        // Update the visual rects for the handles themselves
        self.currentSelectionStartHandleRect = tempRects.first
        self.currentSelectionEndHandleRect = tempRects.last
    }

    // Update text selection based on current drawing position
    private func updateTextSelection(at location: CGPoint, canvasSize: CGSize) {
        let rects = overlayManager.detailedTextRegions
        guard !rects.isEmpty else { return }
        
        // Find the text box under the current position
        for (index, region) in rects.enumerated() {
            let screenRect = CGRect(
                x: region.normalizedRect.origin.x * canvasSize.width,
                y: (1 - region.normalizedRect.origin.y - region.normalizedRect.height) * canvasSize.height,
                width: region.normalizedRect.width * canvasSize.width,
                height: region.normalizedRect.height * canvasSize.height
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
        let rects = overlayManager.detailedTextRegions
        guard canvasSize != .zero, !rects.isEmpty else {
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
            let region = rects[range.start]
            let startScreenRect = CGRect(
                x: region.normalizedRect.origin.x * canvasSize.width,
                y: (1 - region.normalizedRect.origin.y - region.normalizedRect.height) * canvasSize.height,
                width: region.normalizedRect.width * canvasSize.width,
                height: region.normalizedRect.height * canvasSize.height
            )
            newStartHandle = CGPoint(x: startScreenRect.minX, y: startScreenRect.midY)
        }

        var newEndHandle: CGPoint? = nil
        if range.end >= 0 && range.end < rects.count {
            let region = rects[range.end]
            let endScreenRect = CGRect(
                x: region.normalizedRect.origin.x * canvasSize.width,
                y: (1 - region.normalizedRect.origin.y - region.normalizedRect.height) * canvasSize.height,
                width: region.normalizedRect.width * canvasSize.width,
                height: region.normalizedRect.height * canvasSize.height
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

    func processSelectableWords(canvasProxySize: CGSize) {
        let regions = overlayManager.detailedTextRegions
        guard canvasProxySize.width > 0, canvasProxySize.height > 0 else {
            self.allSelectableWords = []
            return
        }
        guard !regions.isEmpty else {
            self.allSelectableWords = []
            return
        }

        var tempSelectableWords: [SelectableWord] = []
        var currentGlobalIndex = 0

        for (regionIndex, region) in regions.enumerated() {
            let recognizedTextObject = region.recognizedText
            let fullString = recognizedTextObject.string

            fullString.enumerateSubstrings(in: fullString.startIndex..<fullString.endIndex, options: [.byWords, .substringNotRequired]) { (wordSubstring, wordSwiftRange, enclosingRange, stop) in
                // We use wordSwiftRange to get the bounding box from Vision
                do {
                    if let wordObservation = try recognizedTextObject.boundingBox(for: wordSwiftRange) {
                        let wordNormalizedBox = wordObservation.boundingBox
                        let wordScreenRect = CGRect(
                            x: wordNormalizedBox.origin.x * canvasProxySize.width,
                            y: (1 - wordNormalizedBox.origin.y - wordNormalizedBox.height) * canvasProxySize.height,
                            width: wordNormalizedBox.width * canvasProxySize.width,
                            height: wordNormalizedBox.height * canvasProxySize.height
                        )
                        // Use the actual substring for the text content
                        let actualWordText = String(fullString[wordSwiftRange])
                        
                        tempSelectableWords.append(SelectableWord(
                            text: actualWordText,
                            screenRect: wordScreenRect,
                            normalizedRect: wordNormalizedBox,
                            globalIndex: currentGlobalIndex,
                            sourceRegionIndex: regionIndex,
                            sourceWordSwiftRange: wordSwiftRange
                        ))
                        currentGlobalIndex += 1
                    }
                } catch {
                    log.warning("Error getting bounding box for word range \(wordSwiftRange): \(error)")
                }
            }
        }
        self.allSelectableWords = tempSelectableWords
        // print("Processed \(self.allSelectableWords.count) selectable words.")
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
    @State static var previewShowOverlay = true
    static var previewManager = OverlayManager.shared

    static var previews: some View {
        let dummyImage: CGImage? = nil

        OverlayView(
            overlayManager: previewManager,
            backgroundImage: dummyImage,
            showOverlay: $previewShowOverlay
        ) { selectedPath, selectedText, selectionRect in
            if let path = selectedPath {
                print("Preview completed with path: \(path.boundingRect), selected text: \(String(describing: selectedText)), rect: \(String(describing: selectionRect))")
            } else {
                print("Preview cancelled")
            }
            previewShowOverlay = false
        }
    }
}

