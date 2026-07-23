#include <metal_stdlib>
using namespace metal;

struct VertexOut {
  float4 position [[position]];
  float2 texcoord;
};

vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
  const float2 positions[3] = {
    float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)
  };
  const float2 texcoords[3] = {
    float2(0.0, 0.0), float2(2.0, 0.0), float2(0.0, 2.0)
  };
  VertexOut out;
  out.position = float4(positions[vertexID], 0.0, 1.0);
  out.texcoord = texcoords[vertexID];
  return out;
}

vertex VertexOut vertex_main_flip_y(uint vertexID [[vertex_id]]) {
  const float2 positions[3] = {
    float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)
  };
  const float2 texcoords[3] = {
    float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0)
  };
  VertexOut out;
  out.position = float4(positions[vertexID], 0.0, 1.0);
  out.texcoord = texcoords[vertexID];
  return out;
}

fragment float4 fragment_main(
    VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]]) {
  constexpr sampler sourceSampler(address::clamp_to_edge, filter::nearest);
  const float4 color = source.sample(sourceSampler, in.texcoord);
  return float4(color.rgb, 1.0);
}
