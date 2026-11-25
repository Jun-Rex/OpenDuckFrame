#include <metal_stdlib>
using namespace metal;

static float spLanczos(float x) {
    const float radius = 3.0;
    if (x == 0.0) return 1.0;
    if (x <= -radius || x >= radius) return 0.0;
    float pix = x * M_PI_F;
    return radius * sin(pix) * sin(pix / radius) / (pix * pix);
}

kernel void spLanczosHorizontal(texture2d<float, access::read> src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float center = ((float)gid.x + 0.5) * (float)src.get_width() / (float)dst.get_width() - 0.5;
    int base = (int)floor(center) - 2;
    float4 acc = float4(0);
    float weight = 0;
    for (int i = 0; i < 6; ++i) {
        int x = clamp(base + i, 0, (int)src.get_width() - 1);
        float w = spLanczos(center - float(base + i));
        acc += src.read(uint2((uint)x, gid.y)) * w;
        weight += w;
    }
    dst.write(weight != 0.0 ? acc / weight : float4(0), gid);
}

kernel void spLanczosVertical(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float center = ((float)gid.y + 0.5) * (float)src.get_height() / (float)dst.get_height() - 0.5;
    int base = (int)floor(center) - 2;
    float4 acc = float4(0);
    float weight = 0;
    for (int i = 0; i < 6; ++i) {
        int y = clamp(base + i, 0, (int)src.get_height() - 1);
        float w = spLanczos(center - float(base + i));
        acc += src.read(uint2(gid.x, (uint)y)) * w;
        weight += w;
    }
    float4 color = weight != 0.0 ? acc / weight : float4(0);
    color.a = 1.0;
    dst.write(clamp(color, 0.0, 1.0), gid);
}

static float3 spAir709Pixel(texture2d<float, access::read> luma,
                          texture2d<float> chroma,
                          uint2 pixel, float2 chromaOffset) {
    constexpr sampler chromaLinear(filter::linear, address::clamp_to_edge);
    float y = (luma.read(pixel).r * 255.0 - 16.0) / 219.0;
    float2 uv = (float2(pixel) + chromaOffset) / float2(luma.get_width(), luma.get_height());
    float2 cbcr = (chroma.sample(chromaLinear, uv).rg * 255.0 - 128.0) / 224.0;
    float3 rgb = float3(y + 1.5748 * cbcr.y,
                       y - 0.1873242729 * cbcr.x - 0.4681242729 * cbcr.y,
                       y + 1.8556 * cbcr.x);
    // The reference first stores a full-resolution BGRA8 conversion. Preserve
    // that saturation and quantization before the six-tap reconstruction.
    return rint(clamp(rgb, 0.0, 1.0) * 255.0) / 255.0;
}

