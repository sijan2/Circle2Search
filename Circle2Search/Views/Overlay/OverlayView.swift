import SwiftUI
import MetalKit // <-- Import MetalKit
import Vision // Ensure Vision is imported for VNRecognizedText

struct OverlayView: View {
    // Define SelectableWord and SelectionHandle at the top of OverlayView struct
    struct SelectableWord: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let screenRect: CGRect       
        let normalizedRect: CGRect   // Original normalized rect from Vision for this word/segment
        let globalIndex: Int         // Unique index in the flattened list of all words
        let sourceRegionIndex: Int   // Index of the parent DetailedTextRegion
        let sourceWordSwiftRange: Range<String.Index> // Range within the source region's full string
    }
    enum SelectionHandle { case start, end, none }

    @ObservedObject var overlayManager: OverlayManager // Inject the manager
    var backgroundImage: CGImage?
    let detailedTextRegions: [DetailedTextRegion]? // MODIFIED: To accept DetailedTextRegion
    @State private var path = Path()
    @State private var drawingPoints: [CGPoint] = [] // Keep track for potential analysis/smoothing
    @State private var brushedSelectedText: String = "" // NEW: For the precise brushed text
    @State private var activeSelectionWordRects: [CGRect] = [] // RENAMED: For clarity, as it will now store word/segment bounding boxes
    @State private var selectedTextIndices: Set<Int> = [] // <-- ADDED: To track selected text
    @State private var hoveredTextIndex: Int? = nil // NEW: For hover effect
    @State private var showSearchButton = false // For confirming drag selection
    @Binding var showOverlay: Bool // Use binding to allow dismissal from here
    var completion: (Path?, String?) -> Void // Path is nil if cancelled, added String? for the brushed text

    // Environment to detect Dark Mode
    @Environment(\.colorScheme) var colorScheme

    // State for animation timing
    @State private var startDate = Date()

    // Gesture state
    @State private var isDragging = false

    // ESC key monitor
    @State private var escapeEventMonitor: Any?

    @FocusState private var isViewFocused: Bool

    // Animation state
    @State private var glowOpacity: Double = 0.0
    @State private var glowScale: CGFloat = 1.0
    @State private var lastDrawingPoint: CGPoint?
    @State private var drawingAnimation: Animation?

    // Add new state variables for selection handles
    @State private var selectionStartHandle: CGPoint?
    @State private var selectionEndHandle: CGPoint?
    @State private var isDraggingHandle: Bool = false // True if a selection handle is being dragged
    @State private var draggedHandleType: SelectionHandle = .none // Which handle is being dragged
    @State private var selectedTextRange: TextSelectionRange?
    
    // State for handle-based selection refinement
    @State private var isHandleSelectionActive: Bool = false
    @State private var startHandleWordGlobalIndex: Int? // Global index in allSelectableWords
    @State private var endHandleWordGlobalIndex: Int?   // Global index in allSelectableWords
    // Screen rects for drawing the start and end handles accurately
    @State private var currentSelectionStartHandleRect: CGRect? 
    @State private var currentSelectionEndHandleRect: CGRect?  
    // All words forming the current selection controlled by handles
    @State private var currentHandleSelectionRects: [CGRect] = [] 
    @State private var textForCurrentHandleSelection: String = ""
    
    // Ripple effect state
    @State private var rippleOrigin: CGPoint = .zero
    @State private var rippleTrigger: Int = 0

    // Processed list of all words with their properties
    @State private var allSelectableWords: [SelectableWord] = []

    // ADDED: Struct for text selection range to conform to Equatable
    struct TextSelectionRange: Equatable {
        var start: Int
        var end: Int
    }
    
    // Extracted Drawing Canvas Layer
    private var drawingCanvasLayer: some View {
        GeometryReader { canvasGeometryProxy in 
            Canvas { context, size in 
                // Only draw the scribble path - no blue selection boxes
                if !path.isEmpty {
                    let timelineDate = startDate
                    let currentTime = Date().timeIntervalSince(timelineDate)
                    let pulseFrequency: Double = 1.8
                    let minOpacity: Double = 0.2
                    let maxOpacity: Double = 0.9
                    let pulse = (sin(currentTime * 2 * .pi * pulseFrequency) + 1) / 2
                    let animatedGlowOpacity = minOpacity + (maxOpacity - minOpacity) * pulse
                    let glowPath = path.strokedPath(StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    context.addFilter(.blur(radius: 3))
                    context.stroke(glowPath, with: .color(.cyan.opacity(animatedGlowOpacity)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    let gradient = Gradient(colors: [.cyan.opacity(0.8), .blue.opacity(0.6), .purple.opacity(0.4)])
                    context.stroke(path, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)), 
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    if let lastPoint = lastDrawingPoint {
                        let tipSize: CGFloat = 12.0
                        let animatedTipOpacity = 0.6 + 0.4 * pulse 
                        let tipPath = Path(ellipseIn: CGRect(x: lastPoint.x - tipSize/2, y: lastPoint.y - tipSize/2, width: tipSize, height: tipSize))
                        context.addFilter(.blur(radius: 2))
                        context.fill(tipPath, with: .color(.cyan.opacity(animatedTipOpacity)))
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
                            print("Tapped on word: \(tappedWord.text)")
                            confirmSelection() // This will set up handle selection for the single tapped word
                        }
                    }
            )
            .onChange(of: detailedTextRegions) { _, newRegions in
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !overlayManager.isWindowActuallyVisible)) { timeline in
            ZStack {
                Color.clear.keyboardShortcut(.escape, modifiers: []).allowsHitTesting(false)
                
                // Layer 1: Screenshot background
                if let bgImage = backgroundImage {
                    Image(decorative: bgImage, scale: 1.0).resizable().aspectRatio(contentMode: .fill).edgesIgnoringSafeArea(.all).allowsHitTesting(false)
                }
                
                // Layer 2: Dark scrim overlay (Android uses ~3% black)
                Color.black.opacity(0.03).edgesIgnoringSafeArea(.all).allowsHitTesting(false)

                // Layer 3: Drawing canvas for scribble
                drawingCanvasLayer

                // Layer 4: Shimmer effect
                GeometryReader { geometry in
                    LensientMetalView(
                        isPaused: $overlayManager.shouldPauseMetalRendering
                    )
                    .edgesIgnoringSafeArea(.all)
                    .allowsHitTesting(false)
                    .onAppear {
                        Task { @MainActor in
                            LensientEffectsController.shared.setViewSize(geometry.size)
                            LensientEffectsController.shared.showIdle()
                        }
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        Task { @MainActor in
                            LensientEffectsController.shared.setViewSize(newSize)
                        }
                    }
                }
            }
            .onAppear {
                setupEscapeKeyMonitor()
                isViewFocused = true 
            }
            .onDisappear {
                removeEscapeKeyMonitor()
                Task { @MainActor in
                    LensientEffectsController.shared.hide()
                }
            }
            .onChange(of: showOverlay) { _, newValue in
                if newValue == true {
                    resetAllSelectionStates() 
                    startDate = Date()
                    // Show shimmer at center when overlay appears
                    Task { @MainActor in
                        LensientEffectsController.shared.showIdle()
                    }
                } else {
                    Task { @MainActor in
                        LensientEffectsController.shared.hide()
                    }
                }
            }
        }
        .focusable(false)
        .focusEffectDisabled()
        .edgesIgnoringSafeArea(.all)
        .background(TransparentWindowView())
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
                    drawingPoints.append(value.startLocation)
                    
                    // Start tracking shimmer at touch point
                    Task { @MainActor in
                        LensientEffectsController.shared.startTracking(at: value.startLocation)
                    }
                }
                path.addLine(to: value.location)
                drawingPoints.append(value.location) 
                lastDrawingPoint = value.location
                
                // Update shimmer position
                Task { @MainActor in
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
                    print("OverlayView: Drag ended. Brushed text found: '\(brushedSelectedText)'. Confirming text selection.")
                    
                    let selectionBounds = activeSelectionWordRects.reduce(CGRect.null) { $0.union($1) }
                    Task { @MainActor in
                        if !selectionBounds.isNull {
                            LensientEffectsController.shared.showSelection(rect: selectionBounds)
                        }
                    }
                    
                    confirmSelection() 
                } else if !self.path.isEmpty {
                    print("OverlayView: Drag ended. No brushed text, but a path was drawn. Completing with path for area selection.")
                    
                    let pathBounds = self.path.boundingRect
                    Task { @MainActor in
                        LensientEffectsController.shared.showSelection(rect: pathBounds)
                    }
                    
                    let pathToReturn = self.path
                    resetAllSelectionStates()
                    completion(pathToReturn, nil)
                } else {
                    print("OverlayView: Drag ended. No brushed text and no significant path drawn. Resetting.")
                    
                    Task { @MainActor in
                        LensientEffectsController.shared.hide()
                    }
                    
                    completion(nil, nil)
                    resetAllSelectionStates()
                }
            }
    }

    // NEW: Function for fine-grained text selection
    func updateBrushedTextSelection(drawnPath: Path, canvasProxySize: CGSize) {
        guard let regions = detailedTextRegions, !drawnPath.isEmpty else {
            if !brushedSelectedText.isEmpty { brushedSelectedText = "" }
            if !activeSelectionWordRects.isEmpty { activeSelectionWordRects = [] }
            return
        }

        let brushPathBoundingBox = drawnPath.strokedPath(StrokeStyle(lineWidth: 15.0, lineCap: .round, lineJoin: .round)).cgPath.boundingBox
        var newBrushedText = ""
        var newWordRects: [CGRect] = []
        var needsSpace = false

        for region in regions {
            let recognizedTextObject = region.recognizedText
            let fullString = recognizedTextObject.string
            
            let blockScreenRect = CGRect(
                x: region.normalizedRect.origin.x * canvasProxySize.width,
                y: (1 - region.normalizedRect.origin.y - region.normalizedRect.height) * canvasProxySize.height,
                width: region.normalizedRect.width * canvasProxySize.width,
                height: region.normalizedRect.height * canvasProxySize.height
            )

            if !brushPathBoundingBox.intersects(blockScreenRect) {
                continue
            }

            var blockTextSelected = false
            fullString.enumerateSubstrings(in: fullString.startIndex..<fullString.endIndex, options: .byWords) { (wordSubstring, wordSwiftRange, enclosingRange, stop) in
                guard let word = wordSubstring else { return }
                let wordNSRange = NSRange(wordSwiftRange, in: fullString) 
                
                do {
                    if let wordObservation = try recognizedTextObject.boundingBox(for: wordSwiftRange) { 
                        let wordNormalizedBox = wordObservation.boundingBox
                        let wordScreenRect = CGRect(
                            x: wordNormalizedBox.origin.x * canvasProxySize.width,
                            y: (1 - wordNormalizedBox.origin.y - wordNormalizedBox.height) * canvasProxySize.height,
                            width: wordNormalizedBox.width * canvasProxySize.width,
                            height: wordNormalizedBox.height * canvasProxySize.height
                        )
                        
                        if brushPathBoundingBox.intersects(wordScreenRect) {
                            if needsSpace && !newBrushedText.isEmpty && !newBrushedText.hasSuffix(" ") {
                                newBrushedText.append(" ")
                            }
                            newBrushedText.append(word)
                            newWordRects.append(wordScreenRect)
                            blockTextSelected = true
                            needsSpace = true 
                        }
                    }
                } catch {
                    // print("Error getting bounding box for word '\(word)': \(error)")
                }
            }
            if blockTextSelected {
                needsSpace = true 
            } 
        }
        
        if self.brushedSelectedText != newBrushedText {
            self.brushedSelectedText = newBrushedText
        }
        if self.activeSelectionWordRects != newWordRects {
            self.activeSelectionWordRects = newWordRects
        }
    }

    // Called when the user confirms the selection (e.g., clicks the button)
    func confirmSelection() {
        let textToSend = isHandleSelectionActive ? textForCurrentHandleSelection : brushedSelectedText
        completion(self.path, textToSend.isEmpty ? nil : textToSend)
        
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
            self.drawingPoints = []
            // activeSelectionWordRects are now stored in currentHandleSelectionRects or were used
            
            print("OverlayView: Confirmed. Handle selection active. Text: '\(self.textForCurrentHandleSelection)'")
        } else {
            isHandleSelectionActive = false
            resetAllSelectionStates() 
            print("OverlayView: Confirmed. No text to activate handles.")
        }
    }

    // Enhanced cancel function to also hide highlights/panel
    // Called when the user cancels (e.g., presses ESC or makes tiny drag)
    func cancelSelection() {
        resetAllSelectionStates()
        Task { @MainActor in ResultPanel.shared.hide() }
        completion(nil, nil)
        showOverlay = false
    }

    private func resetAllSelectionStates() {
        isDragging = false
        path = Path()
        drawingPoints = []
        brushedSelectedText = ""
        activeSelectionWordRects = []
        isHandleSelectionActive = false
        startHandleWordGlobalIndex = nil
        endHandleWordGlobalIndex = nil
        currentSelectionStartHandleRect = nil
        currentSelectionEndHandleRect = nil
        currentHandleSelectionRects = []
        textForCurrentHandleSelection = ""
        selectedTextIndices = [] // Ensure this is also reset if it was used by tap
        hoveredTextIndex = nil
    }

    private func updateHoveredTextIndex(at location: CGPoint, in size: CGSize) {
        if let rects = detailedTextRegions {
            for (index, region) in rects.enumerated() {
                let denormalizedRect = CGRect(
                    x: region.normalizedRect.origin.x * size.width,
                    y: (1 - region.normalizedRect.origin.y - region.normalizedRect.height) * size.height, // Adjust for bottom-left origin
                    width: region.normalizedRect.width * size.width,
                    height: region.normalizedRect.height * size.height
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
                            self.drawingPoints = []
                            print("HandleDrag: Started dragging START handle")
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
                            self.drawingPoints = []
                            print("HandleDrag: Started dragging END handle")
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
                         self.completion(nil, self.textForCurrentHandleSelection)
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
        guard let rects = detailedTextRegions else { return }
        
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
        guard canvasSize != .zero, let rects = self.detailedTextRegions, !rects.isEmpty else {
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
        guard let regions = detailedTextRegions, canvasProxySize.width > 0, canvasProxySize.height > 0 else {
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
                    print("Error getting bounding box for word range \(wordSwiftRange): \(error)")
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
            detailedTextRegions: nil, // <-- Add new parameter for preview (can be nil or sample data)
            showOverlay: $previewShowOverlay // Pass the dummy binding
        ) { selectedPath, selectedText in
            if let path = selectedPath {
                print("Preview completed with path: \(path.boundingRect), selected text: \(String(describing: selectedText))")
            } else {
                print("Preview cancelled")
            }
            previewShowOverlay = false // Simulate dismissal
        }
    }
}

