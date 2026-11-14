// Dithered glyph-ramp planet, a port of the Orbit site's glyph passes; everything runs per cell and nothing outside the disc glows except sparse twinkling stars.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace glyphplanet {

constant int kRampCount = 16;
constant float kPitch = -0.22;

// Ramp ordered by ink weight: " '.~:+ixo%*80#B@"; each glyph is 5 columns by 7 rows, one byte per row, bit 4 leftmost.
constant uchar kGlyphRows[112] = {
    0, 0, 0, 0, 0, 0, 0,
    0b00100, 0b00100, 0b01000, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0b01100, 0b01100,
    0, 0, 0b01000, 0b10101, 0b00010, 0, 0,
    0, 0b01100, 0b01100, 0, 0b01100, 0b01100, 0,
    0, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0,
    0b00100, 0, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110,
    0, 0, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001,
    0, 0, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110,
    0b11001, 0b11010, 0b00010, 0b00100, 0b01000, 0b01011, 0b10011,
    0, 0b10101, 0b01110, 0b11111, 0b01110, 0b10101, 0,
    0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110,
    0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110,
    0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010,
    0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110,
    0b01110, 0b10001, 0b10111, 0b10101, 0b10111, 0b10000, 0b01110
};

static float hash2(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

static float hash3(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float noise3(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(
        mix(mix(hash3(i), hash3(i + float3(1, 0, 0)), f.x),
            mix(hash3(i + float3(0, 1, 0)), hash3(i + float3(1, 1, 0)), f.x), f.y),
        mix(mix(hash3(i + float3(0, 0, 1)), hash3(i + float3(1, 0, 1)), f.x),
            mix(hash3(i + float3(0, 1, 1)), hash3(i + float3(1, 1, 1)), f.x), f.y),
        f.z);
}

static float bandField(float3 q, float time, float bandCount) {
    float shear = 0.9 * sin(time * 0.021) * (1.0 - 1.4 * q.y * q.y);
    float c = cos(shear);
    float s = sin(shear);
    float3 r = float3(c * q.x + s * q.z, q.y, -s * q.x + c * q.z);
    float3 w = r * 2.1 + float3(0.0, 0.0, time * 0.03);
    float warp = (noise3(w) - 0.5) * 1.6 + (noise3(w * 2.3 + 7.1) - 0.5) * 0.8;
    float lat = asin(clamp(r.y + warp * 0.05, -1.0, 1.0));
    float broad = 0.5 + 0.5 * sin(lat * bandCount + warp * 2.4);
    float fine = 0.5 + 0.5 * sin(lat * bandCount * 2.6 + 1.7 + warp * 1.6);
    float grain = noise3(r * 9.0 + float3(time * 0.05, 0.0, 0.0));
    return clamp(0.58 * broad + 0.27 * fine + 0.15 * grain, 0.0, 1.0);
}

static float glyphCoverage(int level, float2 local) {
    // The cell is 6 by 9 bitmap pixels: the glyph sits in columns 0 to 4 and rows 1 to 7, leaving a gap column and leading rows.
    int gx = int(floor(local.x * 6.0));
    int gy = int(floor(local.y * 9.0)) - 1;
    if (gx < 0 || gx > 4 || gy < 0 || gy > 6) { return 0.0; }
    uchar bits = kGlyphRows[level * 7 + gy];
    return float((bits >> (4 - gx)) & 1);
}

static float3 labToLinear(float3 lab) {
    float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    l = l * l * l;
    m = m * m * m;
    s = s * s * s;
    return max(float3(
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    ), 0.0);
}

static float3 encodeSRGB(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c > 0.0031308);
}

static float3 ramp(float t, float3 labNight, float3 labLit) {
    float3 deep = float3(labNight.x * 0.5, labNight.yz * 0.9);
    float3 white = float3(min(labLit.x * 1.06 + 0.04, 0.99), labLit.yz * 0.3);
    float3 lab = t < 0.4 ? mix(deep, labNight, smoothstep(0.0, 0.4, t))
        : t < 0.82 ? mix(labNight, labLit, smoothstep(0.4, 0.82, t))
        : mix(labLit, white, smoothstep(0.82, 1.0, t));
    return encodeSRGB(labToLinear(lab));
}

}

