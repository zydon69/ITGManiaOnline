#include <metal_stdlib>
using namespace metal;

struct VertexIn {
  packed_float4 position;
  packed_float2 texcoord;
  packed_float2 textureMatrixScale;
  packed_float4 color;
};

struct TransformUniforms {
  float4x4 modelViewProjection;
  float4x4 textureMatrix;
  float zBias;
  float3 padding;
};

struct VertexOut {
  float4 position [[position]];
  float2 texcoord;
  float4 color;
};

vertex VertexOut solid_vertex(
    const device VertexIn* vertices [[buffer(0)]],
    constant TransformUniforms& transform [[buffer(1)]],
    uint vertexID [[vertex_id]]) {
  const VertexIn in = vertices[vertexID];
  float4 position = transform.modelViewProjection * float4(
      in.position.x, in.position.y, in.position.z, in.position.w);
  if (position.w != 0.0) {
    const float nearDepth = mix(0.05, 0.0, transform.zBias);
    const float farDepth = mix(1.0, 0.95, transform.zBias);
    const float normalizedDepth = clamp(
        (position.z / position.w) * 0.5 + 0.5, 0.0, 1.0);
    position.z = mix(nearDepth, farDepth, normalizedDepth) * position.w;
  }

  const float2 texcoord = float2(in.texcoord.x, in.texcoord.y);
  const float4 transformedTexcoord =
      transform.textureMatrix * float4(texcoord.x, texcoord.y, 0.0, 1.0);
  const float2 textureMatrixScale =
      float2(in.textureMatrixScale.x, in.textureMatrixScale.y);

  VertexOut out;
  out.position = position;
  out.texcoord = transformedTexcoord.xy * textureMatrixScale +
                 texcoord * (1.0 - textureMatrixScale);
  out.color = in.color;
  return out;
}

float4 blend_compose(float4 over, float4 under, float fill, uint effectMode) {
  float3 neutral = float3(0.5, 0.5, 0.5);
  if (effectMode == 2) {
    neutral = float3(1.0, 1.0, 1.0);
  }
  if (effectMode == 3) {
    neutral = float3(0.0, 0.0, 0.0);
  }
  over.rgb = mix(neutral, over.rgb, fill);

  float4 ret;
  if (effectMode == 2) {
    ret.rgb = clamp(
        (over.rgb + under.rgb - 1.0) / max(over.rgb, float3(0.000001)),
        0.0, 1.0);
    ret.rgb *= over.a * under.a;
  } else if (effectMode == 3) {
    ret.rgb = min(
        under.rgb / max(1.0 - over.rgb, float3(0.000001)), 1.0);
    ret.rgb *= over.a * under.a;
  } else if (effectMode == 4 || effectMode == 5) {
    float3 vividOver = (over.rgb - 0.5) * 2.0;
    ret.rgb = under.rgb + min(vividOver, 0.0);
    ret.rgb /= max(1.0 - abs(vividOver), float3(0.000001));
    ret.rgb *= under.a;
    ret = clamp(ret, 0.0, 1.0);
    ret.rgb *= over.a;
  } else if (effectMode == 6) {
    ret.rgb = min(under.rgb * over.rgb * 2.0, 1.0);
    ret.rgb *= over.a * under.a;
  } else {
    ret.rgb = min(1.0 - ((1.0 - under.rgb) * (1.0 - over.rgb)), 1.0);
    ret.rgb *= over.a * under.a;
  }

  ret.a = over.a * under.a;
  if (effectMode == 5 && ret.a > 0.0) {
    ret.rgb /= ret.a;
    fill *= fill;
    const float low = 0.5 - (1.0 - fill) * 0.5;
    const float high = 0.5 + (1.0 - fill) * 0.5 + 0.00001;
    ret.rgb = clamp((ret.rgb - low) / (high - low), 0.0, 1.0);
    ret.rgb *= ret.a;
  }

  ret.rgb += (1.0 - over.a) * under.rgb * under.a;
  ret.a += (1.0 - over.a) * under.a;

  over.a *= fill;
  ret.rgb += (1.0 - under.a) * over.rgb * over.a;
  ret.a += (1.0 - under.a) * over.a;

  if (ret.a > 0.0) {
    ret.rgb /= ret.a;
  }
  return ret;
}

fragment float4 solid_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    texture2d<float> source2 [[texture(1)]],
    sampler sourceSampler [[sampler(0)]],
    constant uint& textureMode [[buffer(1)]],
    constant uint& alphaTest [[buffer(2)]],
    constant uint& celStage [[buffer(3)]],
    constant uint& effectMode [[buffer(4)]],
    constant uint& textureWidth [[buffer(5)]]) {
  if (celStage == 1) {
    return float4(0.25, 0.125, 0.125, 1.0);
  }

  const float4 sampleColor = source.sample(sourceSampler, in.texcoord);
  if (alphaTest != 0 && sampleColor.a <= 0.00390625) {
    discard_fragment();
  }

  if (effectMode == 1) {
    if (sampleColor.a == 0.0) {
      return sampleColor;
    }
    return float4(sampleColor.rgb / sampleColor.a, sampleColor.a) * in.color;
  }

  if (effectMode >= 2 && effectMode <= 7) {
    const float4 over = source2.sample(sourceSampler, in.texcoord);
    return blend_compose(over, sampleColor, in.color.a, effectMode);
  }

  if (effectMode == 8) {
    float fU = in.texcoord.x * float(textureWidth) * 2.0 - 0.5;
    const float fOdd = fmod(fU + 0.0001, 2.0);
    fU -= fOdd;
    fU = (fU + 0.5) / 2.0 / float(textureWidth);
    const float4 yuyv = source.sample(sourceSampler, float2(fU, in.texcoord.y));
    float3 yuv = fOdd <= 0.5 ? yuyv.rga : yuyv.bga;
    yuv -= float3(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0);
    return float4(
        dot(yuv, float3(1.1643, 0.0000, 1.5958)),
        dot(yuv, float3(1.1643, -0.39173, -0.81290)),
        dot(yuv, float3(1.1643, 2.0170, 0.0000)),
        1.0) * in.color;
  }

  if (textureMode == 1) {
    return float4(in.color.rgb, sampleColor.a * in.color.a);
  }
  if (textureMode == 2) {
    return float4(
        saturate(sampleColor.rgb + in.color.rgb), sampleColor.a * in.color.a);
  }
  return sampleColor * in.color;
}

float sdf_median_rgb(float r, float g, float b) {
  return max(min(r, g), min(max(r, g), b));
}

fragment float4 distance_field_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    texture2d<float> source2 [[texture(1)]],
    sampler sourceSampler [[sampler(0)]],
    constant uint& textureMode [[buffer(1)]],
    constant uint& alphaTest [[buffer(2)]],
    constant uint& celStage [[buffer(3)]],
    constant uint& effectMode [[buffer(4)]],
    constant uint& textureWidth [[buffer(5)]]) {
  const float4 sampleColor = source.sample(sourceSampler, in.texcoord);
  const float dist = sdf_median_rgb(
      sampleColor.r, sampleColor.g, sampleColor.b);
  const float afwidth = 0.75 * length(float2(dfdx(dist), dfdy(dist)));
  const float coverage = smoothstep(0.5 - afwidth, 0.5 + afwidth, dist);
  if (alphaTest != 0 && coverage <= 0.00390625) {
    discard_fragment();
  }
  if (textureMode == 2) {
    return saturate(float4(in.color.rgb, in.color.a * coverage) + in.color);
  }
  return float4(in.color.rgb, in.color.a * coverage);
}
