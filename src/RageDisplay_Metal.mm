/* RageDisplay_Metal - Native Metal renderer entry point. */

#include "RageDisplay_Metal.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <set>
#include <string>
#include <vector>

#include "DisplaySpec.h"
#include "ModelTypes.h"
#include "PerfDiagnostics.h"
#include "RageDisplay.h"
#include "RageLog.h"
#include "RageMath.h"
#include "RageTimer.h"
#include "RageSurface.h"
#include "RageSurfaceUtils.h"
#include "RageUtil.h"
#include "arch/LowLevelWindow/LowLevelWindow.h"
#include "arch/LowLevelWindow/MacOSMetalPresenter.h"
#include "global.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

// Presentation cadence must match the physical display.  Rendering faster than
// a fixed-refresh CAMetalLayer produces an uneven 6:5 cadence on a 120 Hz panel
// when the engine targets 144 Hz, which is perceived as micro-stutter even when
// neither the CPU nor GPU is saturated.
constexpr double kMetalDisplayPacingHeadroomFactor = 1.0;

static RageDisplay::RagePixelFormatDesc PIXEL_FORMAT_DESC[NUM_RagePixelFormat] =
    {{/* R8G8B8A8 */
      32,
      {0xFF000000, 0x00FF0000, 0x0000FF00, 0x000000FF}},
     {/* B8G8R8A8 */
      32,
      {0x000000FF, 0x0000FF00, 0x00FF0000, 0xFF000000}},
     {/* R4G4B4A4 */
      16,
      {0xF000, 0x0F00, 0x00F0, 0x000F}},
     {/* R5G5B5A1 */
      16,
      {0xF800, 0x07C0, 0x003E, 0x0001}},
     {/* R5G5B5 */
      16,
      {0xF800, 0x07C0, 0x003E, 0x0000}},
     {/* R8G8B8 */
      24,
      {0xFF0000, 0x00FF00, 0x0000FF, 0x000000}},
     {/* Paletted */
      8,
      {0, 0, 0, 0}},
     {/* B8G8R8 */
      24,
      {0x0000FF, 0x00FF00, 0xFF0000, 0x000000}},
     {/* A1B5G5R5 */
      16,
      {0x7C00, 0x03E0, 0x001F, 0x8000}},
     {/* X1R5G5B5 */
      16,
      {0x7C00, 0x03E0, 0x001F, 0x0000}}};

float ByteColorToFloat(uint8_t value) {
  return static_cast<float>(value) / 255.0f;
}

uint8_t FloatColorToByte(float value) {
  if (!std::isfinite(value)) {
    value = 0.0f;
  }
  return static_cast<uint8_t>(
      std::clamp(value, 0.0f, 1.0f) * 255.0f + 0.5f);
}

double MetalDisplayPacingTargetHz(
    const std::unique_ptr<MacOSMetalPresenter>& presenter,
    const VideoModeParams& params, int requestedRefreshRate) {
  if (requestedRefreshRate != REFRESH_DEFAULT && requestedRefreshRate > 1) {
    return static_cast<double>(requestedRefreshRate);
  }

  const double fallbackHz =
      params.rate > 1 ? static_cast<double>(params.rate) : 60.0;
  return presenter
             ? presenter->DisplayPacingTargetHz(
                   fallbackHz, kMetalDisplayPacingHeadroomFactor)
             : fallbackHz * kMetalDisplayPacingHeadroomFactor;
}

RageVColor ToVertexColor(const RageColor& color) {
  RageVColor out;
  out.r = FloatColorToByte(color.r);
  out.g = FloatColorToByte(color.g);
  out.b = FloatColorToByte(color.b);
  out.a = FloatColorToByte(color.a);
  return out;
}

const char* MacOSNativePresentationReasonNameForMetal(int reason) {
  switch (reason) {
    case 1:
      return "will_enter_fullscreen";
    case 2:
      return "did_enter_fullscreen";
    case 3:
      return "will_exit_fullscreen";
    case 4:
      return "did_exit_fullscreen";
    case 5:
      return "screen_changed";
    case 6:
      return "backing_changed";
    default:
      return "unknown";
  }
}

RageColor ClampColor(const RageColor& color) {
  const auto clampFinite = [](float value) {
    return std::isfinite(value) ? std::clamp(value, 0.0f, 1.0f) : 0.0f;
  };
  return RageColor(
      clampFinite(color.r), clampFinite(color.g),
      clampFinite(color.b), clampFinite(color.a));
}

bool ReserveAdditionalVertices(
    std::vector<MacOSMetalSolidVertex>* vertices, size_t additional,
    const char* context) {
  if (vertices == nullptr ||
      additional > std::numeric_limits<size_t>::max() - vertices->size()) {
    LOG->Warn(
        "RageDisplay_Metal: refusing overflowing vertex staging context=%s "
        "existing=%zu additional=%zu.",
        context != nullptr ? context : "unknown",
        vertices != nullptr ? vertices->size() : 0, additional);
    return false;
  }
  try {
    vertices->reserve(vertices->size() + additional);
    return true;
  } catch (const std::bad_alloc&) {
    LOG->Warn(
        "RageDisplay_Metal: vertex staging allocation failed context=%s "
        "existing=%zu additional=%zu.",
        context != nullptr ? context : "unknown", vertices->size(), additional);
  } catch (const std::length_error&) {
    LOG->Warn(
        "RageDisplay_Metal: vertex staging length rejected context=%s "
        "existing=%zu additional=%zu.",
        context != nullptr ? context : "unknown", vertices->size(), additional);
  }
  return false;
}

RageVector3 NormalizeOrDefault(
    const RageVector3& vector, const RageVector3& fallback) {
  const float lengthSq =
      vector.x * vector.x + vector.y * vector.y + vector.z * vector.z;
  if (!std::isfinite(lengthSq) || lengthSq <= 0.000001f) {
    return fallback;
  }
  RageVector3 normalized;
  RageVec3Normalize(&normalized, &vector);
  return normalized;
}

RageVector3 TransformNormalInverseTranspose(
    const RageVector3& normal, const RageMatrix& matrix) {
  const float a = matrix.m[0][0];
  const float b = matrix.m[0][1];
  const float c = matrix.m[0][2];
  const float d = matrix.m[1][0];
  const float e = matrix.m[1][1];
  const float f = matrix.m[1][2];
  const float g = matrix.m[2][0];
  const float h = matrix.m[2][1];
  const float i = matrix.m[2][2];

  const float c00 = e * i - f * h;
  const float c01 = f * g - d * i;
  const float c02 = d * h - e * g;
  const float c10 = c * h - b * i;
  const float c11 = a * i - c * g;
  const float c12 = b * g - a * h;
  const float c20 = b * f - c * e;
  const float c21 = c * d - a * f;
  const float c22 = a * e - b * d;
  const float determinant = a * c00 + b * c01 + c * c02;
  if (!std::isfinite(determinant) || std::fabs(determinant) <= 0.000001f) {
    return NormalizeOrDefault(normal, RageVector3(0.0f, 0.0f, 1.0f));
  }

  const float inverseDeterminant = 1.0f / determinant;
  const RageVector3 transformed(
      (normal.x * c00 + normal.y * c10 + normal.z * c20) *
          inverseDeterminant,
      (normal.x * c01 + normal.y * c11 + normal.z * c21) *
          inverseDeterminant,
      (normal.x * c02 + normal.y * c12 + normal.z * c22) *
          inverseDeterminant);
  return NormalizeOrDefault(transformed, RageVector3(0.0f, 0.0f, 1.0f));
}

class RageCompiledGeometryMetal : public RageCompiledGeometry {
 public:
  void Allocate(const std::vector<msMesh>& /* vMeshes */) override {
    const unsigned int verticesCount =
        std::max<unsigned int>(1u, GetTotalVertices());
    const unsigned int trianglesCount =
        std::max<unsigned int>(1u, GetTotalTriangles());

    m_vVertices.resize(verticesCount);
    m_vTriangles.resize(trianglesCount);
  }

  void Change(const std::vector<msMesh>& vMeshes) override {
    m_bIndexOverflow = false;
    if (vMeshes.size() != m_vMeshInfo.size()) {
      LOG->Warn(
          "RageCompiledGeometryMetal: refusing mesh update with mismatched "
          "mesh count source=%zu allocated=%zu.",
          vMeshes.size(), m_vMeshInfo.size());
      m_bIndexOverflow = true;
      return;
    }
    for (size_t i = 0; i < vMeshes.size(); ++i) {
      const MeshInfo& meshInfo = m_vMeshInfo[i];
      const msMesh& mesh = vMeshes[i];

      if (meshInfo.iVertexStart < 0 || meshInfo.iTriangleStart < 0 ||
          mesh.Vertices.size() >
              m_vVertices.size() - std::min(
                  static_cast<size_t>(meshInfo.iVertexStart),
                  m_vVertices.size()) ||
          mesh.Triangles.size() >
              m_vTriangles.size() - std::min(
                  static_cast<size_t>(meshInfo.iTriangleStart),
                  m_vTriangles.size())) {
        LOG->Warn(
            "RageCompiledGeometryMetal: refusing mesh update outside "
            "allocated geometry mesh=%zu vertices=%zu start=%d capacity=%zu "
            "triangles=%zu triangle_start=%d triangle_capacity=%zu.",
            i, mesh.Vertices.size(), meshInfo.iVertexStart,
            m_vVertices.size(), mesh.Triangles.size(),
            meshInfo.iTriangleStart, m_vTriangles.size());
        m_bIndexOverflow = true;
        return;
      }

      for (size_t j = 0; j < mesh.Vertices.size(); ++j) {
        m_vVertices[meshInfo.iVertexStart + j] = mesh.Vertices[j];
      }

      for (size_t j = 0; j < mesh.Triangles.size(); ++j) {
        for (int k = 0; k < 3; ++k) {
          const int localVertexIndex = mesh.Triangles[j].nVertexIndices[k];
          if (localVertexIndex < 0 ||
              static_cast<size_t>(localVertexIndex) >= mesh.Vertices.size()) {
            LOG->Warn(
                "RageCompiledGeometryMetal: refusing mesh=%zu triangle=%zu "
                "with out-of-range local vertex index=%d vertex_count=%zu.",
                i, j, localVertexIndex, mesh.Vertices.size());
            m_bIndexOverflow = true;
            return;
          }
          const int vertexIndex = meshInfo.iVertexStart + localVertexIndex;
          if (vertexIndex < 0 ||
              vertexIndex >
                  static_cast<int>(std::numeric_limits<uint16_t>::max())) {
            LOG->Warn(
                "RageCompiledGeometryMetal: mesh has vertex index %d beyond "
                "the uint16 compiled geometry limit; refusing this compiled "
                "geometry to avoid corrupt rendering.",
                vertexIndex);
            m_bIndexOverflow = true;
            return;
          }
          m_vTriangles[meshInfo.iTriangleStart + j].nVertexIndices[k] =
              static_cast<uint16_t>(vertexIndex);
        }
      }
    }
  }

  void Draw(int /* iMeshIndex */) const override {}

  void EmitTo(
      RageDisplay_Metal* display, int iMeshIndex) const;

 private:
  std::vector<RageModelVertex> m_vVertices;
  std::vector<msTriangle> m_vTriangles;
  bool m_bIndexOverflow = false;
};

class RageTextureLockMetal : public RageTextureLock {
 public:
  ~RageTextureLockMetal() override {
    if (m_LockedSurface != nullptr) {
      LOG->Warn(
          "RageTextureLockMetal: destroying an active texture lock "
          "handle=%lu surface=%p.",
          static_cast<unsigned long>(m_TextureHandle), m_LockedSurface);
      Reset();
    }
  }

  bool Lock(uintptr_t textureHandle, RageSurface* surface) override {
    if (textureHandle == 0 || m_LockedSurface != nullptr || surface == nullptr ||
        surface->pixels != nullptr || surface->h <= 0 || surface->pitch <= 0) {
      LOG->Warn(
          "RageTextureLockMetal: refusing invalid lock handle=%lu "
          "already_locked=%d surface=%p pixels=%p height=%d pitch=%d.",
          static_cast<unsigned long>(textureHandle),
          m_LockedSurface != nullptr ? 1 : 0, surface,
          surface != nullptr ? surface->pixels : nullptr,
          surface != nullptr ? surface->h : 0,
          surface != nullptr ? surface->pitch : 0);
      return false;
    }

    const size_t height = static_cast<size_t>(surface->h);
    const size_t pitch = static_cast<size_t>(surface->pitch);
    if (height > std::numeric_limits<size_t>::max() / pitch) {
      LOG->Warn(
          "RageTextureLockMetal: refusing overflowing lock allocation "
          "handle=%lu height=%zu pitch=%zu.",
          static_cast<unsigned long>(textureHandle), height, pitch);
      return false;
    }
    try {
      m_Buffer.assign(height * pitch, 0);
    } catch (const std::bad_alloc&) {
      LOG->Warn(
          "RageTextureLockMetal: allocation failed handle=%lu bytes=%zu.",
          static_cast<unsigned long>(textureHandle), height * pitch);
      return false;
    } catch (const std::length_error&) {
      LOG->Warn(
          "RageTextureLockMetal: allocation length rejected handle=%lu "
          "bytes=%zu.",
          static_cast<unsigned long>(textureHandle), height * pitch);
      return false;
    }
    m_TextureHandle = textureHandle;
    m_LockedSurface = surface;
    surface->pixels = m_Buffer.empty() ? nullptr : m_Buffer.data();
    surface->pixels_owned = false;
    return surface->pixels != nullptr;
  }

