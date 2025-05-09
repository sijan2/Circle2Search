import SwiftUI

struct GlowingBorderView: View {
    // Configuration parameters
    var cornerRadius: CGFloat
    var strokeWidth: CGFloat
    var animationDuration: Double
    var glowIntensity: Double
    
    // Animation state
    @State private var rotation: Double = 0
    
    // Default initializer with customizable parameters
    init(
        cornerRadius: CGFloat = 16,
        strokeWidth: CGFloat = 2,
        animationDuration: Double = 5,
        glowIntensity: Double = 1.0
    ) {
        self.cornerRadius = cornerRadius
        self.strokeWidth = strokeWidth
        self.animationDuration = animationDuration
        self.glowIntensity = glowIntensity
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Glow layer 3 (most diffuse)
                createGradientBorder(for: geometry.size)
                    .blur(radius: 16 * glowIntensity)
                    .opacity(0.6 * glowIntensity)
                
                // Glow layer 2 (medium diffuse)
                createGradientBorder(for: geometry.size)
                    .blur(radius: 12 * glowIntensity)
                    .opacity(0.7 * glowIntensity)
                
                // Glow layer 1 (least diffuse)
                createGradientBorder(for: geometry.size)
                    .blur(radius: 8 * glowIntensity)
                    .opacity(0.8 * glowIntensity)
                
                // Base sharp layer
                createGradientBorder(for: geometry.size)
                    .blur(radius: 0.5) // Very slight blur for anti-aliasing
                
                // Specular highlight (optional)
                createGradientBorder(for: geometry.size, isSpecular: true)
                    .blur(radius: 0.3)
                    .opacity(0.7)
            }
            .mask(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(lineWidth: strokeWidth)
            )
        }
        .onAppear {
            withAnimation(.linear(duration: animationDuration).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
    
    // Helper function to create the gradient border
    private func createGradientBorder(for size: CGSize, isSpecular: Bool = false) -> some View {
        let colors: [Color] = isSpecular ? 
            [.white.opacity(0.6), .white.opacity(0.3), .white.opacity(0.6)] :
            [
                .purple,
                .yellow,
                .red,
                .pink,
                .cyan,
                .blue,
                .purple
            ]
        
        return AngularGradient(
            gradient: Gradient(colors: colors),
            center: .center,
            angle: .degrees(rotation)
        )
        .frame(width: size.width * 1.5, height: size.height * 1.5) // Larger than the view to ensure full coverage
    }
}

// This view combines the glowing border with the noise overlay
struct GlowingNoiseOverlayView: View {
    // Configuration
    var cornerRadius: CGFloat = 16
    var borderWidth: CGFloat = 2
    var borderGlowIntensity: Double = 1.0
    
    var body: some View {
        ZStack {
            // Noise overlay
            NoiseOverlayView()
            
            // Glowing border
            GlowingBorderView(
                cornerRadius: cornerRadius,
                strokeWidth: borderWidth,
                animationDuration: 5,
                glowIntensity: borderGlowIntensity
            )
        }
    }
}

#Preview {
    VStack {
        GlowingBorderView()
            .frame(width: 300, height: 200)
        
        GlowingNoiseOverlayView()
            .frame(width: 300, height: 200)
    }
    .padding(40)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
