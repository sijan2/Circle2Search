#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// --- Vertex Shader and Struct ---

struct VertexData {
    float4 position [[position]]; // Output position for the GPU
    float2 texCoord;              // Output texture coordinate
};

// This function takes vertex data from Swift and outputs position/texCoord
vertex VertexData vertex_passthrough(uint vertexID [[vertex_id]],
                                     // buffer(0) matches the setVertexBuffer index in Swift
                                     constant float* vertex_array [[buffer(0)]])
{
    VertexData out;
    uint index = vertexID * 4; // Each vertex has x, y, u, v (4 floats)
    out.position = float4(vertex_array[index], vertex_array[index+1], 0.0, 1.0);
    out.texCoord = float2(vertex_array[index+2], vertex_array[index+3]);
    return out;
}

// --- Noise Fragment Shader and Helpers ---

// Simple hash function for procedural noise
float hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.13);
    p3 += dot(p3, p3.yzx + 3.333);
    return fract((p3.x + p3.y) * p3.z);
}

// Value noise function
float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f); // Smoothstep

    float bottom_left = hash(i + float2(0.0, 0.0));
    float bottom_right = hash(i + float2(1.0, 0.0));
    float top_left = hash(i + float2(0.0, 1.0));
    float top_right = hash(i + float2(1.0, 1.0));

    return mix(mix(bottom_left, bottom_right, f.x),
               mix(top_left, top_right, f.x),
               f.y);
}

// Structure for uniforms passed from Swift (must match Swift struct)
struct NoiseUniforms {
    float time;
    float2 resolution;
    float noiseScale;
    float pulseFrequency;
    float pulseAmplitude;
    float scrollSpeed;
};

// This is the main function for generating the noise pattern
fragment float4 noise_fragment(VertexData in [[stage_in]], // Receives output from vertex shader
                               constant NoiseUniforms &uniforms [[buffer(0)]]) // buffer(0) matches Swift setFragmentBuffer index
{
    // Use texture coordinates passed from vertex shader
    float2 uv = in.texCoord;

    // Adjust UV for vertical scrolling based on time
    float scrollOffset = fmod(uniforms.time * uniforms.scrollSpeed / uniforms.resolution.y, 1.0);
    float2 noiseUV = float2(uv.x, uv.y + scrollOffset) * uniforms.noiseScale;

    // Generate base noise value
    float noiseValue = noise(noiseUV);

    // Apply pulsing effect using sine wave based on time
    // M_PI_F requires `#include <metal_math>` or ensure it's available. Usually is.
    float pulseFactor = 1.0 + sin(uniforms.time * uniforms.pulseFrequency * M_PI_F * 2.0) * uniforms.pulseAmplitude;

    // Modulate noise intensity with pulse
    noiseValue *= pulseFactor;

    // Ensure noiseValue stays positive
    noiseValue = max(0.0, noiseValue);

    // Output grayscale noise (alpha = 1.0)
    // Spotlight pass will handle final color and alpha blending
    return float4(float3(noiseValue), 1.0);
}