  void Unlock(RageSurface* surface, bool changed = true) override {
    if (surface == nullptr || m_TextureHandle == 0 ||
        surface != m_LockedSurface) {
      LOG->Warn(
          "RageTextureLockMetal: ignoring invalid unlock surface=%p "
          "locked_surface=%p locked_handle=%lu.",
          surface, m_LockedSurface,
          static_cast<unsigned long>(m_TextureHandle));
      return;
    }
    if (changed && surface->pixels != nullptr && DISPLAY != nullptr) {
      DISPLAY->UpdateTexture(
          m_TextureHandle, surface, 0, 0, surface->w, surface->h);
    } else if (changed && DISPLAY == nullptr) {
      LOG->Warn(
          "RageTextureLockMetal: dropping changed texture unlock after "
          "display shutdown handle=%lu.",
          static_cast<unsigned long>(m_TextureHandle));
    }

    Reset();
  }

 private:
  void Reset() {
    if (m_LockedSurface != nullptr &&
        m_LockedSurface->pixels ==
            (m_Buffer.empty() ? nullptr : m_Buffer.data())) {
      m_LockedSurface->pixels = nullptr;
    }
    m_LockedSurface = nullptr;
    m_TextureHandle = 0;
    m_Buffer.clear();
  }

  uintptr_t m_TextureHandle = 0;
  RageSurface* m_LockedSurface = nullptr;
  std::vector<uint8_t> m_Buffer;
};

RageMatrix RageDisplay_Metal::CurrentModelViewProjection() const {
  RageMatrix projection;
  RageMatrixMultiply(&projection, GetCentering(), GetProjectionTop());

  RageMatrix modelView;
  RageMatrixMultiply(&modelView, GetViewTop(), GetWorldTop());

  RageMatrix modelViewProjection;
  RageMatrixMultiply(&modelViewProjection, &projection, &modelView);
  return modelViewProjection;
}

RageMatrix RageDisplay_Metal::CurrentTextureMatrix() const {
  return *GetTextureTop();
}

void CopyMatrixToMetalUniform(const RageMatrix& matrix, float out[16]) {
  if (out == nullptr) {
    return;
  }
  const float* values = matrix;
  std::memcpy(out, values, sizeof(float) * 16);
}

MacOSMetalTransformUniforms BuildTransformUniforms(
    const RageMatrix& modelViewProjection, const RageMatrix& textureMatrix,
    float zBias) {
  MacOSMetalTransformUniforms uniforms;
  CopyMatrixToMetalUniform(
      modelViewProjection, uniforms.modelViewProjection);
  CopyMatrixToMetalUniform(textureMatrix, uniforms.textureMatrix);
  uniforms.zBias = zBias;
  return uniforms;
}

bool TransformUniformsEqual(
    const MacOSMetalTransformUniforms& lhs,
    const MacOSMetalTransformUniforms& rhs) {
  return std::memcmp(&lhs, &rhs, sizeof(MacOSMetalTransformUniforms)) == 0;
}

void ApplyDepthRange(float zBias, RageVector4* clipPosition);

RageVector4 TransformVertexForDiagnostics(
    const MacOSMetalSolidVertex& vertex,
    const MacOSMetalTransformUniforms& transform) {
  const float* m = transform.modelViewProjection;
  RageVector4 clipPosition(
      m[0] * vertex.x + m[4] * vertex.y + m[8] * vertex.z + m[12] * vertex.w,
      m[1] * vertex.x + m[5] * vertex.y + m[9] * vertex.z + m[13] * vertex.w,
      m[2] * vertex.x + m[6] * vertex.y + m[10] * vertex.z + m[14] * vertex.w,
      m[3] * vertex.x + m[7] * vertex.y + m[11] * vertex.z + m[15] * vertex.w);
  ApplyDepthRange(transform.zBias, &clipPosition);
  return clipPosition;
}

void ApplyDepthRange(float zBias, RageVector4* clipPosition) {
  if (clipPosition == nullptr || clipPosition->w == 0.0f) {
    return;
  }

  const float nearDepth = SCALE(zBias, 0.0f, 1.0f, 0.05f, 0.0f);
  const float farDepth = SCALE(zBias, 0.0f, 1.0f, 1.0f, 0.95f);
  const float normalizedDepth = std::clamp(
      (clipPosition->z / clipPosition->w) * 0.5f + 0.5f, 0.0f, 1.0f);
  const float rangedDepth =
      nearDepth + normalizedDepth * (farDepth - nearDepth);
  clipPosition->z = rangedDepth * clipPosition->w;
}

RageVector2 SphereMapTextureCoord(const RageVector3& normal) {
  const RageVector3 n =
      NormalizeOrDefault(normal, RageVector3(0.0f, 0.0f, 1.0f));
  const float denominator =
      2.0f * std::sqrt(n.x * n.x + n.y * n.y + (n.z + 1.0f) * (n.z + 1.0f));
  if (denominator <= 0.000001f) {
    return RageVector2(0.5f, 0.5f);
  }
  return RageVector2(n.x / denominator + 0.5f, n.y / denominator + 0.5f);
}

MacOSMetalSolidVertex ToMetalSolidVertex(
    const RageVector3& position, const RageVector2& texcoord,
    const RageVector2& texcoord2,
    const RageVColor& color, const RageVector2& textureMatrixScale) {
  MacOSMetalSolidVertex out;
  out.x = position.x;
  out.y = position.y;
  out.z = position.z;
  out.w = 1.0f;
  out.u = texcoord.x;
  out.v = texcoord.y;
  out.u2 = texcoord2.x;
  out.v2 = texcoord2.y;
  out.textureMatrixScaleX = textureMatrixScale.x;
  out.textureMatrixScaleY = textureMatrixScale.y;
  out.r = ByteColorToFloat(color.r);
  out.g = ByteColorToFloat(color.g);
  out.b = ByteColorToFloat(color.b);
  out.a = ByteColorToFloat(color.a);
  return out;
}

MacOSMetalSolidVertex ToMetalSolidVertex(
    const RageSpriteVertex& v) {
  return ToMetalSolidVertex(v.p, v.t, v.t, v.c, RageVector2(1.0f, 1.0f));
}

void AppendTriangle(
    std::vector<MacOSMetalSolidVertex>* vertices,
    const RageSpriteVertex& a, const RageSpriteVertex& b,
    const RageSpriteVertex& c) {
  vertices->push_back(ToMetalSolidVertex(a));
  vertices->push_back(ToMetalSolidVertex(b));
  vertices->push_back(ToMetalSolidVertex(c));
}

RageColor RageDisplay_Metal::ComputeModelColor(
    const RageVector3& normal) const {
  if (!m_bLighting) {
    RageColor color = m_MaterialDiffuse;
    color.r += m_MaterialEmissive.r + m_MaterialAmbient.r;
    color.g += m_MaterialEmissive.g + m_MaterialAmbient.g;
    color.b += m_MaterialEmissive.b + m_MaterialAmbient.b;
    color.a = m_MaterialDiffuse.a;
    return ClampColor(color);
  }

  RageColor lit = m_MaterialEmissive;
  lit.a = m_MaterialDiffuse.a;
  bool anyLight = false;
  for (const DirectionalLight& light : m_Lights) {
    if (!light.enabled) {
      continue;
    }
    anyLight = true;
    lit.r += m_MaterialAmbient.r * light.ambient.r;
    lit.g += m_MaterialAmbient.g * light.ambient.g;
    lit.b += m_MaterialAmbient.b * light.ambient.b;

    const RageVector3 normalizedNormal =
        NormalizeOrDefault(normal, RageVector3(0.0f, 0.0f, 1.0f));
    const RageVector3 lightDir =
        NormalizeOrDefault(light.direction, RageVector3(0.0f, 0.0f, 1.0f));
    const float intensity =
        std::max(0.0f, normalizedNormal.x * lightDir.x +
                           normalizedNormal.y * lightDir.y +
                           normalizedNormal.z * lightDir.z);
    lit.r += m_MaterialDiffuse.r * light.diffuse.r * intensity;
    lit.g += m_MaterialDiffuse.g * light.diffuse.g * intensity;
    lit.b += m_MaterialDiffuse.b * light.diffuse.b * intensity;
    if (intensity > 0.0f) {
      // OpenGL's default non-local viewer uses a constant eye vector.  The
      // half-vector form matches its fixed-function directional-light model.
      const RageVector3 halfVector = NormalizeOrDefault(
          lightDir + RageVector3(0.0f, 0.0f, 1.0f),
          RageVector3(0.0f, 0.0f, 1.0f));
      const float specularBase = std::max(
          0.0f, normalizedNormal.x * halfVector.x +
                    normalizedNormal.y * halfVector.y +
                    normalizedNormal.z * halfVector.z);
      const float specularIntensity =
          std::pow(specularBase, m_fMaterialShininess);
      lit.r += m_MaterialSpecular.r * light.specular.r * specularIntensity;
      lit.g += m_MaterialSpecular.g * light.specular.g * specularIntensity;
      lit.b += m_MaterialSpecular.b * light.specular.b * specularIntensity;
    }
  }
  if (!anyLight) {
    lit.r += m_MaterialAmbient.r + m_MaterialDiffuse.r;
    lit.g += m_MaterialAmbient.g + m_MaterialDiffuse.g;
    lit.b += m_MaterialAmbient.b + m_MaterialDiffuse.b;
  }
  return ClampColor(lit);
}

RageColor RageDisplay_Metal::ComputeCelModelColor(
    const RageVector3& normal) const {
  const RageVector3 normalizedNormal =
      NormalizeOrDefault(normal, RageVector3(0.0f, 0.0f, 1.0f));
  RageVector3 lightDirection(0.0f, 0.0f, 1.0f);
  for (const DirectionalLight& light : m_Lights) {
    if (light.enabled) {
      lightDirection =
          NormalizeOrDefault(light.direction, RageVector3(0.0f, 0.0f, 1.0f));
      break;
    }
  }

  const float ambient = std::sqrt(
      m_MaterialAmbient.r * m_MaterialAmbient.r +
      m_MaterialAmbient.g * m_MaterialAmbient.g +
      m_MaterialAmbient.b * m_MaterialAmbient.b);
  float intensity = std::max(
      0.0f, normalizedNormal.x * lightDirection.x +
                normalizedNormal.y * lightDirection.y +
                normalizedNormal.z * lightDirection.z);

  RageColor multiplier(1.0f, 1.0f, 1.0f, 1.0f);
  if (intensity < 0.5f) {
    intensity *= 0.5f;
    multiplier.r *= 0.6f;
    multiplier.g *= 0.75f;
    multiplier.b *= 0.9f;
  }
  intensity =
      std::min(std::clamp(intensity, ambient, 1.0f) + 0.25f, 1.0f);
  multiplier.r *= intensity;
  multiplier.g *= intensity;
  multiplier.b *= intensity;
  multiplier.a = 1.0f;
  return ClampColor(multiplier);
}

