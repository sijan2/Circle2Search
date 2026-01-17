// LensientShader.metal - Android Circle to Search shimmer effect
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
    float baseRadius;
    float trackingAmount;     // 0 = fullscreen shimmer, 1 = brush tip only
    float particleRadius;
    float saturation;         // 0 = monochrome, 1 = full color
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

// Gaussian blur circle
float blurryCircle(float2 pixelsToCenter, float radius) {
    float blur = 3.0;
    float dist2 = dot(pixelsToCenter, pixelsToCenter);
    return exp(-blur * dist2 / (radius * radius));
}

float4 blendOver(float4 dst, float4 src, float alpha) {
    float4 result;
    result.rgb = src.rgb * alpha + dst.rgb * (1.0 - alpha);
    result.a = alpha + dst.a * (1.0 - alpha);
    return result;
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
    float tracking = u.trackingAmount;
    
    // ============================================
    // MODE 1: FULLSCREEN SHIMMER (tracking = 0)
    // ============================================
    float4 fullscreenResult = float4(0.0);
    if (tracking < 0.99) {
        // Bloom effect on appear
        float bloomDuration = 0.8;
        float bloomT = clamp(t / bloomDuration, 0.0, 1.0);
        float bloomEase = 1.0 - pow(1.0 - bloomT, 2.0);
        
        // Ripple distortion
        float2 normUV = uv - 0.5;
        float dist = length(normUV);
        float ripple = sin(dist * 20.0 - t * 6.0) * exp(-dist * 2.5);
        float rippleFade = (1.0 - bloomEase) * 0.6;
        float2 rippleOffset = normalize(normUV + 0.001) * ripple * rippleFade * 40.0;
        float2 distortedPixel = pixel + rippleOffset;
        
        float baseR = u.baseRadius;
        float soft = baseR * 0.5;
        float wiggleAmp = baseR * 0.35;
        float2 screenCenter = u.resolution * 0.5;
        
        for (int i = 0; i < 8; i++) {
            float phase = float(i) * 0.785398;
            float wiggleX = androidWiggle(t * 0.5, phase, wiggleAmp);
            float wiggleY = androidWiggle(t * 0.5, phase + 1.57, wiggleAmp);
            float orbitAngle = phase + t * 0.15;
            float orbitR = baseR * 0.4;
            
            float2 offset = float2(cos(orbitAngle) * orbitR + wiggleX, sin(orbitAngle) * orbitR + wiggleY);
            float2 blobCenter = screenCenter + offset;
            float alpha = blurryCircle(distortedPixel - blobCenter, baseR);
            
            float3 col = getColor(u, i);
            col = col * col;
            fullscreenResult = blendOver(fullscreenResult, float4(col, 1.0), alpha * 0.7);
        }
        
        float bloomPulse = 1.0 + 0.3 * (1.0 - bloomEase);
        fullscreenResult.rgb = sqrt(fullscreenResult.rgb) * bloomPulse;
    }
    
    // ============================================
    // MODE 2: BRUSH TIP SHIMMER (tracking = 1)
    // Simple centered glow that stays exactly at brush tip
    // ============================================
    float4 tipResult = float4(0.0);
    if (tracking > 0.01) {
        float tipRadius = u.particleRadius;
        
        // Single centered glow - NO offset, stays at exact pointer position
        float dist = length(pixel - center);
        float glow = exp(-3.0 * dist * dist / (tipRadius * tipRadius));
        
        // Slow, natural color cycling through Google colors
        float colorPhase = t * 0.3;  // Very slow - takes ~3 seconds per color
        int colorIdx = int(colorPhase) % 5;
        float colorBlend = fract(colorPhase);
        float3 col1 = getColor(u, colorIdx);
        float3 col2 = getColor(u, (colorIdx + 1) % 5);
        float3 tipColor = mix(col1, col2, colorBlend);
        
        // Boost brightness
        tipColor = tipColor * tipColor;  // Gamma
        tipColor = sqrt(tipColor) * 1.3;
        
        tipResult = float4(tipColor, 1.0) * glow;
    }
    
    // ============================================
    // BLEND: Fullscreen fades, tip shows
    // ============================================
    float fullscreenFade = pow(1.0 - tracking, 2.0);
    float4 result = fullscreenResult * fullscreenFade + tipResult;
    
    // Apply desaturation (saturation: 0 = grayscale, 1 = full color)
    float gray = dot(result.rgb, float3(0.299, 0.587, 0.114));
    result.rgb = mix(float3(gray), result.rgb, u.saturation);
    
    result *= u.opacity;
    
    return result;
}
