// Filename: Spotlight.metal
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Structure for vertex data
struct VertexData {
    float2 texCoord;
};

// Structure for uniforms
struct SpotlightUniforms {
    float time;            // Current time
    float2 resolution;     // View dimensions (used implicitly by uv)
    float spotlightHeight; // No longer used by this shader
    float spotlightSpeed;  // No longer used by this shader
    float4 lightModeTint;  // RGBA tint for light mode (can be used for subtle base)
    float4 darkModeTint;   // RGBA tint for dark mode (can be used for subtle base)
    uint isDarkMode;       // Flag indicating color scheme
    float spotlightBrightness;// No longer used by this shader
    float topInset;        // Normalized status bar inset (0.0 to 1.0)
};

fragment float4 spotlight_fragment(VertexData in [[stage_in]],
                                   float4 screenPosition [[position]],
                                   texture2d<float> noiseTexture [[texture(0)]],
                                   constant SpotlightUniforms &uniforms [[buffer(0)]])
{
    float2 uv = in.texCoord; // Normalized coordinates (0.0 to 1.0)

    // Early exit for pixels within the status bar area
    if (uv.y < uniforms.topInset) {
        return float4(0.0, 0.0, 0.0, 0.0); // Fully transparent
    }

    // Remap uv.y for the visible screen area (below status bar)
    // effective_uv_y goes from 0 (at status bar bottom) to 1 (at screen bottom)
    float effective_uv_y = (uv.y - uniforms.topInset) / (1.0 - uniforms.topInset);

    // Parameters for the rounded rectangle stroke
    float cornerRadius = 0.02f;
    float glowBandThickness = 0.03f;
    float g_half_band_norm = glowBandThickness / 2.0f; // Half band thickness in normalized [0,1] space

    // Remap effective_uv_y to p_y for SDF calculation.
    // The range [g_half_band_norm, 1.0 - g_half_band_norm] in effective_uv_y
    // should map to the SDF's core vertical extent [-0.5, 0.5] for p_y.
    // This ensures the glow band is fully contained within the visible area.
    float p_y_numerator = effective_uv_y - g_half_band_norm;
    float bottomPadding = 0.010f; // Adjust this for more/less bottom extension
    float p_y_denominator = (1.0f + bottomPadding) - 2.0f * g_half_band_norm;
    
    // Avoid division by zero or near-zero if glowBandThickness is too large (e.g., >= 1.0)
    float p_y;
    if (p_y_denominator <= 0.0001f) { // Effectively if glowBandThickness >= 1.0
        p_y = 0.0f; // Collapse to center, will likely result in full screen glow or no glow based on SDF
    } else {
        p_y = (p_y_numerator / p_y_denominator) - 0.5f;
    }

    float2 p = float2(uv.x - 0.5f, p_y);

    // SDF for a rounded rectangle boundary
    float2 b_half_dims_no_radius = float2(0.5f, 0.5f);
    float2 q = abs(p) - (b_half_dims_no_radius - cornerRadius);
    float dist_sdf = length(max(q, float2(0.0f))) - cornerRadius;

    // Calculate intensity for a stroke effect based on the SDF
    float intensity = 1.0f - smoothstep(0.0f, g_half_band_norm, abs(dist_sdf));

    // Apply power curve for falloff control within the band
    intensity = pow(intensity, 1.3f);
    
    // Animate color with time
    float time = uniforms.time * 0.3f; // Slower animation
    float3 color;
    color.r = 0.5f + 0.5f * sin(time);
    color.g = 0.5f + 0.5f * sin(time + 2.094f); // Pi * 2/3
    color.b = 0.5f + 0.5f * sin(time + 4.188f); // Pi * 4/3

    return float4(color * intensity, intensity);
}