void RageCompiledGeometryMetal::EmitTo(
    RageDisplay_Metal* display, int iMeshIndex) const {
  if (display == nullptr || iMeshIndex < 0 ||
      static_cast<size_t>(iMeshIndex) >= m_vMeshInfo.size()) {
    return;
  }

  const MeshInfo& meshInfo = m_vMeshInfo[iMeshIndex];
  if (meshInfo.iTriangleCount <= 0) {
    return;
  }
  if (m_bIndexOverflow) {
    return;
  }

  const size_t triangleStart = static_cast<size_t>(meshInfo.iTriangleStart);
  const size_t triangleCount = static_cast<size_t>(meshInfo.iTriangleCount);
  if (meshInfo.iTriangleStart < 0 ||
      triangleStart > m_vTriangles.size() ||
      triangleCount > m_vTriangles.size() - triangleStart ||
      triangleCount > std::numeric_limits<size_t>::max() / 3) {
    LOG->Warn(
        "RageCompiledGeometryMetal: refusing invalid draw range mesh=%d "
        "triangle_start=%d triangle_count=%d capacity=%zu.",
        iMeshIndex, meshInfo.iTriangleStart, meshInfo.iTriangleCount,
        m_vTriangles.size());
    return;
  }

  for (size_t i = 0; i < triangleCount; ++i) {
    const msTriangle& triangle = m_vTriangles[triangleStart + i];
    for (int k = 0; k < 3; ++k) {
      if (triangle.nVertexIndices[k] >= m_vVertices.size()) {
        LOG->Warn(
            "RageCompiledGeometryMetal: refusing mesh=%d with invalid "
            "staged triangle=%zu vertex_slot=%d vertex_index=%u.",
            iMeshIndex, i, k,
            static_cast<unsigned int>(triangle.nVertexIndices[k]));
        return;
      }
    }
  }

  const size_t outputVertexCount = triangleCount * 3;
  RageDisplay_Metal::DrawBatch* directBatch = nullptr;
  MacOSMetalSolidVertex* directVertices = nullptr;
  const bool useDirectVertices = display->ReserveDirectVertices(
      outputVertexCount, &directBatch, &directVertices);
  RageDisplay_Metal::DrawBatch* fallbackBatch = nullptr;
  if (!useDirectVertices) {
    fallbackBatch = &display->ActiveBatch(
        display->m_iActiveDrawBatchCount > 0 &&
        display->m_DrawBatches[display->m_iActiveDrawBatchCount - 1]
            .vertexBuffer != nullptr);
    if (!ReserveAdditionalVertices(
            &fallbackBatch->vertices, outputVertexCount,
            "compiled_geometry")) {
      return;
    }
  }

  RageMatrix modelView;
  RageMatrixMultiply(&modelView, display->GetViewTop(), display->GetWorldTop());
  size_t out = 0;
  for (int i = 0; i < meshInfo.iTriangleCount; ++i) {
    const msTriangle& tri =
        m_vTriangles[meshInfo.iTriangleStart + static_cast<size_t>(i)];
    for (int k = 0; k < 3; ++k) {
      const uint16_t vertexIndex = tri.nVertexIndices[k];
      const RageModelVertex& modelVertex = m_vVertices[vertexIndex];
      const RageVector3 transformedNormal =
          TransformNormalInverseTranspose(modelVertex.n, modelView);
      RageVector3 position = modelVertex.p;
      RageColor litColor =
          display->ComputeModelColor(transformedNormal);
      if (display->m_iCelShadedStage == 1) {
        position += modelVertex.n * 0.125f;
        litColor = RageColor(0.25f, 0.125f, 0.125f, 1.0f);
      } else if (display->m_iCelShadedStage == 2) {
        litColor = display->ComputeCelModelColor(transformedNormal);
      }
      const RageDisplay_Metal::DrawBatch& batch =
          useDirectVertices ? *directBatch : *fallbackBatch;
      const RageVector2 sphereTexcoord =
          SphereMapTextureCoord(transformedNormal);
      const RageVector2 texcoord = batch.sphereMapping[TextureUnit_1]
                                       ? sphereTexcoord
                                       : modelVertex.t;
      const RageVector2 texcoord2 = batch.sphereMapping[TextureUnit_2]
                                        ? sphereTexcoord
                                        : modelVertex.t;
      const MacOSMetalSolidVertex vertex = ToMetalSolidVertex(
          position, texcoord, texcoord2, ToVertexColor(litColor),
          modelVertex.TextureMatrixScale);
      if (useDirectVertices) {
        directVertices[out++] = vertex;
      } else {
        fallbackBatch->vertices.push_back(vertex);
      }
    }
  }
}

RageDisplay_Metal::RageDisplay_Metal()
    : m_TextureHandles{},
      m_BlendMode(BLEND_NORMAL),
      m_TextureModes{},
      m_EffectMode(EffectMode_Normal),
      m_iCelShadedStage(0),
      m_SphereMapping{},
      m_fZBias(0.0f),
      m_ZTestMode(ZTEST_OFF),
      m_CullMode(CULL_NONE),
      m_TextureWrapping{},
      m_TextureFiltering{},
      m_bZWrite(false),
      m_bAlphaTest(false),
      m_bClearDepthNextFrame(true),
      m_iCurrentRenderTargetHandle(0),
      m_MaterialDiffuse(1.0f, 1.0f, 1.0f, 1.0f),
      m_MaterialAmbient(0.0f, 0.0f, 0.0f, 1.0f),
      m_MaterialEmissive(0.0f, 0.0f, 0.0f, 1.0f),
      m_MaterialSpecular(0.0f, 0.0f, 0.0f, 1.0f),
      m_fMaterialShininess(0.0f),
      m_bLighting(false),
      m_Lights(4),
      m_iNextTextureHandle(1),
      m_iMetalFrames(0),
      m_iMetalStagingFrames(0),
      m_iSkippedPresentFrames(0),
      m_iLastMainDirectVertexCapacity(65536),
      m_iLastRenderTargetDirectVertexCapacity(16384),
      m_iRequestedRefreshRate(REFRESH_DEFAULT),
      m_bReady(false) {
  MacOSMetalPresenterSetNativeRendererActive(true);
  m_TextureModes.fill(TextureMode_Modulate);
  m_TextureFiltering.fill(true);
  m_Textures.resize(1);
  LOG->MapLog("renderer", "Current renderer: metal");
}

RageDisplay_Metal::~RageDisplay_Metal() {
  SetRuntimeFramePacingTargetHz(0.0f);
  ResetVertexWriter(&m_MainVertexWriter, true);
  ResetVertexWriter(&m_RenderTargetVertexWriter, true);
  DestroyAllTextures();
  if (m_Presenter) {
    m_Presenter->Shutdown();
  }
  MacOSMetalPresenterSetNativeRendererActive(false);
}

std::string RageDisplay_Metal::Init(
    const VideoModeParams& p,
    bool /* bAllowUnacceleratedRenderer */) {
  m_Window.reset(LowLevelWindow::Create());
  m_Presenter.reset(new MacOSMetalPresenter());
  m_bReady = false;

  bool needReloadTextures = false;
  const std::string err = SetVideoMode(p, needReloadTextures);
  if (!err.empty()) {
    SetRuntimeFramePacingTargetHz(0.0f);
    return err;
  }

  LOG->Trace(
      "RageDisplay_Metal initialized: size=%dx%d rate=%d windowed=%d",
      m_Params.width, m_Params.height, m_Params.rate,
      m_Params.windowed ? 1 : 0);
  return std::string();
}

void RageDisplay_Metal::GetDisplaySpecs(DisplaySpecs& out) const {
  if (m_Window) {
    m_Window->GetDisplaySpecs(out);
  } else {
    out.clear();
  }
}

const RageDisplay::RagePixelFormatDesc* RageDisplay_Metal::GetPixelFormatDesc(
    RagePixelFormat pf) const {
  if (pf < 0 || pf >= NUM_RagePixelFormat) {
    LOG->Warn(
        "RageDisplay_Metal: invalid pixel format requested value=%d; "
        "falling back to RGBA8.",
        static_cast<int>(pf));
    pf = RagePixelFormat_RGBA8;
  }
  return &PIXEL_FORMAT_DESC[pf];
}

bool RageDisplay_Metal::SupportsTextureFormat(
    RagePixelFormat pixfmt, bool /* realtime */) {
  switch (pixfmt) {
    case RagePixelFormat_RGBA8:
    case RagePixelFormat_BGRA8:
    case RagePixelFormat_RGBA4:
    case RagePixelFormat_RGB5A1:
    case RagePixelFormat_RGB5:
    case RagePixelFormat_RGB8:
    case RagePixelFormat_PAL:
    case RagePixelFormat_BGR8:
    case RagePixelFormat_A1BGR5:
    case RagePixelFormat_X1RGB5:
      return true;
    default:
      return false;
  }
}

bool RageDisplay_Metal::BeginFrame() {
  if (!m_bReady) {
    return false;
  }
  // OpenGL clears color and depth at the beginning of every frame.  Metal's
  // offscreen color target is cleared by the presenter, but depth is only
  // cleared when this flag is set.  Re-arm it here so depth-writing models do
  // not occlude later frames with stale geometry.
  m_bClearDepthNextFrame = true;
  m_bLayerReconfiguredForResolutionChange = false;
  SetDefaultRenderStates();
  return true;
}

void RageDisplay_Metal::ReleaseTexture(MetalTexture* texture) {
  if (texture == nullptr) {
    return;
  }
  if (texture->texture != nullptr && m_Presenter) {
    m_Presenter->ReleaseTexture(texture->texture);
  }
  if (texture->depthTexture != nullptr && m_Presenter) {
    m_Presenter->ReleaseTexture(texture->depthTexture);
  }
  texture->texture = nullptr;
  texture->depthTexture = nullptr;
  texture->width = 0;
  texture->height = 0;
  texture->renderWidth = 0;
  texture->renderHeight = 0;
  texture->renderTarget = false;
  texture->requestedDepth = false;
  texture->requestedAlpha = false;
  texture->requestedFloat = false;
  texture->generateMipMaps = false;
  texture->hasRendered = false;
  texture->preserveNextRender = false;
}

bool RageDisplay_Metal::IsTexturePendingDelete(uintptr_t handle) const {
  return std::find(
             m_PendingTextureDeletes.begin(), m_PendingTextureDeletes.end(),
             handle) != m_PendingTextureDeletes.end();
}

void RageDisplay_Metal::ReleasePendingTextureDeletes() {
  for (uintptr_t handle : m_PendingTextureDeletes) {
    if (handle == 0 || handle >= m_Textures.size()) {
      continue;
    }
    ReleaseTexture(&m_Textures[handle]);
    RecycleTextureHandle(handle);
  }
  m_PendingTextureDeletes.clear();
}

bool RageDisplay_Metal::UploadTexturePixels(
    MetalTexture* texture, RageSurface* img, int xoffset, int yoffset,
    int width, int height) {
  if (texture == nullptr || img == nullptr || m_Presenter == nullptr ||
      width <= 0 || height <= 0 || texture->width <= 0 ||
      texture->height <= 0) {
    return false;
  }
  if (img->pixels == nullptr || img->format == nullptr) {
    LOG->Warn(
        "RageDisplay_Metal: refusing texture upload with missing pixels or "
        "format offset=%d,%d size=%dx%d texture=%dx%d.",
        xoffset, yoffset, width, height, texture->width, texture->height);
    return false;
  }

  const int bytesPerPixel = img->format->BytesPerPixel;
  if (bytesPerPixel <= 0 || img->w < width || img->h < height ||
      img->pitch <= 0 ||
      static_cast<size_t>(img->pitch) <
          static_cast<size_t>(width) * static_cast<size_t>(bytesPerPixel)) {
    LOG->Warn(
        "RageDisplay_Metal: refusing malformed texture source size=%dx%d "
        "upload=%dx%d pitch=%d bytes_per_pixel=%d.",
        img->w, img->h, width, height, img->pitch, bytesPerPixel);
    return false;
  }
  const size_t uploadWidth = static_cast<size_t>(width);
  const size_t uploadHeight = static_cast<size_t>(height);
  if (uploadWidth > std::numeric_limits<size_t>::max() / 4 ||
      uploadHeight >
          std::numeric_limits<size_t>::max() / (uploadWidth * 4)) {
    LOG->Warn(
        "RageDisplay_Metal: refusing overflowing texture upload size=%dx%d.",
        width, height);
    return false;
  }

  std::vector<uint8_t> pixels;
  try {
    pixels.assign(uploadWidth * uploadHeight * 4, 0);
  } catch (const std::bad_alloc&) {
    LOG->Warn(
        "RageDisplay_Metal: texture conversion allocation failed size=%dx%d.",
        width, height);
    return false;
  }
  for (int y = 0; y < height; ++y) {
    const uint8_t* src = img->pixels + static_cast<size_t>(y) * img->pitch;
    uint8_t* dst = pixels.data() + static_cast<size_t>(y) * width * 4;
    for (int x = 0; x < width; ++x) {
      uint8_t rgbaPixel[4] = {0, 0, 0, 0};
      RageSurfaceUtils::GetRGBAV(
          src + static_cast<size_t>(x) * img->format->BytesPerPixel, img,
          rgbaPixel);
      const size_t dstOffset = static_cast<size_t>(x) * 4;
      dst[dstOffset + 0] = rgbaPixel[0];
      dst[dstOffset + 1] = rgbaPixel[1];
      dst[dstOffset + 2] = rgbaPixel[2];
      dst[dstOffset + 3] = rgbaPixel[3];
    }
  }

  const size_t bytesPerRow = static_cast<size_t>(width) * 4;
  if (texture->texture != nullptr) {
    return m_Presenter->UpdateRGBA8Texture(
        texture->texture, xoffset, yoffset, width, height, pixels.data(),
        bytesPerRow);
  }

  const size_t textureWidth = static_cast<size_t>(texture->width);
  const size_t textureHeight = static_cast<size_t>(texture->height);
  if (textureWidth > std::numeric_limits<size_t>::max() / 4 ||
      textureHeight >
          std::numeric_limits<size_t>::max() / (textureWidth * 4)) {
    return false;
  }
  std::vector<uint8_t> fullPixels;
  try {
    fullPixels.assign(textureWidth * textureHeight * 4, 0);
  } catch (const std::bad_alloc&) {
    LOG->Warn(
        "RageDisplay_Metal: full texture allocation failed size=%dx%d.",
        texture->width, texture->height);
    return false;
  }
  for (int y = 0; y < height; ++y) {
    std::memcpy(
        fullPixels.data() +
            (static_cast<size_t>(y + yoffset) * texture->width + xoffset) * 4,
        pixels.data() + static_cast<size_t>(y) * width * 4,
        bytesPerRow);
  }

  void* metalTexture = m_Presenter->CreateRGBA8Texture(
      texture->width, texture->height, fullPixels.data(),
      static_cast<size_t>(texture->width) * 4, texture->generateMipMaps);
  if (metalTexture == nullptr) {
    return false;
  }

  const int newWidth = texture->width;
  const int newHeight = texture->height;
  const bool newGenerateMipMaps = texture->generateMipMaps;
  ReleaseTexture(texture);
  texture->texture = metalTexture;
  texture->width = newWidth;
  texture->height = newHeight;
  texture->generateMipMaps = newGenerateMipMaps;
  return true;
}

