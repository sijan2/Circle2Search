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
    @State private var pathPoints: [CGPoint] = []
    
    // MARK: - Selection State
    
    @State var brushedSelectedText: String = ""
    @State var activeSelectionWordRects: [CGRect] = []
    @State var selectedTextIndices: Set<Int> = []
    @State var hoveredTextIndex: Int? = nil
    @State var allSelectableWords: [SelectableWord] = []
    @State private var lineGroupingThreshold: CGFloat = 8
    
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
    
    // MARK: - Barcode UX State
    
    @State private var copiedBarcodeIds: Set<UUID> = []  // Track which barcodes show "copied" feedback
    @State private var hoveredBarcodeId: UUID? = nil      // Track hover state for QR box
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
    private var brushSelectionRadius: CGFloat { max(12, androidStrokeWidth * 2.0) }
    
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
            .simultaneousGesture( 
                TapGesture()
                    .onEnded { _ in
                        log.debug("TAP detected! isResultPanelVisible=\(overlayManager.isResultPanelVisible), needsConfirmTapToExit=\(overlayManager.needsConfirmTapToExit)")
                        
                        // If popover just closed, this tap was the closing tap - clear flag and wait for next tap
                        if overlayManager.needsConfirmTapToExit {
                            log.debug("Clearing needsConfirmTapToExit - next tap will exit")
                            overlayManager.needsConfirmTapToExit = false
                            return
                        }
                        
                        // When popover is closed and confirmed, ANY tap exits the overlay
                        if !overlayManager.isResultPanelVisible {
                            log.debug("Popover closed - tap exits overlay")
                            cancelSelection()
                            return
                        }
                        
                        // When popover is OPEN: tap on word to select it (changes the search)
                        if let tappedGlobalIndex = hoveredTextIndex, tappedGlobalIndex < allSelectableWords.count {
                            let tappedWord = allSelectableWords[tappedGlobalIndex]
                            self.brushedSelectedText = tappedWord.text
                            self.activeSelectionWordRects = [tappedWord.screenRect]
                            log.debug("Tapped on word: \(tappedWord.text)")
                            confirmSelection()
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
                
                // Layer 3: Selection highlight (blue background behind selected text)
                selectionHighlightLayer

                // Layer 4: Drawing canvas for scribble
                drawingCanvasLayer
                
                // Layer 5: Selection handles (teardrop handles on top of canvas)
                selectionHandleLayer

                // Layer 6: Shimmer effect
                LensientMetalView(
                    isPaused: $overlayManager.shouldPauseMetalRendering
                )
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(false)
                
                // Layer 7: Barcode overlay indicators (MUST be above shimmer for visibility and tapping)
                barcodeOverlayLayer
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
                    pathPoints = [value.startLocation]
                    
                    // Start tracking shimmer at touch point
                    MainActor.assumeIsolated {
                        LensientEffectsController.shared.startTracking(at: value.startLocation)
                    }
                }
                
                // Priority 3: Distance threshold to reduce path complexity
                if let last = lastDrawingPoint, distance(last, value.location) < 2.0 { return }
                
                path.addLine(to: value.location)
                lastDrawingPoint = value.location
                pathPoints.append(value.location)
                
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
        
        guard !drawnPath.isEmpty, !allSelectableWords.isEmpty, !pathPoints.isEmpty else {
            if !brushedSelectedText.isEmpty { brushedSelectedText = "" }
            if !activeSelectionWordRects.isEmpty { activeSelectionWordRects = [] }
            return
        }

        let selectionRadius = brushSelectionRadius
        let brushBounds = boundingRect(for: pathPoints).insetBy(dx: -selectionRadius, dy: -selectionRadius)

        var touchedIndices: [Int] = []
        for (index, word) in allSelectableWords.enumerated() {
            guard brushBounds.intersects(word.screenRect) else { continue }
            let expandedRect = word.screenRect.insetBy(dx: -selectionRadius, dy: -selectionRadius)
            if pathIntersectsRect(pathPoints, rect: expandedRect) {
                touchedIndices.append(index)
            }
        }

        guard let minIndex = touchedIndices.min(), let maxIndex = touchedIndices.max() else {
            if !brushedSelectedText.isEmpty { brushedSelectedText = "" }
            if !activeSelectionWordRects.isEmpty { activeSelectionWordRects = [] }
            return
        }

        var newBrushedText = ""
        var newWordRects: [CGRect] = []
        for index in minIndex...maxIndex {
            let word = allSelectableWords[index]
            if !newBrushedText.isEmpty { newBrushedText.append(" ") }
            newBrushedText.append(word.text)
            newWordRects.append(word.screenRect)
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
            self.pathPoints = []
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
        pathPoints = []
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
    
    // MARK: - Barcode Overlay Layer
    
    /// Renders barcode highlights with Android-style action chips
    /// - Chip tap: Copies to clipboard + shows checkmark feedback
    /// - Box tap: Opens action (URL/phone/etc) + dismisses overlay
    private var barcodeOverlayLayer: some View {
        ForEach(overlayManager.detectedBarcodes) { barcode in
            VStack(spacing: 8) {
                // Barcode highlight rectangle - TAP TO OPEN AND DISMISS
                ZStack {
                    // Translucent background fill
                    RoundedRectangle(cornerRadius: 8)
                        .fill(barcodeAccentColor(for: barcode).opacity(hoveredBarcodeId == barcode.id ? 0.3 : 0.15))
                    
                    // Border stroke
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(barcodeAccentColor(for: barcode), lineWidth: hoveredBarcodeId == barcode.id ? 3.5 : 2.5)
                    
                    // Hover hint - "Click to open" indicator
                    if hoveredBarcodeId == barcode.id {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 20, weight: .medium))
                            Text("Click to open")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(barcodeAccentColor(for: barcode))
                        .opacity(0.8)
                    }
                }
                .frame(width: barcode.screenRect.width + 12, height: barcode.screenRect.height + 12)
                .contentShape(Rectangle())
                .onHover { isHovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        hoveredBarcodeId = isHovering ? barcode.id : nil
                    }
                }
                .onTapGesture {
                    // Box tap: OPEN and DISMISS
                    openAndDismiss(barcode: barcode)
                }
                
                // Action chip - TAP TO COPY
                actionChip(for: barcode)
            }
            .position(
                x: barcode.screenRect.midX,
                y: barcode.screenRect.midY + 20
            )
        }
        .edgesIgnoringSafeArea(.all)
    }
    
    /// Action chip view - shows checkmark when copied
    private func actionChip(for barcode: DetectableBarcode) -> some View {
        let isCopied = copiedBarcodeIds.contains(barcode.id)
        
        return HStack(spacing: 6) {
            // Icon: checkmark if copied, otherwise content type icon
            Image(systemName: isCopied ? "checkmark" : barcode.contentType.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .contentTransition(.symbolEffect(.replace))
            
            // Label: "Copied!" if copied, otherwise action label
            Text(isCopied ? "Copied!" : chipLabel(for: barcode))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(isCopied ? Color.green : barcodeAccentColor(for: barcode))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        )
        .scaleEffect(isCopied ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isCopied)
        .onTapGesture {
            // Chip tap: COPY to clipboard
            copyToClipboard(barcode: barcode)
        }
    }
    
    /// Get accent color based on barcode content type
    private func barcodeAccentColor(for barcode: DetectableBarcode) -> Color {
        switch barcode.contentType {
        case .url: return .blue
        case .wifi: return Color(red: 0.2, green: 0.7, blue: 0.4)
        case .phone, .sms: return .green
        case .email: return .blue
        case .contact: return .orange
        case .location: return .red
        case .event: return .purple
        case .product: return .gray
        default: return Color(red: 0.2, green: 0.7, blue: 0.4)
        }
    }
    
    /// Get descriptive chip label
    private func chipLabel(for barcode: DetectableBarcode) -> String {
        let payload = barcode.parsedPayload
        
        switch barcode.contentType {
        case .wifi:
            if let ssid = payload.wifiSSID {
                return "Copy \"\(ssid)\" password"
            }
            return "Copy password"
        case .url:
            if let urlStr = barcode.payloadString, let url = URL(string: urlStr), let host = url.host {
                let trimmed = host.replacingOccurrences(of: "www.", with: "")
                return trimmed.count > 18 ? String(trimmed.prefix(18)) + "…" : trimmed
            }
            return "Copy link"
        case .phone:
            if let phone = payload.phoneNumber {
                return phone.count > 15 ? String(phone.prefix(15)) + "…" : phone
            }
            return "Copy number"
        case .email:
            if let email = payload.emailAddress {
                let short = email.count > 18 ? String(email.prefix(15)) + "…" : email
                return short
            }
            return "Copy email"
        case .contact:
            if let name = payload.contactName {
                return name.count > 18 ? String(name.prefix(15)) + "…" : name
            }
            return "Copy contact"
        case .location:
            return "Copy location"
        case .product:
            return barcode.payloadString ?? "Copy barcode"
        default:
            return "Copy"
        }
    }
    
    // MARK: - Barcode Actions
    
    /// Copy barcode content to clipboard and show checkmark feedback
    private func copyToClipboard(barcode: DetectableBarcode) {
        let payload = barcode.parsedPayload
        var textToCopy: String = barcode.payloadString ?? ""
        
        // Get the most useful text to copy based on content type
        switch barcode.contentType {
        case .wifi:
            textToCopy = payload.wifiPassword ?? payload.wifiSSID ?? textToCopy
        case .url:
            textToCopy = payload.urlString ?? textToCopy
        case .phone:
            textToCopy = payload.phoneNumber ?? textToCopy
        case .email:
            textToCopy = payload.emailAddress ?? textToCopy
        case .contact:
            var parts: [String] = []
            if let name = payload.contactName { parts.append(name) }
            if let phone = payload.contactPhone { parts.append(phone) }
            if let email = payload.contactEmail { parts.append(email) }
            textToCopy = parts.joined(separator: "\n")
        case .location:
            if let lat = payload.latitude, let lng = payload.longitude {
                textToCopy = "\(lat), \(lng)"
            }
        default:
            break
        }
        
        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)
        log.info("Copied to clipboard: \(textToCopy)")
        
        // Show checkmark animation
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            copiedBarcodeIds.insert(barcode.id)
        }
        
        // Reset after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                _ = self.copiedBarcodeIds.remove(barcode.id)
            }
        }
    }
    
    /// Open barcode action and dismiss overlay using native macOS APIs
    private func openAndDismiss(barcode: DetectableBarcode) {
        log.info("Opening barcode action and dismissing: \(barcode.contentType)")
        
        let payload = barcode.parsedPayload
        let handler = BarcodeIntentHandler.shared
        
        // Dismiss helper
        func dismiss() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.showOverlay = false
                OverlayManager.shared.dismissOverlay()
            }
        }
        
        switch barcode.contentType {
        case .url:
            let urlStr = payload.urlString ?? barcode.payloadString ?? ""
            handler.openURL(urlStr) { success in
                if success { dismiss() }
            }
            
        case .wifi:
            // Copy password and optionally open WiFi settings
            handler.handleWiFi(
                ssid: payload.wifiSSID ?? "",
                password: payload.wifiPassword,
                encryption: payload.wifiEncryption,
                hidden: payload.wifiHidden
            ) { success, message in
                log.info("WiFi: \(message)")
                // For WiFi, also open system preferences
                handler.openWiFiSettings()
                dismiss()
            }
            
        case .phone:
            let number = payload.phoneNumber ?? barcode.payloadString ?? ""
            handler.callPhone(number) { success in
                if success { dismiss() }
            }
            
        case .sms:
            if let phone = payload.phoneNumber {
                handler.sendSMS(to: phone, message: payload.smsMessage) { success in
                    if success { dismiss() }
                }
            }
            
        case .email:
            if let email = payload.emailAddress {
                handler.sendEmail(
                    to: email,
                    subject: payload.emailSubject,
                    body: payload.emailBody
                ) { success in
                    if success { dismiss() }
                }
            }
            
        case .contact:
            // Use native Contacts API
            handler.addContact(
                name: payload.contactName,
                phone: payload.contactPhone,
                email: payload.contactEmail,
                organization: payload.contactOrganization
            ) { success, message in
                log.info("Contact: \(message)")
                dismiss()
            }
            
        case .event:
            // Use native Calendar API
            handler.addCalendarEvent(
                title: payload.eventTitle,
                location: payload.eventLocation,
                startDate: payload.eventStartDate,
                endDate: payload.eventEndDate
            ) { success, message in
                log.info("Event: \(message)")
                dismiss()
            }
            
        case .location:
            if let lat = payload.latitude, let lng = payload.longitude {
                handler.openLocation(
                    latitude: lat,
                    longitude: lng,
                    label: payload.locationLabel
                ) { success in
                    if success { dismiss() }
                }
            }
            
        case .product:
            if let code = barcode.payloadString {
                handler.searchProduct(code) { success in
                    if success { dismiss() }
                }
            }
            
        default:
            // For unknown types, search Google
            if let text = barcode.payloadString {
                if let url = URL(string: text), url.scheme != nil {
                    handler.openURL(text) { _ in dismiss() }
                } else {
                    handler.searchGoogle(text) { _ in dismiss() }
                }
            }
        }
    }
    
    /// Show success visual effect (legacy, kept for compatibility)
    private func showSuccessEffect() {
        MainActor.assumeIsolated {
            LensientEffectsController.shared.showAmbient()
        }
    }
    
    // MARK: - Selection Highlight Layer (Blue Background)
    
    /// Renders blue highlight rectangles behind selected words (like Chrome/Safari)
    private var selectionHighlightLayer: some View {
        Canvas { context, size in
            // Use system accent color with transparency for selection highlight
            let highlightColor = Color.accentColor.opacity(0.35)
            
            // Choose the correct source of rects based on selection mode
            let rectsToHighlight = isHandleSelectionActive 
                ? currentHandleSelectionRects 
                : activeSelectionWordRects
            
            guard !rectsToHighlight.isEmpty else { return }
            
            for rect in rectsToHighlight {
                // Slightly expand rect for visual polish
                let expandedRect = rect.insetBy(dx: -2, dy: -1)
                let roundedPath = Path(roundedRect: expandedRect, cornerRadius: 3)
                context.fill(roundedPath, with: .color(highlightColor))
            }
        }
        .edgesIgnoringSafeArea(.all)
        .allowsHitTesting(false)
    }
    
    // MARK: - Teardrop Handle Shape
    
    /// Creates a teardrop-shaped selection handle path (like native macOS/iOS selection)
    /// - Parameters:
    ///   - point: The anchor point where the handle connects to the text
    ///   - isStart: If true, teardrop points up (start handle); otherwise points down (end handle)
    private func teardropHandlePath(at point: CGPoint, isStart: Bool) -> Path {
        var path = Path()
        let handleHeight: CGFloat = 20
        let circleRadius: CGFloat = 5
        let stemWidth: CGFloat = 2.5
        
        if isStart {
            // Start handle: stem goes UP from anchor, circle at TOP
            // Anchor point is at bottom of stem (left edge of first word, at baseline)
            let stemTop = point.y - handleHeight + circleRadius
            let circleCenter = CGPoint(x: point.x, y: stemTop)
            
            // Circle at top
            path.addEllipse(in: CGRect(
                x: circleCenter.x - circleRadius,
                y: circleCenter.y - circleRadius,
                width: circleRadius * 2,
                height: circleRadius * 2
            ))
            
            // Stem from circle bottom to anchor point
            path.addRect(CGRect(
                x: point.x - stemWidth / 2,
                y: circleCenter.y,
                width: stemWidth,
                height: point.y - circleCenter.y
            ))
        } else {
            // End handle: stem goes DOWN from anchor, circle at BOTTOM
            // Anchor point is at top of stem (right edge of last word, at top)
            let stemBottom = point.y + handleHeight - circleRadius
            let circleCenter = CGPoint(x: point.x, y: stemBottom)
            
            // Stem from anchor point down to circle
            path.addRect(CGRect(
                x: point.x - stemWidth / 2,
                y: point.y,
                width: stemWidth,
                height: circleCenter.y - point.y
            ))
            
            // Circle at bottom
            path.addEllipse(in: CGRect(
                x: circleCenter.x - circleRadius,
                y: circleCenter.y - circleRadius,
                width: circleRadius * 2,
                height: circleRadius * 2
            ))
        }
        
        return path
    }
    
    // MARK: - Selection Handle Layer
    
    /// Renders teardrop selection handles at the start and end of selection
    private var selectionHandleLayer: some View {
        Canvas { context, size in
            guard isHandleSelectionActive else { return }
            
            let handleColor = Color.accentColor
            
            // Start handle: left edge of first selected word, pointing up
            if let startRect = currentSelectionStartHandleRect {
                // Anchor at bottom-left of first word
                let startAnchor = CGPoint(x: startRect.minX, y: startRect.maxY)
                let startPath = teardropHandlePath(at: startAnchor, isStart: true)
                context.fill(startPath, with: .color(handleColor))
            }
            
            // End handle: right edge of last selected word, pointing down
            if let endRect = currentSelectionEndHandleRect {
                // Anchor at top-right of last word
                let endAnchor = CGPoint(x: endRect.maxX, y: endRect.minY)
                let endPath = teardropHandlePath(at: endAnchor, isStart: false)
                context.fill(endPath, with: .color(handleColor))
            }
        }
        .edgesIgnoringSafeArea(.all)
        .allowsHitTesting(false)
    }
    
    // MARK: - Helpers
    
    private func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let firstPoint = points.first else { return .null }
        var minX = firstPoint.x
        var maxX = firstPoint.x
        var minY = firstPoint.y
        var maxY = firstPoint.y

        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func pathIntersectsRect(_ points: [CGPoint], rect: CGRect) -> Bool {
        guard points.count > 1 else {
            if let point = points.first { return rect.contains(point) }
            return false
        }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            if segmentIntersectsRect(start, end, rect: rect) {
                return true
            }
        }
        return false
    }

    private func segmentIntersectsRect(_ start: CGPoint, _ end: CGPoint, rect: CGRect) -> Bool {
        if rect.contains(start) || rect.contains(end) { return true }

        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)

        let epsilon: CGFloat = 0.0001
        return segmentsIntersect(start, end, topLeft, topRight, epsilon: epsilon)
            || segmentsIntersect(start, end, topRight, bottomRight, epsilon: epsilon)
            || segmentsIntersect(start, end, bottomRight, bottomLeft, epsilon: epsilon)
            || segmentsIntersect(start, end, bottomLeft, topLeft, epsilon: epsilon)
    }

    private func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint, epsilon: CGFloat) -> Bool {
        let d1 = cross(p3, p4, p1)
        let d2 = cross(p3, p4, p2)
        let d3 = cross(p1, p2, p3)
        let d4 = cross(p1, p2, p4)

        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }

        if abs(d1) <= epsilon && onSegment(p3, p4, p1, epsilon: epsilon) { return true }
        if abs(d2) <= epsilon && onSegment(p3, p4, p2, epsilon: epsilon) { return true }
        if abs(d3) <= epsilon && onSegment(p1, p2, p3, epsilon: epsilon) { return true }
        if abs(d4) <= epsilon && onSegment(p1, p2, p4, epsilon: epsilon) { return true }

        return false
    }

    private func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private func onSegment(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint, epsilon: CGFloat) -> Bool {
        let minX = min(a.x, b.x) - epsilon
        let maxX = max(a.x, b.x) + epsilon
        let minY = min(a.y, b.y) - epsilon
        let maxY = max(a.y, b.y) + epsilon
        return p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
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
        var minHorizontalDistance: CGFloat = .greatestFiniteMagnitude

        for word in allSelectableWords {
            let verticalDistance = abs(word.screenRect.midY - newLocation.y)
            if verticalDistance <= lineGroupingThreshold {
                let horizontalDistance = abs(word.screenRect.midX - newLocation.x)
                if horizontalDistance < minHorizontalDistance {
                    minHorizontalDistance = horizontalDistance
                    closestWordGlobalIndexToDragLocation = word.globalIndex
                }
            }
        }

        if closestWordGlobalIndexToDragLocation == nil {
            for word in allSelectableWords {
                let wordCenter = CGPoint(x: word.screenRect.midX, y: word.screenRect.midY)
                let distSq = pow(wordCenter.x - newLocation.x, 2) + pow(wordCenter.y - newLocation.y, 2)
                if distSq < minDistSqToDragLocation {
                    minDistSqToDragLocation = distSq
                    closestWordGlobalIndexToDragLocation = word.globalIndex
                }
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
            self.lineGroupingThreshold = 8
            return
        }
        guard !regions.isEmpty else {
            self.allSelectableWords = []
            self.lineGroupingThreshold = 8
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
        self.allSelectableWords = orderSelectableWords(tempSelectableWords)
        self.hoveredTextIndex = nil
        // print("Processed \(self.allSelectableWords.count) selectable words.")
    }

    private func orderSelectableWords(_ words: [SelectableWord]) -> [SelectableWord] {
        guard !words.isEmpty else { return [] }

        let sortedHeights = words.map { $0.screenRect.height }.sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]
        let groupingThreshold = max(4, medianHeight * 0.6)
        lineGroupingThreshold = groupingThreshold

        let sortedByY = words.sorted { $0.screenRect.minY < $1.screenRect.minY }
        var lines: [[SelectableWord]] = []
        var currentLine: [SelectableWord] = []
        var currentLineMidY: CGFloat = 0

        for word in sortedByY {
            let midY = word.screenRect.midY
            if currentLine.isEmpty {
                currentLine = [word]
                currentLineMidY = midY
                continue
            }

            if abs(midY - currentLineMidY) <= groupingThreshold {
                currentLine.append(word)
                let count = CGFloat(currentLine.count)
                currentLineMidY = (currentLineMidY * (count - 1) + midY) / count
            } else {
                lines.append(currentLine)
                currentLine = [word]
                currentLineMidY = midY
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        let orderedWords = lines.flatMap { line in
            line.sorted { $0.screenRect.minX < $1.screenRect.minX }
        }

        return orderedWords.enumerated().map { index, word in
            SelectableWord(
                text: word.text,
                screenRect: word.screenRect,
                normalizedRect: word.normalizedRect,
                globalIndex: index,
                sourceRegionIndex: word.sourceRegionIndex,
                sourceWordSwiftRange: word.sourceWordSwiftRange
            )
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