kernel void spAirNV12Lanczos(texture2d<float, access::read> luma [[texture(0)]],
                            texture2d<float> chroma [[texture(1)]],
                            texture2d<float, access::write> dst [[texture(2)]],
                            constant float2 &chromaOffset [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 center = (float2(gid) + 0.5) * float2(luma.get_width(), luma.get_height()) /
                    float2(dst.get_width(), dst.get_height()) - 0.5;
    int2 base = int2(floor(center)) - 2;
    float xWeights[6], yWeights[6];
    float sumX = 0.0, sumY = 0.0;
    for (int i = 0; i < 6; ++i) {
        xWeights[i] = spLanczos(center.x - float(base.x + i));
        yWeights[i] = spLanczos(center.y - float(base.y + i));
        sumX += xWeights[i]; sumY += yWeights[i];
    }
    float3 vertical = float3(0);
    for (int j = 0; j < 6; ++j) {
        int y = clamp(base.y + j, 0, int(luma.get_height()) - 1);
        float3 horizontal = float3(0);
        for (int i = 0; i < 6; ++i) {
            int x = clamp(base.x + i, 0, int(luma.get_width()) - 1);
            horizontal += spAir709Pixel(luma, chroma, uint2(x, y), chromaOffset) * xWeights[i];
        }
        // Match the existing horizontal pass's RGBA16Float intermediate.
        horizontal = float3(half3(sumX != 0.0 ? horizontal / sumX : float3(0)));
        vertical += horizontal * yWeights[j];
    }
    float3 rgb = sumY != 0.0 ? vertical / sumY : float3(0);
    dst.write(float4(clamp(rgb, 0.0, 1.0), 1.0), gid);
}

struct SPPresentVertex {
    float4 position [[position]];
    float2 uv;
};

vertex SPPresentVertex spPresentVertex(uint vid [[vertex_id]],
                                       constant float4 *quad [[buffer(0)]]) {
    SPPresentVertex out;
    out.position = float4(quad[vid].xy, 0.0, 1.0);
    out.uv = quad[vid].zw;
    return out;
}

fragment float4 spPresentFragment(SPPresentVertex in [[stage_in]],
                                  texture2d<float> image [[texture(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    return float4(image.sample(linear, in.uv).rgb, 1.0);
}

fragment float4 spAirPresentLanczos(SPPresentVertex in [[stage_in]],
                                   texture2d<float, access::read> image [[texture(0)]]) {
    float2 center = in.uv * float2(image.get_width(), image.get_height()) - 0.5;
    int2 base = int2(floor(center)) - 2;
    float xWeights[6], yWeights[6];
    float sumX = 0.0, sumY = 0.0;
    for (int i = 0; i < 6; ++i) {
        xWeights[i] = spLanczos(center.x - float(base.x + i));
        yWeights[i] = spLanczos(center.y - float(base.y + i));
        sumX += xWeights[i]; sumY += yWeights[i];
    }
    float3 vertical = float3(0);
    for (int j = 0; j < 6; ++j) {
        int y = clamp(base.y + j, 0, int(image.get_height()) - 1);
        float3 horizontal = float3(0);
        for (int i = 0; i < 6; ++i) {
            int x = clamp(base.x + i, 0, int(image.get_width()) - 1);
            horizontal += image.read(uint2(x, y)).rgb * xWeights[i];
        }
        horizontal = float3(half3(sumX != 0.0 ? horizontal / sumX : float3(0)));
        vertical += horizontal * yWeights[j];
    }
    float3 rgb = sumY != 0.0 ? vertical / sumY : float3(0);
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// One 16x16 threadgroup per tile. A tile whose two submitted source pictures
// are bit-identical takes the current source pixels; any other tile keeps the
// generated frame. See SPStaticTileRestorer.
kernel void spRestoreStaticTiles(texture2d<float, access::read> previous [[texture(0)]],
                                 texture2d<float, access::read> current [[texture(1)]],
                                 texture2d<float, access::read> generated [[texture(2)]],
                                 texture2d<float, access::write> output [[texture(3)]],
                                 device atomic_uint *staticTiles [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]],
                                 uint2 tid [[thread_position_in_threadgroup]],
                                 uint simdIndex [[simdgroup_index_in_threadgroup]],
                                 uint simdCount [[simdgroups_per_threadgroup]]) {
    threadgroup bool changedBySimd[32];
    const bool inside = gid.x < output.get_width() && gid.y < output.get_height();
    float4 now = float4(0);
    bool differs = false;
    if (inside) {
        now = current.read(gid);
        differs = any(previous.read(gid) != now);
    }
    const bool simdChanged = simd_any(differs);
    if (simd_is_first()) changedBySimd[simdIndex] = simdChanged;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    bool changed = false;
    for (uint i = 0; i < simdCount; ++i) changed = changed || changedBySimd[i];
    if (inside) output.write(changed ? generated.read(gid) : now, gid);
    if (!changed && tid.x == 0 && tid.y == 0) atomic_fetch_add_explicit(staticTiles, 1u, memory_order_relaxed);
}