uintptr_t RageDisplay_Metal::AllocateTextureHandle() {
  while (!m_FreeTextureHandles.empty()) {
    const uintptr_t handle = m_FreeTextureHandles.back();
    m_FreeTextureHandles.pop_back();
    if (handle != 0 && handle < m_Textures.size() &&
        m_Textures[handle].texture == nullptr &&
        m_Textures[handle].depthTexture == nullptr) {
      return handle;
    }
  }

  const uintptr_t handle = m_iNextTextureHandle++;
  if (handle >= m_Textures.size()) {
    m_Textures.resize(handle + 1);
  }
  return handle;
}

void RageDisplay_Metal::RecycleTextureHandle(uintptr_t handle) {
  if (handle == 0 || handle >= m_Textures.size()) {
    return;
  }
  if (m_Textures[handle].texture != nullptr ||
      m_Textures[handle].depthTexture != nullptr) {
    return;
  }
  if (std::find(m_FreeTextureHandles.begin(), m_FreeTextureHandles.end(),
                handle) != m_FreeTextureHandles.end()) {
    return;
  }
  m_FreeTextureHandles.push_back(handle);
}

uintptr_t RageDisplay_Metal::CreateTexture(
    RagePixelFormat pixfmt, RageSurface* img,
    bool bGenerateMipMaps) {
  if (!SupportsTextureFormat(pixfmt) || img == nullptr || img->w <= 0 ||
      img->h <= 0) {
    return 0;
  }

  const uintptr_t handle = AllocateTextureHandle();
  MetalTexture& texture = m_Textures[handle];
  texture.width = img->w;
  texture.height = img->h;
  texture.generateMipMaps = bGenerateMipMaps;
  if (!UploadTexturePixels(&texture, img, 0, 0, img->w, img->h)) {
    ReleaseTexture(&texture);
    RecycleTextureHandle(handle);
    return 0;
  }

  return handle;
}

void RageDisplay_Metal::UpdateTexture(
    uintptr_t iTexHandle, RageSurface* img, int xoffset, int yoffset,
    int width, int height) {
  if (iTexHandle == 0 || iTexHandle >= m_Textures.size() ||
      IsTexturePendingDelete(iTexHandle)) {
    return;
  }
  MetalTexture& texture = m_Textures[iTexHandle];
  if (texture.texture == nullptr) {
    return;
  }
  if (texture.renderTarget) {
    LOG->Warn(
        "RageDisplay_Metal: ignoring UpdateTexture on render target handle=%lu.",
        static_cast<unsigned long>(iTexHandle));
    return;
  }

  if (xoffset < 0 || yoffset < 0 || width <= 0 || height <= 0 ||
      xoffset > texture.width - width || yoffset > texture.height - height) {
    LOG->Warn(
        "RageDisplay_Metal: ignoring invalid texture update handle=%lu "
        "offset=%d,%d size=%dx%d texture=%dx%d.",
        static_cast<unsigned long>(iTexHandle), xoffset, yoffset, width, height,
        texture.width, texture.height);
    return;
  }
  if (!UploadTexturePixels(&texture, img, xoffset, yoffset, width, height)) {
    LOG->Warn(
        "RageDisplay_Metal: texture update failed handle=%lu offset=%d,%d "
        "size=%dx%d texture=%dx%d.",
        static_cast<unsigned long>(iTexHandle), xoffset, yoffset, width, height,
        texture.width, texture.height);
  }
}

RageTextureLock* RageDisplay_Metal::CreateTextureLock() {
  return new RageTextureLockMetal;
}

uintptr_t RageDisplay_Metal::CreateRenderTarget(
    const RenderTargetParam& param, int& iTextureWidthOut,
    int& iTextureHeightOut) {
  iTextureWidthOut = 0;
  iTextureHeightOut = 0;
  if (m_Presenter == nullptr || param.iWidth <= 0 || param.iHeight <= 0) {
    return 0;
  }
  if (param.bFloat) {
    LOG->Warn(
        "RageDisplay_Metal: float render targets are not supported yet; "
        "refusing render target %dx%d so the caller can fall back instead "
        "of silently losing precision.",
        param.iWidth, param.iHeight);
    return 0;
  }

  const int textureWidth = param.iWidth;
  const int textureHeight = param.iHeight;
  void* colorTexture =
      m_Presenter->CreateBGRA8RenderTargetTexture(textureWidth, textureHeight);
  if (colorTexture == nullptr) {
    LOG->Warn(
        "RageDisplay_Metal: failed to create render target color texture "
        "%dx%d.",
        textureWidth, textureHeight);
    return 0;
  }

  void* depthTexture = nullptr;
  if (param.bWithDepthBuffer) {
    depthTexture =
        m_Presenter->CreateDepthRenderTargetTexture(textureWidth, textureHeight);
    if (depthTexture == nullptr) {
      LOG->Warn(
          "RageDisplay_Metal: failed to create render target depth texture "
          "%dx%d.",
          textureWidth, textureHeight);
      m_Presenter->ReleaseTexture(colorTexture);
      return 0;
    }
  }

  const uintptr_t handle = AllocateTextureHandle();
  MetalTexture& texture = m_Textures[handle];
  ReleaseTexture(&texture);
  texture.texture = colorTexture;
  texture.depthTexture = depthTexture;
  texture.width = textureWidth;
  texture.height = textureHeight;
  texture.renderWidth = param.iWidth;
  texture.renderHeight = param.iHeight;
  texture.renderTarget = true;
  texture.requestedDepth = param.bWithDepthBuffer;
  texture.requestedAlpha = param.bWithAlpha;
  texture.requestedFloat = param.bFloat;
  texture.hasRendered = false;
  texture.preserveNextRender = false;

  iTextureWidthOut = textureWidth;
  iTextureHeightOut = textureHeight;
  if (PerfDiagnosticsEnabled()) {
    LOG->Trace(
        "PERF_TRACE: metal_render_target_created handle=%lu logical=%dx%d "
        "texture=%dx%d requested_depth=%d requested_alpha=%d "
        "requested_float=%d actual_depth=%d actual_format=BGRA8Unorm",
        static_cast<unsigned long>(handle), param.iWidth, param.iHeight,
        textureWidth, textureHeight, param.bWithDepthBuffer ? 1 : 0,
        param.bWithAlpha ? 1 : 0, param.bFloat ? 1 : 0,
        depthTexture != nullptr ? 1 : 0);
  }
  return handle;
}

uintptr_t RageDisplay_Metal::GetRenderTarget() {
  return m_iCurrentRenderTargetHandle;
}

void RageDisplay_Metal::SetRenderTarget(
    uintptr_t iHandle, bool bPreserveTexture) {
  const uintptr_t previousHandle = m_iCurrentRenderTargetHandle;

  if (previousHandle == 0 && iHandle != 0) {
    /*
     * Switching from the drawable to an offscreen target must not present the
     * partially built frame.  Keep the main-target batches aside, render the
     * offscreen pass, then restore them before the final EndFrame present.
     */
    if (m_bClearDepthNextFrame) {
      DrawBatch clearBatch;
      clearBatch.clearDepthBefore = true;
      m_DrawBatches.push_back(std::move(clearBatch));
      m_iActiveDrawBatchCount = m_DrawBatches.size();
      m_bClearDepthNextFrame = false;
    }
    MoveActiveBatchesTo(&m_PendingMainDrawBatches);
  } else {
    FlushBatches();
  }

  if (iHandle == 0) {
    m_iCurrentRenderTargetHandle = 0;
    RestorePendingMainBatches();
    if (PerfDiagnosticsEnabled() && previousHandle != 0) {
      LOG->Trace(
          "PERF_TRACE: metal_render_target_set previous=%lu current=0",
          static_cast<unsigned long>(previousHandle));
    }
    return;
  }

  if (iHandle >= m_Textures.size() || !m_Textures[iHandle].renderTarget ||
      m_Textures[iHandle].texture == nullptr) {
    LOG->Warn(
        "RageDisplay_Metal: invalid render target handle=%lu.",
        static_cast<unsigned long>(iHandle));
    m_iCurrentRenderTargetHandle = 0;
    RestorePendingMainBatches();
    return;
  }

  MetalTexture& texture = m_Textures[iHandle];
  texture.preserveNextRender = bPreserveTexture && texture.hasRendered;
  m_iCurrentRenderTargetHandle = iHandle;
  if (PerfDiagnosticsEnabled()) {
    LOG->Trace(
        "PERF_TRACE: metal_render_target_set previous=%lu current=%lu "
        "preserve_requested=%d preserve_effective=%d has_rendered=%d "
        "logical=%dx%d texture=%dx%d requested_depth=%d requested_alpha=%d "
        "requested_float=%d",
        static_cast<unsigned long>(previousHandle),
        static_cast<unsigned long>(iHandle), bPreserveTexture ? 1 : 0,
        texture.preserveNextRender ? 1 : 0, texture.hasRendered ? 1 : 0,
        texture.renderWidth, texture.renderHeight, texture.width,
        texture.height, texture.requestedDepth ? 1 : 0,
        texture.requestedAlpha ? 1 : 0, texture.requestedFloat ? 1 : 0);
  }
  SetDefaultRenderStates();
}

void RageDisplay_Metal::DeleteTexture(uintptr_t iTexHandle) {
  if (iTexHandle == 0 || iTexHandle >= m_Textures.size()) {
    return;
  }
  if (m_iCurrentRenderTargetHandle == iTexHandle) {
    FlushBatches();
    m_iCurrentRenderTargetHandle = 0;
  }
  if (IsTexturePendingDelete(iTexHandle)) {
    return;
  }
  const MetalTexture& texture = m_Textures[iTexHandle];
  const bool hadAllocatedTexture =
      texture.texture != nullptr || texture.depthTexture != nullptr ||
      texture.width > 0 || texture.height > 0;
  if (!hadAllocatedTexture) {
    return;
  }
  if (PerfDiagnosticsEnabled() && texture.renderTarget) {
    LOG->Trace(
        "PERF_TRACE: metal_render_target_deleted handle=%lu has_rendered=%d "
        "logical=%dx%d texture=%dx%d",
        static_cast<unsigned long>(iTexHandle), texture.hasRendered ? 1 : 0,
        texture.renderWidth, texture.renderHeight, texture.width,
        texture.height);
  }
  for (uintptr_t& textureHandle : m_TextureHandles) {
    if (textureHandle == iTexHandle) {
      textureHandle = 0;
    }
  }
  /*
   * DrawBatch keeps stable engine handles until EndFrame builds and submits the
   * Metal command buffers.  Releasing or recycling this handle here could make
   * an earlier draw sample either freed memory or a newly allocated texture.
   */
  m_PendingTextureDeletes.push_back(iTexHandle);
}

