// LensientShader.metal - Fullscreen shimmer effect
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

float softCircle(float2 p, float r, float soft) {
    return 1.0 - smoothstep(r - soft, r + soft, length(p));
}

float4 blendOver(float4 dst, float4 src) {
    return src + (1.0 - src.a) * dst;
}

vertex VertexOut shimmer_vertex(uint vid [[vertex_id]],
                                 constant float* verts [[buffer(0)]]) {
    VertexOut out;
    uint i = vid * 4;
    out.position = float4(verts[i], verts[i+1], 0, 1);
    out.uv = float2(verts[i+2], verts[i+3]);
    return out;
}

fragment float4 shimmer_fragment(VertexOut in [[stage_in]],
                                  constant ShimmerUniforms &u [[buffer(0)]]) {
    if (u.opacity < 0.01) {
        return float4(0.0);
    }
    
    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    float2 pixel = uv * u.resolution;
    float2 center = float2(u.centerX, u.centerY);
    
    float t = u.time;
    float4 result = float4(0.0);
    
    float baseR = u.radius;
    float soft = baseR * 0.7;
    
    for (int i = 0; i < 8; i++) {
        float angle = float(i) * 0.785398 + t * 0.4;
        float orbitR = baseR * 0.35;
        
        float phase = float(i) * 1.57;
        float wiggleX = sin(t * 1.1 + phase) * baseR * 0.2;
        float wiggleY = cos(t * 0.8 + phase * 0.7) * baseR * 0.2;
        
        float2 offset = float2(
            cos(angle) * orbitR + wiggleX,
            sin(angle) * orbitR + wiggleY
        );
        
        float2 blobCenter = center + offset;
        float alpha = softCircle(pixel - blobCenter, baseR, soft);
        
        float3 col = getColor(u, i);
        float3 colSq = col * col;
        
        result = blendOver(result, alpha * float4(colSq, 1.0));
    }
    
    result.rgb = sqrt(result.rgb);
    result *= u.opacity;
    
    return result;
}
