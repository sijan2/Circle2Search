// LensientShader.metal - Fullscreen shimmer with fluid bloom ripple
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct ShimmerUniforms {
    float2 resolution;
    float time;
    float opacity;
    float centerX;
    float centerY;
    float radius;
    float padding1;
    float padding2;
    float4 color0;
    float4 color1;
    float4 color2;
    float4 color3;
    float4 color4;
    float4 color5;
    float4 color6;
    float4 color7;
};

float3 getColor(constant ShimmerUniforms &u, int i) {
    switch(i) {
        case 0: return u.color0.rgb;
        case 1: return u.color1.rgb;
        case 2: return u.color2.rgb;
        case 3: return u.color3.rgb;
        case 4: return u.color4.rgb;
        case 5: return u.color5.rgb;
        case 6: return u.color6.rgb;
        default: return u.color7.rgb;
    }
}

float androidWiggle(float t, float phase, float amp) {
    float wave1 = 0.53 * sin(1.0 * t + phase);
    float wave2 = 0.25 * sin(2.0 * t + phase * 1.3);
    float wave3 = 0.12 * sin(3.0 * t + phase * 0.7);
    return amp * (wave1 + wave2 + wave3);
}

float softCircle(float2 p, float r, float soft) {
    return 1.0 - smoothstep(r - soft, r + soft, length(p));
}

float4 blendOver(float4 dst, float4 src) {
    return src + (1.0 - src.a) * dst;
}

vertex VertexOut shimmer_vertex(uint vid [[vertex_id]], constant float* verts [[buffer(0)]]) {
    VertexOut out;
    uint i = vid * 4;
    out.position = float4(verts[i], verts[i+1], 0, 1);
    out.uv = float2(verts[i+2], verts[i+3]);
    return out;
}

fragment float4 shimmer_fragment(VertexOut in [[stage_in]], constant ShimmerUniforms &u [[buffer(0)]]) {
    if (u.opacity < 0.01) return float4(0.0);
    
    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    float2 pixel = uv * u.resolution;
    float2 center = float2(u.centerX, u.centerY);
    float t = u.time;
    
    // Fluid bloom ripple - multiple waves from edges blooming inward/outward
    float bloomDuration = 0.8;
    float bloomT = min(t, bloomDuration) / bloomDuration;
    float bloomEase = 1.0 - pow(1.0 - bloomT, 2.0); // Ease out quad
    
    // Ripple distortion - waves emanating everywhere like water
    float2 normUV = uv - 0.5;
    float dist = length(normUV);
    
    // Multiple ripple waves at different phases (flower petal feel)
    float ripple1 = sin(dist * 25.0 - t * 8.0) * exp(-dist * 3.0);
    float ripple2 = sin(dist * 18.0 - t * 6.0 + 1.0) * exp(-dist * 2.5);
    float ripple3 = sin(dist * 12.0 - t * 4.0 + 2.0) * exp(-dist * 2.0);
    
    // Bloom fade - ripples are strong at start, settle down
    float rippleFade = (1.0 - bloomEase) * 0.8;
    float rippleStrength = (ripple1 + ripple2 * 0.7 + ripple3 * 0.5) * rippleFade;
    
    // Apply fluid distortion to pixel position
    float2 rippleDir = normalize(normUV + 0.001);
    float2 distortedPixel = pixel + rippleDir * rippleStrength * 60.0;
    
    // Shimmer blobs with distorted positions
    float4 result = float4(0.0);
    float baseR = u.radius;
    float soft = baseR * 0.5;
    float wiggleAmp = baseR * 0.35; // Increased for more spread
    
    for (int i = 0; i < 8; i++) {
        float phase = float(i) * 0.785398;
        float wiggleX = androidWiggle(t * 0.5, phase, wiggleAmp); // Original speed
        float wiggleY = androidWiggle(t * 0.5, phase + 1.57, wiggleAmp);
        float orbitAngle = phase + t * 0.15; // Original speed
        float orbitR = baseR * 0.4; // Larger orbit for more spread
        
        float2 offset = float2(cos(orbitAngle) * orbitR + wiggleX, sin(orbitAngle) * orbitR + wiggleY);
        float2 blobCenter = center + offset;
        float alpha = softCircle(distortedPixel - blobCenter, baseR, soft);
        
        float3 col = getColor(u, i);
        result = blendOver(result, alpha * float4(col * col, 1.0));
    }
    
    // Bloom brightness pulse
    float bloomPulse = 1.0 + 0.4 * (1.0 - bloomEase);
    
    result.rgb = sqrt(result.rgb) * bloomPulse;
    result *= u.opacity;
    
    return result;
}