void RageDisplay_Metal::ClearAllTextures() {
  m_TextureHandles.fill(0);
}

void RageDisplay_Metal::DestroyAllTextures() {
  for (MetalTexture& texture : m_Textures) {
    ReleaseTexture(&texture);
  }
  m_Textures.clear();
  m_Textures.resize(1);
  m_FreeTextureHandles.clear();
  m_PendingTextureDeletes.clear();
  m_TextureHandles.fill(0);
  m_iCurrentRenderTargetHandle = 0;
  m_iNextTextureHandle = 1;
}

void RageDisplay_Metal::SetTexture(TextureUnit tu, uintptr_t iTexture) {
  if (tu < 0 || tu >= NUM_TextureUnit) {
    return;
  }
  if (iTexture != 0 &&
      (iTexture >= m_Textures.size() || IsTexturePendingDelete(iTexture) ||
       m_Textures[iTexture].texture == nullptr)) {
    LOG->Warn(
        "RageDisplay_Metal: refusing invalid texture binding unit=%d handle=%lu.",
        static_cast<int>(tu), static_cast<unsigned long>(iTexture));
    iTexture = 0;
  }
  m_TextureHandles[tu] = iTexture;
}

void RageDisplay_Metal::SetBlendMode(BlendMode mode) {
  if (mode < 0 || mode >= NUM_BlendMode) {
    mode = BLEND_NORMAL;
  }
  m_BlendMode = mode;
}

void RageDisplay_Metal::SetTextureMode(TextureUnit tu, TextureMode mode) {
  if (tu < 0 || tu >= NUM_TextureUnit) {
    return;
  }
  if (mode < 0 || mode >= NUM_TextureMode) {
    mode = TextureMode_Modulate;
  }
  m_TextureModes[tu] = mode;
}

void RageDisplay_Metal::SetTextureWrapping(TextureUnit tu, bool wrapping) {
  if (tu < 0 || tu >= NUM_TextureUnit) {
    return;
  }
  m_TextureWrapping[tu] = wrapping;
}

void RageDisplay_Metal::SetTextureFiltering(TextureUnit tu, bool filtering) {
  if (tu < 0 || tu >= NUM_TextureUnit) {
    return;
  }
  m_TextureFiltering[tu] = filtering;
}

void RageDisplay_Metal::SetEffectMode(EffectMode effect) {
  switch (effect) {
    case EffectMode_Normal:
    case EffectMode_Unpremultiply:
    case EffectMode_ColorBurn:
    case EffectMode_ColorDodge:
    case EffectMode_VividLight:
    case EffectMode_HardMix:
    case EffectMode_Overlay:
    case EffectMode_Screen:
    case EffectMode_YUYV422:
    case EffectMode_DistanceField:
      m_EffectMode = effect;
      break;
    default:
      m_EffectMode = EffectMode_Normal;
      break;
  }
}

bool RageDisplay_Metal::IsEffectModeSupported(EffectMode effect) {
  return effect == EffectMode_Normal ||
         effect == EffectMode_Unpremultiply ||
         effect == EffectMode_ColorBurn ||
         effect == EffectMode_ColorDodge ||
         effect == EffectMode_VividLight ||
         effect == EffectMode_HardMix ||
         effect == EffectMode_Overlay ||
         effect == EffectMode_Screen ||
         effect == EffectMode_YUYV422 ||
         effect == EffectMode_DistanceField;
}

void RageDisplay_Metal::SetZWrite(bool write) {
  m_bZWrite = write;
}

void RageDisplay_Metal::SetZBias(float bias) {
  m_fZBias = std::isfinite(bias) ? std::clamp(bias, 0.0f, 1.0f) : 0.0f;
}

void RageDisplay_Metal::SetZTestMode(ZTestMode mode) {
  if (mode < 0 || mode >= NUM_ZTestMode) {
    mode = ZTEST_OFF;
  }
  m_ZTestMode = mode;
}

void RageDisplay_Metal::ClearZBuffer() {
  m_bClearDepthNextFrame = true;
}

void RageDisplay_Metal::SetCullMode(CullMode mode) {
  if (mode < 0 || mode >= NUM_CullMode) {
    mode = CULL_NONE;
  }
  m_CullMode = mode;
}

void RageDisplay_Metal::SetAlphaTest(bool enabled) {
  m_bAlphaTest = enabled;
}

void RageDisplay_Metal::SetMaterial(
    const RageColor& emissive, const RageColor& ambient,
    const RageColor& diffuse, const RageColor& specular,
    float shininess) {
  m_MaterialDiffuse = diffuse;
  m_MaterialAmbient = ambient;
  m_MaterialEmissive = emissive;
  m_MaterialSpecular = specular;
  m_fMaterialShininess =
      std::isfinite(shininess) ? std::clamp(shininess, 0.0f, 128.0f) : 0.0f;
}

void RageDisplay_Metal::SetLighting(bool enabled) {
  m_bLighting = enabled;
}

void RageDisplay_Metal::SetLightOff(int index) {
  if (index < 0 || static_cast<size_t>(index) >= m_Lights.size()) {
    return;
  }
  m_Lights[index].enabled = false;
}

void RageDisplay_Metal::SetLightDirectional(
    int index, const RageColor& ambient, const RageColor& diffuse,
    const RageColor& specular, const RageVector3& dir) {
  if (index < 0) {
    return;
  }
  if (static_cast<size_t>(index) >= m_Lights.size()) {
    m_Lights.resize(static_cast<size_t>(index) + 1);
  }
  DirectionalLight& light = m_Lights[index];
  light.enabled = true;
  light.ambient = ambient;
  light.diffuse = diffuse;
  light.specular = specular;
  light.direction = dir;
}

void RageDisplay_Metal::SetSphereEnvironmentMapping(
    TextureUnit tu, bool enabled) {
  if (tu < 0 || tu >= NUM_TextureUnit) {
    return;
  }
  m_SphereMapping[tu] = enabled;
}

void RageDisplay_Metal::SetCelShaded(int stage) {
  if (stage < 0 || stage > 2) {
    stage = 0;
  }
  m_iCelShadedStage = stage;
}

RageDisplay_Metal::DrawBatch& RageDisplay_Metal::ActiveBatch(bool forceNew) {
  if (!forceNew && m_iActiveDrawBatchCount > 0) {
    DrawBatch& last = m_DrawBatches[m_iActiveDrawBatchCount - 1];
    const MacOSMetalTransformUniforms currentTransform =
        BuildTransformUniforms(
            CurrentModelViewProjection(), CurrentTextureMatrix(), m_fZBias);
    if (last.textureHandles == m_TextureHandles &&
        last.blendMode == m_BlendMode &&
        last.textureModes == m_TextureModes &&
        last.effectMode == m_EffectMode &&
        last.celStage == m_iCelShadedStage &&
        last.sphereMapping == m_SphereMapping &&
        last.zBias == m_fZBias &&
        TransformUniformsEqual(last.transform, currentTransform) &&
        last.zTestMode == m_ZTestMode &&
        last.cullMode == m_CullMode &&
        last.textureWrapping == m_TextureWrapping &&
        last.textureFiltering == m_TextureFiltering &&
        last.zWrite == m_bZWrite &&
        last.alphaTest == m_bAlphaTest &&
        !m_bClearDepthNextFrame) {
      return last;
    }
  }

  if (m_iActiveDrawBatchCount == m_DrawBatches.size()) {
    m_DrawBatches.emplace_back();
  }

  DrawBatch& batch = m_DrawBatches[m_iActiveDrawBatchCount++];
  batch.textureHandles = m_TextureHandles;
  batch.blendMode = m_BlendMode;
  batch.textureModes = m_TextureModes;
  batch.effectMode = m_EffectMode;
  batch.celStage = m_iCelShadedStage;
  batch.sphereMapping = m_SphereMapping;
  batch.zBias = m_fZBias;
  batch.zTestMode = m_ZTestMode;
  batch.cullMode = m_CullMode;
  batch.textureWrapping = m_TextureWrapping;
  batch.textureFiltering = m_TextureFiltering;
  batch.zWrite = m_bZWrite;
  batch.alphaTest = m_bAlphaTest;
  batch.clearDepthBefore = m_bClearDepthNextFrame;
  batch.transform = BuildTransformUniforms(
      CurrentModelViewProjection(), CurrentTextureMatrix(), m_fZBias);
  m_bClearDepthNextFrame = false;
  batch.vertexBuffer = nullptr;
  batch.vertexBufferOffsetBytes = 0;
  batch.vertexCount = 0;
  batch.vertices.clear();
  return batch;
}

bool RageDisplay_Metal::ReserveDirectVertices(
    size_t vertexCount, DrawBatch** batchOut,
    MacOSMetalSolidVertex** verticesOut) {
  if (batchOut != nullptr) {
    *batchOut = nullptr;
  }
  if (verticesOut != nullptr) {
    *verticesOut = nullptr;
  }
  if (m_Presenter == nullptr || vertexCount == 0 ||
      batchOut == nullptr || verticesOut == nullptr) {
    return false;
  }

  VertexWriterState& writer =
      m_iCurrentRenderTargetHandle > 0 ? m_RenderTargetVertexWriter
                                       : m_MainVertexWriter;
  if (writer.disabled) {
    return false;
  }

  if (!writer.active) {
    writer.renderTarget = m_iCurrentRenderTargetHandle > 0;
    const size_t previousCapacity =
        writer.renderTarget ? m_iLastRenderTargetDirectVertexCapacity
                            : m_iLastMainDirectVertexCapacity;
    const size_t requestedCapacity =
        std::max(previousCapacity, std::max<size_t>(vertexCount, 4096));
    const bool began =
        writer.renderTarget
            ? m_Presenter->BeginRenderTargetVertexFrame(
                  requestedCapacity, &writer.frame, &writer.vertices)
            : m_Presenter->BeginSolidVertexFrame(
                  requestedCapacity, &writer.frame, &writer.vertices);
    if (!began || writer.vertices == nullptr ||
        writer.frame.vertexBuffer == nullptr) {
      writer.disabled = true;
      return false;
    }
    writer.capacityVertices = requestedCapacity;
    writer.usedVertices = 0;
    writer.active = true;
  }

  if (vertexCount >
      std::numeric_limits<size_t>::max() - writer.usedVertices) {
    writer.disabled = true;
    return false;
  }
  const size_t requiredVertices = writer.usedVertices + vertexCount;
  if (requiredVertices > writer.capacityVertices) {
    writer.overflowRequiredVertices = std::max(
        writer.overflowRequiredVertices, requiredVertices);
    writer.disabled = true;
    return false;
  }

  const size_t vertexOffset = writer.usedVertices;
  DrawBatch& batch = ActiveBatch(
      m_iActiveDrawBatchCount > 0 &&
      (!m_DrawBatches[m_iActiveDrawBatchCount - 1].vertices.empty() ||
       (m_DrawBatches[m_iActiveDrawBatchCount - 1].vertexBuffer != nullptr &&
        m_DrawBatches[m_iActiveDrawBatchCount - 1].vertexBuffer !=
            writer.frame.vertexBuffer)));
  if (batch.vertexBuffer == nullptr && batch.vertexCount == 0) {
    batch.vertexBuffer = writer.frame.vertexBuffer;
    batch.vertexBufferOffsetBytes =
        vertexOffset * sizeof(MacOSMetalSolidVertex);
  } else if (
      batch.vertexBuffer != writer.frame.vertexBuffer ||
      batch.vertexBufferOffsetBytes +
              batch.vertexCount * sizeof(MacOSMetalSolidVertex) !=
          vertexOffset * sizeof(MacOSMetalSolidVertex)) {
    DrawBatch& newBatch = ActiveBatch(true);
    newBatch.vertexBuffer = writer.frame.vertexBuffer;
    newBatch.vertexBufferOffsetBytes =
        vertexOffset * sizeof(MacOSMetalSolidVertex);
    *batchOut = &newBatch;
    *verticesOut = writer.vertices + vertexOffset;
    writer.usedVertices += vertexCount;
    newBatch.vertexCount += vertexCount;
    return true;
  }

  *batchOut = &batch;
  *verticesOut = writer.vertices + vertexOffset;
  writer.usedVertices += vertexCount;
  batch.vertexCount += vertexCount;
  return true;
}

