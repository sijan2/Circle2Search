import SwiftUI

// Structure to hold dot properties
struct NoiseDot: Identifiable {
    let id = UUID()
    var position: CGPoint
    let initialSize: CGFloat
    let color: Color
    var initialOpacity: Double // Base opacity
}

struct NoiseOverlayView: View {
    @State private var dots: [NoiseDot] = []
    @State private var rotation: Double = 0 // For border animation
    @State private var pulseScale: CGFloat = 1.0 // For pulsing effect
    @State private var wavePhase: Double = 0 // For wave animation
    @State private var isActivated: Bool = true // Control for activating the effect
    
    let dotCount = 3500 // Increase density slightly?
    let baseBackgroundOpacity = 0.4 // Increased base opacity

    // Define a color palette - More vibrant options
    let noiseColors: [Color] = [
        .white.opacity(0.98), // Very bright white
        Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.6), // Light Sky Blue
        Color(red: 1.0, green: 0.5, blue: 0.8).opacity(0.5), // Pinkish
        Color(red: 0.5, green: 1.0, blue: 0.5).opacity(0.4), // Lime Green
        Color(red: 0.8, green: 0.6, blue: 1.0).opacity(0.5), // Lavender
        .cyan.opacity(0.6)
    ]
    
    // Border configuration
    var borderWidth: CGFloat = 5.0 // Increased for more visible effect
    var cornerRadius: CGFloat = 16
    var glowIntensity: Double = 1.5 // Increased intensity
    var animationDuration: Double = 5
    // Apple Intelligence inspired colors
    let borderColors: [Color] = [
        Color(red: 0.2, green: 0.4, blue: 1.0), // Electric blue
        Color(red: 0.45, green: 0.0, blue: 0.8), // Rich violet
        Color(red: 0.8, green: 0.2, blue: 1.0), // Fuchsia
        Color(red: 1.0, green: 0.4, blue: 0.7), // Warm pink
        Color(red: 0.3, green: 0.7, blue: 1.0), // Sky blue
        Color(red: 0.0, green: 0.5, blue: 1.0), // Deep blue
        Color(red: 0.2, green: 0.4, blue: 1.0), // Back to electric blue
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Noise overlay with animated dots
                TimelineView(.animation(minimumInterval: 0.03, paused: false)) { timeline in // Faster update?
                    Canvas { context, size in
                        let time = timeline.date.timeIntervalSinceReferenceDate

                        for dot in dots {
                            // Calculate animated opacity: Use sine wave based on time + dot's initial opacity/position for variation
                            let timeFactor = sin(time * 2.0 + dot.position.y * 0.05) // Adjust frequency/phase
                            let animatedOpacity = dot.initialOpacity * (0.6 + 0.4 * timeFactor) // Oscillate between 60% and 100% of initialOpacity

                            context.fill(
                                Path(ellipseIn: CGRect(x: dot.position.x, y: dot.position.y, width: dot.initialSize, height: dot.initialSize)),
                                with: .color(dot.color.opacity(max(0, min(1, animatedOpacity)))) // Clamp opacity
                            )
                        }
                    }
                    .blur(radius: 0.6) // Slightly more blur?
                    .blendMode(.screen)
                    .edgesIgnoringSafeArea(.all)
                    // Generate dots when the view appears and size is known
                    .onAppear {
                        generateDots(size: geometry.size)
                    }
                     // Regenerate if size changes significantly (e.g., screen change)
                     // Updated onChange syntax for macOS 14+ using two parameters
                    .onChange(of: geometry.size) { oldValue, newValue in
                         generateDots(size: newValue)
                     }
                }
                
                // Glowing border overlay with enhanced effects
                TimelineView(.animation(minimumInterval: 0.03)) { _ in
                    ZStack {
                        // Additional diffuse glow layer (very spread)
                        createGradientBorder(for: geometry.size)
                            .blur(radius: 25 * glowIntensity)
                            .opacity(0.5 * glowIntensity)
                            .scaleEffect(pulseScale + 0.05)
                        
                        // Glow layer 3 (most diffuse)
                        createGradientBorder(for: geometry.size)
                            .blur(radius: 20 * glowIntensity)
                            .opacity(0.7 * glowIntensity)
                            .scaleEffect(pulseScale + 0.03)
                        
                        // Glow layer 2 (medium diffuse)
                        createGradientBorder(for: geometry.size)
                            .blur(radius: 15 * glowIntensity)
                            .opacity(0.8 * glowIntensity)
                            .scaleEffect(pulseScale + 0.02)
                        
                        // Glow layer 1 (least diffuse)
                        createGradientBorder(for: geometry.size)
                            .blur(radius: 10 * glowIntensity)
                            .opacity(0.9 * glowIntensity)
                            .scaleEffect(pulseScale + 0.01)
                        
                        // Base sharp layer
                        createGradientBorder(for: geometry.size)
                            .blur(radius: 0.5) // Very slight blur for anti-aliasing
                            .scaleEffect(pulseScale)
                        
                        // Specular highlight (brighter)
                        createGradientBorder(for: geometry.size, isSpecular: true)
                            .blur(radius: 0.3)
                            .opacity(0.9)
                            .scaleEffect(pulseScale - 0.01)
                    }
                    .mask(
                        waveStrokeMask(for: geometry.size)
                    )
                }
            }
            .background(.clear)
            .onAppear {
                // Start the animations
                startAnimations()
            }
        }
    }
    
    // Create a wavy stroke mask for the gradient
    private func waveStrokeMask(for size: CGSize) -> some View {
        let waveStrength: CGFloat = 2.0 // Strength of wave distortion
        
        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(lineWidth: borderWidth)
                .offset(x: sin(wavePhase + 0.0) * waveStrength,
                        y: cos(wavePhase + 0.5) * waveStrength)
            
            // Additional stroke layers with offset phases for more complex wave effect
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(lineWidth: borderWidth * 0.9)
                .offset(x: sin(wavePhase + 2.0) * waveStrength,
                        y: cos(wavePhase + 1.5) * waveStrength)
                .opacity(0.8)
            
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(lineWidth: borderWidth * 0.8)
                .offset(x: sin(wavePhase + 4.0) * waveStrength,
                        y: cos(wavePhase + 3.5) * waveStrength)
                .opacity(0.6)
        }
    }

    // Start all animations
    private func startAnimations() {
        // Continuous gradient rotation animation
        withAnimation(.linear(duration: animationDuration).repeatForever(autoreverses: false)) {
            rotation = 360
        }
        
        // Subtle pulsing animation
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
            pulseScale = 1.03 // Subtle scaling effect
        }
        
        // Wave motion animation
        withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
            wavePhase = .pi * 2 // Full cycle
        }
    }

    // Function to generate the initial set of dots
    private func generateDots(size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }
        var newDots: [NoiseDot] = []
        var rng = SystemRandomNumberGenerator() // Use system RNG for initial placement

        for _ in 0..<dotCount {
            let x = CGFloat.random(in: 0..<size.width, using: &rng)
            let y = CGFloat.random(in: 0..<size.height, using: &rng)
            let dotSize = CGFloat.random(in: 1...3.0, using: &rng) // Slightly larger max size
            let color = noiseColors.randomElement(using: &rng) ?? .white
            let opacity = Double.random(in: 0.4...0.9, using: &rng) // Increased opacity range

            newDots.append(NoiseDot(
                position: CGPoint(x: x, y: y),
                initialSize: dotSize,
                color: color,
                initialOpacity: opacity
            ))
        }
        self.dots = newDots
        print("Generated \(dots.count) noise dots.")
    }
    
    // Helper function to create the gradient border
    private func createGradientBorder(for size: CGSize, isSpecular: Bool = false) -> some View {
        let colors: [Color] = isSpecular ? 
            [.white.opacity(0.9), .white.opacity(0.6), .white.opacity(0.9)] :
            borderColors
        
        return AngularGradient(
            gradient: Gradient(colors: colors),
            center: .center,
            angle: .degrees(rotation)
        )
        .frame(width: size.width * 2.5, height: size.height * 2.5) // Much larger to prevent edge clipping
    }
}

#Preview {
    NoiseOverlayView()
        .frame(width: 400, height: 300)
        .preferredColorScheme(.dark) // Preview on dark
}
