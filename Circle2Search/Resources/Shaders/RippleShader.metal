#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

[[stitchable]] half4 Ripple(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float time
) {
    float2 uv = position / size;
    float2 center = float2(0.5, 0.5);
    
    // Gentle organic displacement - like breathing/pulsing
    float t = time;
    
    // Soft sine waves at different scales for organic feel
    float wave1 = sin(uv.x * 3.0 + t * 2.0) * sin(uv.y * 2.5 + t * 1.8);
    float wave2 = sin(uv.x * 5.0 - t * 1.5) * sin(uv.y * 4.0 + t * 2.2);
    float wave3 = sin((uv.x + uv.y) * 2.0 + t * 1.2);
    
    // Combine waves with decreasing amplitude over time
    float decay = exp(-t * 1.5);
    float displacement = (wave1 * 0.5 + wave2 * 0.3 + wave3 * 0.2) * decay;
    
    // Very gentle displacement amount
    float strength = 6.0 * decay;
    
    // Displacement flows smoothly across surface
    float2 offset = float2(
        displacement * strength,
        displacement * strength * 0.8
    );
    
    float2 newPosition = position + offset;
    half4 color = layer.sample(newPosition);
    
    return color;
}