void RageDisplay_Metal::ResetVertexWriter(
    VertexWriterState* writer, bool cancelFrame) {
  if (writer == nullptr) {
    return;
  }
  if (writer->active) {
    const size_t nextCapacityFloor =
        std::max(writer->usedVertices, writer->overflowRequiredVertices);
    if (writer->renderTarget) {
      m_iLastRenderTargetDirectVertexCapacity =
          std::max(m_iLastRenderTargetDirectVertexCapacity,
                   nextCapacityFloor);
    } else {
      m_iLastMainDirectVertexCapacity =
          std::max(m_iLastMainDirectVertexCapacity, nextCapacityFloor);
    }
  }
  if (cancelFrame && writer->frame.frameSlot >= 0 && m_Presenter != nullptr) {
    m_Presenter->CancelVertexFrame(&writer->frame);
  }
  writer->frame = MacOSMetalVertexFrame();
  writer->vertices = nullptr;
  writer->usedVertices = 0;
  writer->capacityVertices = 0;
  writer->overflowRequiredVertices = 0;
  writer->active = false;
  writer->disabled = false;
  writer->renderTarget = false;
}

void RageDisplay_Metal::BuildMetalBatches(
    const std::vector<DrawBatch>& batches, size_t batchCount,
    std::vector<MacOSMetalDrawBatch>* metalBatches) const {
  if (metalBatches == nullptr) {
    return;
  }

  metalBatches->clear();
  metalBatches->reserve(batchCount);
  const size_t safeBatchCount = std::min(batchCount, batches.size());
  for (size_t i = 0; i < safeBatchCount; ++i) {
    const DrawBatch& batch = batches[i];
    if (batch.vertices.empty() && batch.vertexCount == 0 &&
        !batch.clearDepthBefore) {
      continue;
    }
    void* texture = nullptr;
    int textureWidth = 1;
    if (batch.textureHandles[TextureUnit_1] > 0 &&
        batch.textureHandles[TextureUnit_1] < m_Textures.size()) {
      if (m_iCurrentRenderTargetHandle == 0 ||
          batch.textureHandles[TextureUnit_1] != m_iCurrentRenderTargetHandle) {
        texture = m_Textures[batch.textureHandles[TextureUnit_1]].texture;
        textureWidth =
            std::max(1, m_Textures[batch.textureHandles[TextureUnit_1]].width);
      }
    }
    void* texture2 = nullptr;
    bool hasTexture2 = false;
    if (batch.textureHandles[TextureUnit_2] > 0 &&
        batch.textureHandles[TextureUnit_2] < m_Textures.size()) {
      if (m_iCurrentRenderTargetHandle == 0 ||
          batch.textureHandles[TextureUnit_2] != m_iCurrentRenderTargetHandle) {
        texture2 = m_Textures[batch.textureHandles[TextureUnit_2]].texture;
        hasTexture2 = texture2 != nullptr;
      }
    }
    MacOSMetalDrawBatch metalBatch;
    metalBatch.vertices =
        batch.vertices.empty() ? nullptr : batch.vertices.data();
    metalBatch.vertexBuffer = batch.vertexBuffer;
    metalBatch.vertexBufferOffsetBytes = batch.vertexBufferOffsetBytes;
    metalBatch.vertexCount =
        batch.vertexCount > 0 ? batch.vertexCount : batch.vertices.size();
    metalBatch.texture = texture;
    metalBatch.textureWidth = textureWidth;
    metalBatch.texture2 = texture2;
    metalBatch.textureMode2 = batch.textureModes[TextureUnit_2];
    metalBatch.hasTexture2 = hasTexture2;
    metalBatch.blendMode = batch.blendMode;
    metalBatch.textureMode = batch.textureModes[TextureUnit_1];
    metalBatch.effectMode = batch.effectMode;
    metalBatch.celStage = batch.celStage;
    metalBatch.zTestMode = batch.zTestMode;
    metalBatch.cullMode = batch.cullMode;
    metalBatch.textureWrapping = batch.textureWrapping[TextureUnit_1];
    metalBatch.textureFiltering = batch.textureFiltering[TextureUnit_1];
    metalBatch.texture2Wrapping = batch.textureWrapping[TextureUnit_2];
    metalBatch.texture2Filtering = batch.textureFiltering[TextureUnit_2];
    metalBatch.zWrite = batch.zWrite;
    metalBatch.alphaTest = batch.alphaTest;
    metalBatch.clearDepthBefore = batch.clearDepthBefore;
    metalBatch.transform = batch.transform;
    metalBatches->push_back(metalBatch);
  }
}

void RageDisplay_Metal::ClearActiveBatches() {
  const size_t safeBatchCount =
      std::min(m_iActiveDrawBatchCount, m_DrawBatches.size());
  for (size_t i = 0; i < safeBatchCount; ++i) {
    m_DrawBatches[i].vertices.clear();
    m_DrawBatches[i].vertexBuffer = nullptr;
    m_DrawBatches[i].vertexBufferOffsetBytes = 0;
    m_DrawBatches[i].vertexCount = 0;
  }
  m_iActiveDrawBatchCount = 0;
}

void RageDisplay_Metal::MoveActiveBatchesTo(
    std::vector<DrawBatch>* destination) {
  if (destination == nullptr) {
    ClearActiveBatches();
    return;
  }

  const size_t safeBatchCount =
      std::min(m_iActiveDrawBatchCount, m_DrawBatches.size());
  destination->reserve(destination->size() + safeBatchCount);
  for (size_t i = 0; i < safeBatchCount; ++i) {
    if (!m_DrawBatches[i].vertices.empty() ||
        m_DrawBatches[i].vertexCount > 0 ||
        m_DrawBatches[i].clearDepthBefore) {
      destination->push_back(std::move(m_DrawBatches[i]));
    } else {
      m_DrawBatches[i].vertices.clear();
      m_DrawBatches[i].vertexBuffer = nullptr;
      m_DrawBatches[i].vertexBufferOffsetBytes = 0;
      m_DrawBatches[i].vertexCount = 0;
    }
  }
  m_iActiveDrawBatchCount = 0;
}

void RageDisplay_Metal::RestorePendingMainBatches() {
  if (m_PendingMainDrawBatches.empty()) {
    return;
  }

  std::vector<DrawBatch> activeMainBatches;
  MoveActiveBatchesTo(&activeMainBatches);
  m_DrawBatches.clear();
  m_DrawBatches.reserve(
      m_PendingMainDrawBatches.size() + activeMainBatches.size());
  for (DrawBatch& batch : m_PendingMainDrawBatches) {
    m_DrawBatches.push_back(std::move(batch));
  }
  for (DrawBatch& batch : activeMainBatches) {
    m_DrawBatches.push_back(std::move(batch));
  }
  m_iActiveDrawBatchCount = m_DrawBatches.size();
  m_PendingMainDrawBatches.clear();
}

void RageDisplay_Metal::FlushBatches() {
  if (!m_bReady || m_Presenter == nullptr) {
    ResetVertexWriter(&m_MainVertexWriter, true);
    ResetVertexWriter(&m_RenderTargetVertexWriter, true);
    ClearActiveBatches();
    return;
  }

  const size_t activeBatchCount =
      std::min(m_iActiveDrawBatchCount, m_DrawBatches.size());
  size_t stagedVertexCount = 0;
  size_t stagedVertexCapacity = 0;
  size_t directVertexCount = 0;
  size_t largestBatchVertexCount = 0;
  size_t largestBatchVertexCapacity = 0;
  size_t smallBatchCount = 0;
  for (size_t i = 0; i < activeBatchCount; ++i) {
    const std::vector<MacOSMetalSolidVertex>& vertices =
        m_DrawBatches[i].vertices;
    const size_t batchVertexCount =
        std::max(vertices.size(), m_DrawBatches[i].vertexCount);
    stagedVertexCount += vertices.size();
    stagedVertexCapacity += vertices.capacity();
    directVertexCount += m_DrawBatches[i].vertexCount;
    largestBatchVertexCount =
        std::max(largestBatchVertexCount, batchVertexCount);
    largestBatchVertexCapacity =
        std::max(largestBatchVertexCapacity, vertices.capacity());
    if (batchVertexCount > 0 && batchVertexCount <= 12) {
      ++smallBatchCount;
    }
  }

  const bool renderingToTarget = m_iCurrentRenderTargetHandle > 0;
  VertexWriterState& activeWriter =
      renderingToTarget ? m_RenderTargetVertexWriter : m_MainVertexWriter;
  const bool useDirectVertexFrame =
      activeWriter.active && activeWriter.frame.frameSlot >= 0 &&
      directVertexCount > 0;
  RageTimer buildTimer;
  BuildMetalBatches(m_DrawBatches, m_iActiveDrawBatchCount, &m_MetalDrawBatches);
  const float buildBatchesMs = buildTimer.Ago() * 1000.0f;
  if (PerfDiagnosticsEnabled()) {
    ++m_iMetalStagingFrames;
    if (m_iMetalStagingFrames <= 5 || m_iMetalStagingFrames % 600 == 0 ||
        buildBatchesMs >= 1.0f) {
      LOG->Trace(
          "PERF_TRACE: metal_cpu_staging frame=%llu active_batches=%zu "
          "metal_batches=%zu vertices=%zu staged_bytes=%zu "
          "vertex_capacity=%zu capacity_bytes=%zu largest_batch=%zu "
          "largest_capacity=%zu small_batches=%zu avg_vertices_per_batch=%.2f "
          "direct_vertices=%zu direct_frame=%d build_batches_ms=%.3f",
          static_cast<unsigned long long>(m_iMetalStagingFrames),
          activeBatchCount, m_MetalDrawBatches.size(), stagedVertexCount,
          stagedVertexCount * sizeof(MacOSMetalSolidVertex),
          stagedVertexCapacity,
          stagedVertexCapacity * sizeof(MacOSMetalSolidVertex),
          largestBatchVertexCount, largestBatchVertexCapacity, smallBatchCount,
          activeBatchCount > 0
              ? static_cast<double>(stagedVertexCount + directVertexCount) /
                    static_cast<double>(activeBatchCount)
              : 0.0,
          directVertexCount, useDirectVertexFrame ? 1 : 0,
          buildBatchesMs);
    }
  }

  if (m_iCurrentRenderTargetHandle > 0 &&
      m_iCurrentRenderTargetHandle < m_Textures.size()) {
    MetalTexture& target = m_Textures[m_iCurrentRenderTargetHandle];
    if (!target.renderTarget || target.texture == nullptr) {
      LOG->Warn(
          "RageDisplay_Metal: active render target became invalid handle=%lu.",
          static_cast<unsigned long>(m_iCurrentRenderTargetHandle));
      m_iCurrentRenderTargetHandle = 0;
      if (useDirectVertexFrame) {
        ResetVertexWriter(&activeWriter, true);
      }
      ClearActiveBatches();
      m_MetalDrawBatches.clear();
      return;
    }
    const bool preserveColor = target.preserveNextRender && target.hasRendered;
    const int viewportWidth =
        std::min(target.renderWidth > 0 ? target.renderWidth : target.width,
                 target.width);
    const int viewportHeight =
        std::min(target.renderHeight > 0 ? target.renderHeight : target.height,
                 target.height);
    const bool clearDepth =
        target.depthTexture != nullptr && (!preserveColor || m_bClearDepthNextFrame);
    const bool rendered = m_Presenter->RenderSolidBatchesToTexture(
        target.texture, target.depthTexture, m_MetalDrawBatches.data(),
        m_MetalDrawBatches.size(), preserveColor, clearDepth,
        0.0, 0.0, 0.0, 0.0, viewportWidth, viewportHeight,
        useDirectVertexFrame ? &activeWriter.frame : nullptr);
    if (useDirectVertexFrame && activeWriter.frame.frameSlot >= 0) {
      ResetVertexWriter(&activeWriter, true);
    } else {
      ResetVertexWriter(&activeWriter, false);
    }
    if (rendered) {
      target.hasRendered = true;
      target.preserveNextRender = true;
    } else {
      LOG->Warn(
          "RageDisplay_Metal: render target submit failed handle=%lu "
          "batches=%zu.",
          static_cast<unsigned long>(m_iCurrentRenderTargetHandle),
          m_MetalDrawBatches.size());
      target.preserveNextRender = preserveColor;
    }
    ClearActiveBatches();
    m_MetalDrawBatches.clear();
    m_bClearDepthNextFrame = false;
    return;
  }

  const double targetHz = MetalDisplayPacingTargetHz(
      m_Presenter, m_Params, m_iRequestedRefreshRate);
  SetRuntimeFramePacingTargetHz(static_cast<float>(targetHz));
  const int frameLimitHz =
      std::max(1, static_cast<int>(std::lround(targetHz)));
  FrameLimitBeforeVsync(frameLimitHz);
  const bool clearDepth = m_bClearDepthNextFrame;
  /*
   * Present through an offscreen render target for both native windowed and
   * native fullscreen modes.  This keeps CAMetalLayer::nextDrawable off the hot
   * render path: the frame is rendered first, then we consume a prefetched
   * drawable opportunistically.  The native Metal renderer requires this
   * offscreen present path during initialization, so missing pipeline state is an
   * initialization failure instead of a runtime direct-drawable fallback.
   */
  const MacOSMetalPresentResult presentResult =
      m_Presenter->PresentSolidBatchesOffscreenFirst(
      m_MetalDrawBatches.data(), m_MetalDrawBatches.size(), clearDepth, 0.0,
      0.0, 0.0, 1.0, targetHz,
      useDirectVertexFrame ? &activeWriter.frame : nullptr);
  if (useDirectVertexFrame && activeWriter.frame.frameSlot >= 0) {
    ResetVertexWriter(&activeWriter, true);
  } else {
    ResetVertexWriter(&activeWriter, false);
  }
  /*
   * Metal present is asynchronous; the useful per-frame timings are reported by
   * MacOSMetalPresenter.  Do not feed submit/acquire time into the legacy
   * swap-buffer classifier, otherwise Metal backpressure is reported as if it
   * were an OpenGL CGLFlushDrawable block.
   */
  FrameLimitAfterVsync(0.0f);
  ClearActiveBatches();
  m_MetalDrawBatches.clear();
  m_bClearDepthNextFrame = false;
  if (presentResult != MacOSMetalPresentResult::Presented) {
    ++m_iSkippedPresentFrames;
    if (m_iSkippedPresentFrames <= 3 ||
        m_iSkippedPresentFrames % 600 == 0) {
      LOG->Warn(
          "RageDisplay_Metal: present %s; frames=%llu.",
          presentResult == MacOSMetalPresentResult::Skipped
              ? "skipped"
              : "failed",
          static_cast<unsigned long long>(m_iSkippedPresentFrames));
    }
  }
}