// Applied with colorEffect over an opaque stage-background rectangle, so the incoming colour is the paper (light) or night (dark) glyphs composite onto.
[[ stitchable ]] half4 glyphPlanet(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float spinRate,
    float tilt,
    float bands,
    float fill,
    float cellScale,
    float ink,
    float3 labNight,
    float3 labLit
) {
    using namespace glyphplanet;

    float3 background = float3(color.rgb);
    float2 cell = float2(6.0, 9.0) * cellScale;
    float2 grid = position / cell;
    float2 cellId = floor(grid);
    float2 local = grid - cellId;
    float2 center = (cellId + 0.5) * cell;

    float2 mid = size * 0.5;
    float radius = min(size.x, size.y) * 0.365;
    float2 d = float2(center.x - mid.x, mid.y - center.y) / radius;
    float r2 = dot(d, d);

    if (r2 >= 1.0) {
        float pick = hash2(cellId * float2(3.1, 1.7));
        if (pick < 0.991) { return half4(half3(background), 1.0h); }
        float twinkle = 0.5 + 0.5 * sin(time * 1.3 + hash2(cellId + 7.0) * 6.2831853);
        int level = hash2(cellId) > 0.5 ? 2 : 5;
        float cover = glyphCoverage(level, local);
        float3 star = ink > 0.5 ? float3(0.33, 0.34, 0.42) : float3(0.78, 0.79, 0.88);
        float alpha = cover * (0.22 + 0.4 * twinkle);
        return half4(half3(mix(background, star, alpha)), 1.0h);
    }

    // Body-space point: undo lean, pitch and spin so bands and noise rotate with the planet.
    float3 n = float3(d, sqrt(1.0 - r2));
    float lc = cos(tilt);
    float ls = sin(tilt);
    float3 q = float3(lc * n.x + ls * n.y, -ls * n.x + lc * n.y, n.z);
    float pc = cos(kPitch);
    float ps = sin(kPitch);
    q = float3(q.x, pc * q.y + ps * q.z, -ps * q.y + pc * q.z);
    float angle = time * spinRate + 0.4;
    float sc = cos(angle);
    float ss = sin(angle);
    q = float3(sc * q.x - ss * q.z, q.y, ss * q.x + sc * q.z);

    float albedo = clamp((bandField(q, time, bands) - 0.5) * 1.9 + 0.5, 0.0, 1.0);

    // Light from the upper left, a little toward the viewer; a wide smoothstep softens the terminator so the night side fades.
    float3 light = normalize(float3(-0.7071, 0.7071, 0.33));
    float lit = smoothstep(-0.55, 0.9, dot(n, light));
    float2 lightFlat = normalize(light.xy + float2(1e-4));
    float behind = smoothstep(-0.2, 0.7, -light.z);
    float toward = dot(normalize(d + float2(1e-5)), lightFlat);
    float scatter = pow(1.0 - n.z, 4.0) * smoothstep(-0.35, 1.0, toward) * (0.35 + 0.65 * behind);
    const float ambient = 0.16;
    const float rim = 0.7;
    float value = mix(0.2, 1.0, albedo) * (ambient + (1.0 - ambient) * lit) + rim * scatter;
    float tone = value + (albedo - 0.5) * 0.14;

    float dither = hash2(cellId) - 0.5;
    float ditherAmount = 0.14 / sqrt(max(float(kRampCount) / 10.0, 1.0));
    float dithered = clamp(value + dither * ditherAmount * step(0.02, value), 0.0, 1.0);

    // Sweep reveal runs clockwise from the lit upper-left; the unrevealed part keeps about a quarter of its density rather than going dark.
    float sweep = fract(atan2(d.x, d.y) / (2.0 * M_PI_F) + 0.125);
    float revealed = fill >= 1.0 ? 1.0 : 1.0 - smoothstep(fill - 0.04, fill, sweep);
    dithered *= mix(0.25, 1.0, revealed);
    dithered = max(dithered, 0.07);

    float gamma = 1.08;
    float shaped = pow(dithered, gamma);
    int level = int(floor(shaped * float(kRampCount - 1) + 0.5));
    if (level < 1) { return half4(half3(background), 1.0h); }

    float cover = glyphCoverage(level, local);
    float3 glyph = ramp(clamp(tone, 0.0, 1.0), labNight, labLit);
    float energy = cover * (0.2 + 0.95 * shaped) * mix(1.0, 0.75, smoothstep(0.7, 1.0, shaped));
    return half4(half3(mix(background, glyph, clamp(energy, 0.0, 1.0))), 1.0h);
}