void RageDisplay_Metal::EndFrame() {
  if (m_bReady && m_Presenter) {
    if (m_iCurrentRenderTargetHandle != 0) {
      FlushBatches();
      m_iCurrentRenderTargetHandle = 0;
    }
    RestorePendingMainBatches();

    const std::vector<DrawBatch>& batches = m_DrawBatches;
    const size_t activeBatchCount =
        std::min(m_iActiveDrawBatchCount, batches.size());
    ++m_iMetalFrames;
    if (PerfDiagnosticsEnabled() &&
        (m_iMetalFrames <= 5 || m_iMetalFrames % 600 == 0)) {
      size_t directVertexCount = 0;
      size_t fallbackVertexCount = 0;
      size_t finiteVertexCount = 0;
      size_t insideClipVertexCount = 0;
      float minX = std::numeric_limits<float>::infinity();
      float minY = std::numeric_limits<float>::infinity();
      float minZ = std::numeric_limits<float>::infinity();
      float maxX = -std::numeric_limits<float>::infinity();
      float maxY = -std::numeric_limits<float>::infinity();
      float maxZ = -std::numeric_limits<float>::infinity();
      std::set<uintptr_t> textureHandles;
      for (size_t batchIndex = 0; batchIndex < activeBatchCount;
           ++batchIndex) {
        const DrawBatch& batch = batches[batchIndex];
        directVertexCount += batch.vertexCount;
        fallbackVertexCount += batch.vertices.size();
        for (uintptr_t textureHandle : batch.textureHandles) {
          if (textureHandle != 0) {
            textureHandles.insert(textureHandle);
          }
        }
        for (const MacOSMetalSolidVertex& vertex : batch.vertices) {
          const RageVector4 clipPosition =
              TransformVertexForDiagnostics(vertex, batch.transform);
          if (!std::isfinite(clipPosition.x) ||
              !std::isfinite(clipPosition.y) ||
              !std::isfinite(clipPosition.z) ||
              !std::isfinite(clipPosition.w) ||
              clipPosition.w == 0.0f) {
            continue;
          }
          const float ndcX = clipPosition.x / clipPosition.w;
          const float ndcY = clipPosition.y / clipPosition.w;
          const float ndcZ = clipPosition.z / clipPosition.w;
          if (!std::isfinite(ndcX) || !std::isfinite(ndcY) ||
              !std::isfinite(ndcZ)) {
            continue;
          }
          ++finiteVertexCount;
          minX = std::min(minX, ndcX);
          minY = std::min(minY, ndcY);
          minZ = std::min(minZ, ndcZ);
          maxX = std::max(maxX, ndcX);
          maxY = std::max(maxY, ndcY);
          maxZ = std::max(maxZ, ndcZ);
          if (ndcX >= -1.0f && ndcX <= 1.0f && ndcY >= -1.0f &&
              ndcY <= 1.0f && ndcZ >= -1.0f && ndcZ <= 1.0f) {
            ++insideClipVertexCount;
          }
        }
      }
      LOG->Trace(
          "PERF_TRACE: RageDisplay_Metal frame=%llu batches=%zu vertices=%zu "
          "direct_vertices=%zu fallback_vertices=%zu textures=%zu "
          "fallback_finite=%zu fallback_inside_clip=%zu "
          "fallback_bounds=(%.3f,%.3f,%.3f)..(%.3f,%.3f,%.3f)",
          static_cast<unsigned long long>(m_iMetalFrames), activeBatchCount,
          directVertexCount + fallbackVertexCount, directVertexCount,
          fallbackVertexCount, textureHandles.size(), finiteVertexCount,
          insideClipVertexCount,
          finiteVertexCount > 0 ? minX : 0.0f,
          finiteVertexCount > 0 ? minY : 0.0f,
          finiteVertexCount > 0 ? minZ : 0.0f,
          finiteVertexCount > 0 ? maxX : 0.0f,
          finiteVertexCount > 0 ? maxY : 0.0f,
          finiteVertexCount > 0 ? maxZ : 0.0f);
    }
    FlushBatches();
  }
  if (m_Window) {
    m_Window->Update();
    const int nativePresentationReason =
        MacOSMetalPresenterConsumeNativePresentationChangeReason();
    if (nativePresentationReason != 0 && m_Presenter && m_bReady &&
        !m_bLayerReconfiguredForResolutionChange) {
      m_Presenter->ReconfigureAttachedLayer(
          m_Window->GetNativeWindowHandle(),
          MacOSNativePresentationReasonNameForMetal(nativePresentationReason));
    }
  }
  ReleasePendingTextureDeletes();
  ProcessStatsOnFlip();
}

void RageDisplay_Metal::ResolutionChanged() {
  if (m_Window == nullptr) {
    return;
  }

  const ActualVideoModeParams previousParams = m_Params;
  m_Params = m_Window->GetActualVideoModeParams();
  RageDisplay::ResolutionChanged();

  bool layerReconfigured = false;
  if (m_Presenter != nullptr && m_bReady) {
    layerReconfigured = m_Presenter->ReconfigureAttachedLayer(
        m_Window->GetNativeWindowHandle(), "resolution_changed");
    m_bLayerReconfiguredForResolutionChange = layerReconfigured;
    if (!layerReconfigured) {
      LOG->Warn(
          "RageDisplay_Metal: layer reconfiguration failed after resize "
          "%dx%d -> %dx%d.",
          previousParams.width, previousParams.height, m_Params.width,
          m_Params.height);
    }
  }
  if (PerfDiagnosticsEnabled()) {
    LOG->Trace(
        "PERF_TRACE: metal_resolution_changed previous=%dx%d current=%dx%d "
        "layer_reconfigured=%d",
        previousParams.width, previousParams.height, m_Params.width,
        m_Params.height, layerReconfigured ? 1 : 0);
  }
}

void RageDisplay_Metal::DrawQuadsInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 4) {
    return;
  }

  const size_t outputVertexCount = static_cast<size_t>(iNumVerts / 4) * 6;
  DrawBatch* directBatch = nullptr;
  MacOSMetalSolidVertex* directVertices = nullptr;
  if (ReserveDirectVertices(
          outputVertexCount, &directBatch, &directVertices)) {
    size_t out = 0;
    for (int i = 0; i + 3 < iNumVerts; i += 4) {
      directVertices[out++] = ToMetalSolidVertex(v[i + 0]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 1]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 2]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 2]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 3]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 0]);
    }
    return;
  }

  DrawBatch& batch = ActiveBatch(
      m_iActiveDrawBatchCount > 0 &&
      m_DrawBatches[m_iActiveDrawBatchCount - 1].vertexBuffer != nullptr);
  if (!ReserveAdditionalVertices(
          &batch.vertices, outputVertexCount, "quads")) {
    return;
  }
  for (int i = 0; i + 3 < iNumVerts; i += 4) {
    AppendTriangle(&batch.vertices, v[i + 0], v[i + 1], v[i + 2]);
    AppendTriangle(&batch.vertices, v[i + 2], v[i + 3], v[i + 0]);
  }
}

void RageDisplay_Metal::DrawQuadStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 4) {
    return;
  }

  const size_t outputVertexCount = static_cast<size_t>(iNumVerts - 2) * 3;
  DrawBatch* directBatch = nullptr;
  MacOSMetalSolidVertex* directVertices = nullptr;
  if (ReserveDirectVertices(
          outputVertexCount, &directBatch, &directVertices)) {
    size_t out = 0;
    for (int i = 0; i + 3 < iNumVerts; i += 2) {
      directVertices[out++] = ToMetalSolidVertex(v[i + 0]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 1]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 2]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 2]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 1]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 3]);
    }
    directBatch->vertexCount -= outputVertexCount - out;
    VertexWriterState& writer =
        m_iCurrentRenderTargetHandle > 0 ? m_RenderTargetVertexWriter
                                         : m_MainVertexWriter;
    writer.usedVertices -= outputVertexCount - out;
    return;
  }

  DrawBatch& batch = ActiveBatch(
      m_iActiveDrawBatchCount > 0 &&
      m_DrawBatches[m_iActiveDrawBatchCount - 1].vertexBuffer != nullptr);
  if (!ReserveAdditionalVertices(
          &batch.vertices, outputVertexCount, "quad_strip")) {
    return;
  }
  for (int i = 0; i + 3 < iNumVerts; i += 2) {
    AppendTriangle(&batch.vertices, v[i + 0], v[i + 1], v[i + 2]);
    AppendTriangle(&batch.vertices, v[i + 2], v[i + 1], v[i + 3]);
  }
}

void RageDisplay_Metal::DrawFanInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 3) {
    return;
  }

  const size_t outputVertexCount = static_cast<size_t>(iNumVerts - 2) * 3;
  DrawBatch* directBatch = nullptr;
  MacOSMetalSolidVertex* directVertices = nullptr;
  if (ReserveDirectVertices(
          outputVertexCount, &directBatch, &directVertices)) {
    size_t out = 0;
    for (int i = 1; i + 1 < iNumVerts; ++i) {
      directVertices[out++] = ToMetalSolidVertex(v[0]);
      directVertices[out++] = ToMetalSolidVertex(v[i]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 1]);
    }
    return;
  }

  DrawBatch& batch = ActiveBatch(
      m_iActiveDrawBatchCount > 0 &&
      m_DrawBatches[m_iActiveDrawBatchCount - 1].vertexBuffer != nullptr);
  if (!ReserveAdditionalVertices(
          &batch.vertices, outputVertexCount, "fan")) {
    return;
  }
  for (int i = 1; i + 1 < iNumVerts; ++i) {
    AppendTriangle(&batch.vertices, v[0], v[i], v[i + 1]);
  }
}

void RageDisplay_Metal::DrawStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 3) {
    return;
  }

  const size_t outputVertexCount = static_cast<size_t>(iNumVerts - 2) * 3;
  DrawBatch* directBatch = nullptr;
  MacOSMetalSolidVertex* directVertices = nullptr;
  if (ReserveDirectVertices(
          outputVertexCount, &directBatch, &directVertices)) {
    size_t out = 0;
    for (int i = 0; i + 2 < iNumVerts; ++i) {
      if ((i % 2) == 0) {
        directVertices[out++] = ToMetalSolidVertex(v[i]);
        directVertices[out++] = ToMetalSolidVertex(v[i + 1]);
        directVertices[out++] = ToMetalSolidVertex(v[i + 2]);
      } else {
        directVertices[out++] = ToMetalSolidVertex(v[i + 1]);
        directVertices[out++] = ToMetalSolidVertex(v[i]);
        directVertices[out++] = ToMetalSolidVertex(v[i + 2]);
      }
    }
    return;
  }

  DrawBatch& batch = ActiveBatch(
      m_iActiveDrawBatchCount > 0 &&
      m_DrawBatches[m_iActiveDrawBatchCount - 1].vertexBuffer != nullptr);
  if (!ReserveAdditionalVertices(
          &batch.vertices, outputVertexCount, "strip")) {
    return;
  }
  for (int i = 0; i + 2 < iNumVerts; ++i) {
    if ((i % 2) == 0) {
      AppendTriangle(&batch.vertices, v[i], v[i + 1], v[i + 2]);
    } else {
      AppendTriangle(&batch.vertices, v[i + 1], v[i], v[i + 2]);
    }
  }
}

void RageDisplay_Metal::DrawTrianglesInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 3) {
    return;
  }

  const size_t outputVertexCount = static_cast<size_t>((iNumVerts / 3) * 3);
  DrawBatch* directBatch = nullptr;
  MacOSMetalSolidVertex* directVertices = nullptr;
  if (ReserveDirectVertices(
          outputVertexCount, &directBatch, &directVertices)) {
    size_t out = 0;
    for (int i = 0; i + 2 < iNumVerts; i += 3) {
      directVertices[out++] = ToMetalSolidVertex(v[i + 0]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 1]);
      directVertices[out++] = ToMetalSolidVertex(v[i + 2]);
    }
    return;
  }

  DrawBatch& batch = ActiveBatch(
      m_iActiveDrawBatchCount > 0 &&
      m_DrawBatches[m_iActiveDrawBatchCount - 1].vertexBuffer != nullptr);
  if (!ReserveAdditionalVertices(
          &batch.vertices, outputVertexCount, "triangles")) {
    return;
  }
  for (int i = 0; i + 2 < iNumVerts; i += 3) {
    AppendTriangle(&batch.vertices, v[i + 0], v[i + 1], v[i + 2]);
  }
}

void RageDisplay_Metal::DrawCompiledGeometryInternal(
    const RageCompiledGeometry* p, int iMeshIndex) {
  const RageCompiledGeometryMetal* metalGeometry =
      dynamic_cast<const RageCompiledGeometryMetal*>(p);
  if (metalGeometry == nullptr) {
    static bool s_bWarnedForeignCompiledGeometry = false;
    if (!s_bWarnedForeignCompiledGeometry) {
      LOG->Warn(
          "RageDisplay_Metal: ignoring compiled geometry from another "
          "renderer implementation.");
      s_bWarnedForeignCompiledGeometry = true;
    }
    return;
  }

  metalGeometry->EmitTo(this, iMeshIndex);
}

RageSurface* RageDisplay_Metal::CreateScreenshot() {
  if (m_Presenter != nullptr) {
    std::vector<uint8_t> pixels;
    int width = 0;
    int height = 0;
    if (m_Presenter->ReadBackOffscreenPresentTextureBGRA8(
            &pixels, &width, &height) &&
        width > 0 && height > 0 &&
        pixels.size() == static_cast<size_t>(width) *
                         static_cast<size_t>(height) * 4) {
      RageSurface* image = CreateSurface(
          width, height, 32,
          0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000);
      if (image != nullptr && image->pixels != nullptr) {
        const size_t srcPitch = static_cast<size_t>(width) * 4;
        if (image->pitch < 0 ||
            static_cast<size_t>(image->pitch) < srcPitch) {
          delete image;
          return nullptr;
        }
        for (int row = 0; row < height; ++row) {
          std::memcpy(
              image->pixels + static_cast<size_t>(row) * image->pitch,
              pixels.data() + static_cast<size_t>(row) * srcPitch,
              srcPitch);
        }
        return image;
      }
      delete image;
    }
  }

  if (m_Window == nullptr) {
    return nullptr;
  }

  NSWindow* window = (__bridge NSWindow*)m_Window->GetNativeWindowHandle();
  if (window == nil) {
    return nullptr;
  }

  // Fallback for early startup or unusual paths where no Metal offscreen
  // present texture has been rendered yet.  This is best-effort only because
  // macOS may require Screen Recording permission for window capture.
  CGImageRef captured = CGWindowListCreateImage(
      CGRectNull, kCGWindowListOptionIncludingWindow,
      static_cast<CGWindowID>([window windowNumber]),
      kCGWindowImageBoundsIgnoreFraming);
  if (captured == nullptr) {
    bool screenCaptureDenied = false;
    if (@available(macOS 10.15, *)) {
      static bool s_bRequestedScreenCaptureAccess = false;
      screenCaptureDenied = !CGPreflightScreenCaptureAccess();
      if (screenCaptureDenied && !s_bRequestedScreenCaptureAccess) {
        s_bRequestedScreenCaptureAccess = true;
        CGRequestScreenCaptureAccess();
      }
    }
    LOG->Warn(
        "RageDisplay_Metal::CreateScreenshot: window capture failed%s. "
        "Metal backbuffer readback was unavailable and the composite fallback "
        "also failed; grant Screen Recording permission to ITGmania, then "
        "restart the game.",
        screenCaptureDenied ? " (Screen Recording permission is not granted)"
                            : "");
    return nullptr;
  }

  const size_t width = CGImageGetWidth(captured);
  const size_t height = CGImageGetHeight(captured);
  if (width == 0 || height == 0 ||
      width > static_cast<size_t>(std::numeric_limits<int>::max()) ||
      height > static_cast<size_t>(std::numeric_limits<int>::max())) {
    CGImageRelease(captured);
    return nullptr;
  }

  RageSurface* image = CreateSurface(
      static_cast<int>(width), static_cast<int>(height), 32,
      0xFF000000, 0x00FF0000, 0x0000FF00, 0x000000FF);
  if (image == nullptr || image->pixels == nullptr) {
    delete image;
    CGImageRelease(captured);
    return nullptr;
  }

  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      image->pixels, width, height, 8, image->pitch, colorSpace,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  if (context == nullptr) {
    CGColorSpaceRelease(colorSpace);
    delete image;
    CGImageRelease(captured);
    return nullptr;
  }

  CGContextDrawImage(
      context,
      CGRectMake(
          0, 0, static_cast<CGFloat>(width), static_cast<CGFloat>(height)),
      captured);
  CGContextRelease(context);
  CGColorSpaceRelease(colorSpace);
  CGImageRelease(captured);

  return image;
}

void RageDisplay_Metal::DrawLineStripInternal(
    const RageSpriteVertex v[], int iNumVerts, float LineWidth) {
  if (v == nullptr || iNumVerts < 2 || LineWidth <= 0.0f) {
    return;
  }
  RageDisplay::DrawLineStripInternal(v, iNumVerts, LineWidth);
}

void RageDisplay_Metal::DrawSymmetricQuadStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 6) {
    return;
  }

  const int iNumPieces = (iNumVerts - 3) / 3;
  const size_t outputVertexCount = static_cast<size_t>(iNumPieces) * 12;
  DrawBatch* directBatch = nullptr;
  MacOSMetalSolidVertex* directVertices = nullptr;
  if (ReserveDirectVertices(
          outputVertexCount, &directBatch, &directVertices)) {
    size_t out = 0;
    for (int i = 0; i < iNumPieces; ++i) {
      const int base = i * 3;
      directVertices[out++] = ToMetalSolidVertex(v[base + 1]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 3]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 0]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 1]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 4]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 3]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 1]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 5]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 4]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 1]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 2]);
      directVertices[out++] = ToMetalSolidVertex(v[base + 5]);
    }
    return;
  }

  DrawBatch& batch = ActiveBatch(
      m_iActiveDrawBatchCount > 0 &&
      m_DrawBatches[m_iActiveDrawBatchCount - 1].vertexBuffer != nullptr);
  if (!ReserveAdditionalVertices(
          &batch.vertices, outputVertexCount, "symmetric_quad_strip")) {
    return;
  }
  for (int i = 0; i < iNumPieces; ++i) {
    const int base = i * 3;
    AppendTriangle(&batch.vertices, v[base + 1], v[base + 3], v[base + 0]);
    AppendTriangle(&batch.vertices, v[base + 1], v[base + 4], v[base + 3]);
    AppendTriangle(&batch.vertices, v[base + 1], v[base + 5], v[base + 4]);
    AppendTriangle(&batch.vertices, v[base + 1], v[base + 2], v[base + 5]);
  }
}

RageCompiledGeometry* RageDisplay_Metal::CreateCompiledGeometry() {
  return new RageCompiledGeometryMetal;
}

void RageDisplay_Metal::DeleteCompiledGeometry(RageCompiledGeometry* p) {
  delete p;
}

std::string RageDisplay_Metal::TryVideoMode(
    const VideoModeParams& p, bool& bNewDeviceOut) {
  if (!m_Window || !m_Presenter) {
    return "Native Metal renderer internal window/presenter is not ready.";
  }

  const ActualVideoModeParams previousParams = m_Params;
  const int previousRequestedRefreshRate = m_iRequestedRefreshRate;
  const int requestedRefreshRate = p.rate;
  const bool hadWorkingPresenter =
      m_bReady && previousParams.width > 0 && previousParams.height > 0;
  m_bReady = false;

  // A presenter reinitialization invalidates direct frame slots.  Discard the
  // unfinished frame before touching the window and finish any deferred
  // texture deletions now that no CPU batch can still reference them.
  ResetVertexWriter(&m_MainVertexWriter, true);
  ResetVertexWriter(&m_RenderTargetVertexWriter, true);
  ClearActiveBatches();
  m_PendingMainDrawBatches.clear();
  m_MetalDrawBatches.clear();
  m_iCurrentRenderTargetHandle = 0;
  ReleasePendingTextureDeletes();

  std::string err = m_Window->TryVideoMode(p, bNewDeviceOut);
  if (!err.empty()) {
    m_bReady = hadWorkingPresenter;
    return err;
  }

  auto initializePresenterForCurrentMode =
      [&](int pacingRefreshRate, std::string* failureOut) -> bool {
    m_Params = m_Window->GetActualVideoModeParams();
    void* nativeWindow = m_Window->GetNativeWindowHandle();
    if (nativeWindow == nullptr) {
      if (failureOut != nullptr) {
        *failureOut = "Native Metal renderer could not access the macOS window.";
      }
      return false;
    }

    const double targetHz =
        MetalDisplayPacingTargetHz(m_Presenter, m_Params, pacingRefreshRate);
    if (!m_Presenter->Initialize(
            nativeWindow, std::max(1, m_Params.width),
            std::max(1, m_Params.height), targetHz, false)) {
      if (failureOut != nullptr) {
        *failureOut = m_Presenter->FailureReason().empty()
                          ? "Native Metal presenter initialization failed."
                          : m_Presenter->FailureReason();
      }
      return false;
    }
    if (!m_Presenter->AttachLayerAsContentView(nativeWindow)) {
      if (failureOut != nullptr) {
        *failureOut = m_Presenter->FailureReason().empty()
                          ? "Native Metal presenter layer attachment failed."
                          : m_Presenter->FailureReason();
      }
      return false;
    }
    const double attachedTargetHz =
        MetalDisplayPacingTargetHz(m_Presenter, m_Params, pacingRefreshRate);
    SetRuntimeFramePacingTargetHz(static_cast<float>(attachedTargetHz));
    return true;
  };

  auto rollbackToPreviousMode = [&](const std::string& originalError) {
    if (!hadWorkingPresenter) {
      m_iRequestedRefreshRate = previousRequestedRefreshRate;
      SetRuntimeFramePacingTargetHz(0.0f);
      return originalError;
    }

    bool rollbackNewDevice = false;
    std::string rollbackErr =
        m_Window->TryVideoMode(previousParams, rollbackNewDevice);
    if (!rollbackErr.empty()) {
      m_bReady = false;
      m_iRequestedRefreshRate = previousRequestedRefreshRate;
      SetRuntimeFramePacingTargetHz(0.0f);
      return originalError + " Rollback to the previous Metal video mode also "
                             "failed: " +
             rollbackErr;
    }

    std::string presenterErr;
    if (!initializePresenterForCurrentMode(
            previousRequestedRefreshRate, &presenterErr)) {
      m_bReady = false;
      m_iRequestedRefreshRate = previousRequestedRefreshRate;
      SetRuntimeFramePacingTargetHz(0.0f);
      return originalError + " Rollback to the previous Metal presenter also "
                             "failed: " +
             presenterErr;
    }

    m_bReady = true;
    m_iRequestedRefreshRate = previousRequestedRefreshRate;
    LOG->Warn(
        "RageDisplay_Metal: video mode change failed and previous mode was "
        "restored: %s",
        originalError.c_str());
    return originalError;
  };

  std::string presenterErr;
  if (!initializePresenterForCurrentMode(
          requestedRefreshRate, &presenterErr)) {
    return rollbackToPreviousMode(presenterErr);
  }

  m_PendingMainDrawBatches.clear();
  DestroyAllTextures();
  bNewDeviceOut = true;

  m_bReady = true;
  m_iRequestedRefreshRate = requestedRefreshRate;
  return std::string();
}
