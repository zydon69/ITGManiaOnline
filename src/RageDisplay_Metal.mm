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
#include "RageSurface.h"
#include "RageSurfaceUtils.h"
#include "RageUtil.h"
#include "arch/LowLevelWindow/LowLevelWindow.h"
#include "arch/LowLevelWindow/MacOSMetalPresenter.h"
#include "global.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

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
  return static_cast<uint8_t>(
      std::clamp(value, 0.0f, 1.0f) * 255.0f + 0.5f);
}

RageVColor ToVertexColor(const RageColor& color) {
  RageVColor out;
  out.r = FloatColorToByte(color.r);
  out.g = FloatColorToByte(color.g);
  out.b = FloatColorToByte(color.b);
  out.a = FloatColorToByte(color.a);
  return out;
}

RageColor ClampColor(const RageColor& color) {
  return RageColor(
      std::clamp(color.r, 0.0f, 1.0f),
      std::clamp(color.g, 0.0f, 1.0f),
      std::clamp(color.b, 0.0f, 1.0f),
      std::clamp(color.a, 0.0f, 1.0f));
}

RageVector3 NormalizeOrDefault(
    const RageVector3& vector, const RageVector3& fallback) {
  const float lengthSq =
      vector.x * vector.x + vector.y * vector.y + vector.z * vector.z;
  if (lengthSq <= 0.000001f) {
    return fallback;
  }
  RageVector3 normalized;
  RageVec3Normalize(&normalized, &vector);
  return normalized;
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
    for (size_t i = 0; i < vMeshes.size(); ++i) {
      const MeshInfo& meshInfo = m_vMeshInfo[i];
      const msMesh& mesh = vMeshes[i];

      for (size_t j = 0; j < mesh.Vertices.size(); ++j) {
        m_vVertices[meshInfo.iVertexStart + j] = mesh.Vertices[j];
      }

      for (size_t j = 0; j < mesh.Triangles.size(); ++j) {
        for (int k = 0; k < 3; ++k) {
          const int vertexIndex =
              meshInfo.iVertexStart + mesh.Triangles[j].nVertexIndices[k];
          m_vTriangles[meshInfo.iTriangleStart + j].nVertexIndices[k] =
              static_cast<uint16_t>(vertexIndex);
        }
      }
    }
  }

  void Draw(int /* iMeshIndex */) const override {}

  void EmitTo(
      RageDisplay_Metal* display, int iMeshIndex,
      const RageVColor& color) const;

 private:
  std::vector<RageModelVertex> m_vVertices;
  std::vector<msTriangle> m_vTriangles;
};

class RageTextureLockMetal : public RageTextureLock {
 public:
  void Lock(uintptr_t textureHandle, RageSurface* surface) override {
    ASSERT(m_TextureHandle == 0);
    ASSERT(surface != nullptr);
    ASSERT(surface->pixels == nullptr);

    m_TextureHandle = textureHandle;
    const size_t bufferSize =
        static_cast<size_t>(std::max(0, surface->h)) *
        static_cast<size_t>(std::max(0, surface->pitch));
    m_Buffer.assign(bufferSize, 0);
    surface->pixels = m_Buffer.empty() ? nullptr : m_Buffer.data();
    surface->pixels_owned = false;
  }

  void Unlock(RageSurface* surface, bool changed = true) override {
    ASSERT(surface != nullptr);
    if (changed && m_TextureHandle != 0 && surface->pixels != nullptr) {
      DISPLAY->UpdateTexture(
          m_TextureHandle, surface, 0, 0, surface->w, surface->h);
    }

    surface->pixels = nullptr;
    m_TextureHandle = 0;
    m_Buffer.clear();
  }

 private:
  uintptr_t m_TextureHandle = 0;
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

RageVector2 TransformTextureCoord(
    const RageVector2& texcoord, const RageMatrix& textureMatrix,
    const RageVector2& textureMatrixScale) {
  RageVector4 original(texcoord.x, texcoord.y, 0.0f, 1.0f);
  RageVector4 transformed;
  RageVec4TransformCoord(&transformed, &original, &textureMatrix);

  return RageVector2(
      transformed.x * textureMatrixScale.x +
          texcoord.x * (1.0f - textureMatrixScale.x),
      transformed.y * textureMatrixScale.y +
          texcoord.y * (1.0f - textureMatrixScale.y));
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
    const RageVColor& color, const RageVector2& textureMatrixScale,
    const RageMatrix& modelViewProjection, const RageMatrix& textureMatrix,
    float zBias) {
  RageVector4 transformed(position.x, position.y, position.z, 1.0f);
  RageVec4TransformCoord(&transformed, &transformed, &modelViewProjection);
  ApplyDepthRange(zBias, &transformed);
  const RageVector2 transformedTexcoord =
      TransformTextureCoord(texcoord, textureMatrix, textureMatrixScale);

  MacOSMetalSolidVertex out;
  out.x = transformed.x;
  out.y = transformed.y;
  out.z = transformed.z;
  out.w = transformed.w;
  out.u = transformedTexcoord.x;
  out.v = transformedTexcoord.y;
  out.r = ByteColorToFloat(color.r);
  out.g = ByteColorToFloat(color.g);
  out.b = ByteColorToFloat(color.b);
  out.a = ByteColorToFloat(color.a);
  return out;
}

MacOSMetalSolidVertex ToMetalSolidVertex(
    const RageSpriteVertex& v, const RageMatrix& modelViewProjection,
    const RageMatrix& textureMatrix, float zBias) {
  return ToMetalSolidVertex(
      v.p, v.t, v.c, RageVector2(1.0f, 1.0f), modelViewProjection,
      textureMatrix, zBias);
}

void AppendTriangle(
    std::vector<MacOSMetalSolidVertex>* vertices,
    const RageSpriteVertex& a, const RageSpriteVertex& b,
    const RageSpriteVertex& c, const RageMatrix& modelViewProjection,
    const RageMatrix& textureMatrix, float zBias) {
  vertices->push_back(
      ToMetalSolidVertex(a, modelViewProjection, textureMatrix, zBias));
  vertices->push_back(
      ToMetalSolidVertex(b, modelViewProjection, textureMatrix, zBias));
  vertices->push_back(
      ToMetalSolidVertex(c, modelViewProjection, textureMatrix, zBias));
}

RageColor RageDisplay_Metal::ComputeModelColor(const RageVector3& normal) const {
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
  }
  if (!anyLight) {
    lit.r += m_MaterialAmbient.r + m_MaterialDiffuse.r;
    lit.g += m_MaterialAmbient.g + m_MaterialDiffuse.g;
    lit.b += m_MaterialAmbient.b + m_MaterialDiffuse.b;
  }
  return ClampColor(lit);
}

void RageCompiledGeometryMetal::EmitTo(
    RageDisplay_Metal* display, int iMeshIndex,
    const RageVColor& fallbackColor) const {
  if (display == nullptr || iMeshIndex < 0 ||
      static_cast<size_t>(iMeshIndex) >= m_vMeshInfo.size()) {
    return;
  }

  const MeshInfo& meshInfo = m_vMeshInfo[iMeshIndex];
  if (meshInfo.iTriangleCount <= 0) {
    return;
  }

  RageDisplay_Metal::DrawBatch& batch = display->ActiveBatch();
  batch.vertices.reserve(
      batch.vertices.size() +
      static_cast<size_t>(meshInfo.iTriangleCount) * 3);

  const RageMatrix modelViewProjection = display->CurrentModelViewProjection();
  const RageMatrix textureMatrix = display->CurrentTextureMatrix();
  RageMatrix modelView;
  RageMatrixMultiply(&modelView, display->GetViewTop(), display->GetWorldTop());
  for (int i = 0; i < meshInfo.iTriangleCount; ++i) {
    const msTriangle& tri =
        m_vTriangles[meshInfo.iTriangleStart + static_cast<size_t>(i)];
    for (int k = 0; k < 3; ++k) {
      const uint16_t vertexIndex = tri.nVertexIndices[k];
      if (vertexIndex >= m_vVertices.size()) {
        continue;
      }
      const RageModelVertex& modelVertex = m_vVertices[vertexIndex];
      RageVector3 transformedNormal;
      RageVec3TransformNormal(&transformedNormal, &modelVertex.n, &modelView);
      RageVector3 position = modelVertex.p;
      RageColor litColor = display->ComputeModelColor(transformedNormal);
      if (display->m_iCelShadedStage == 1) {
        position += modelVertex.n * 0.125f;
        litColor = RageColor(0.25f, 0.125f, 0.125f, 1.0f);
      } else if (display->m_iCelShadedStage == 2) {
        litColor.a = 1.0f;
      }
      const RageVector2 texcoord =
          batch.sphereMapping
              ? SphereMapTextureCoord(transformedNormal)
              : modelVertex.t;
      batch.vertices.push_back(ToMetalSolidVertex(
          position, texcoord, ToVertexColor(litColor),
          modelVertex.TextureMatrixScale, modelViewProjection, textureMatrix,
          batch.zBias));
    }
  }
}

RageDisplay_Metal::RageDisplay_Metal()
    : m_TextureHandles{},
      m_BlendMode(BLEND_NORMAL),
      m_TextureModes{},
      m_EffectMode(EffectMode_Normal),
      m_iCelShadedStage(0),
      m_bSphereMapping(false),
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
      m_bLighting(false),
      m_Lights(4),
      m_iNextTextureHandle(1),
      m_bReady(false) {
  m_TextureModes.fill(TextureMode_Modulate);
  m_TextureFiltering.fill(true);
  m_Textures.resize(1);
  LOG->MapLog("renderer", "Current renderer: metal");
}

RageDisplay_Metal::~RageDisplay_Metal() {
  DestroyAllTextures();
  if (m_Presenter) {
    m_Presenter->Shutdown();
  }
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
  ASSERT(pf >= 0 && pf < NUM_RagePixelFormat);
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
  texture->hasRendered = false;
  texture->preserveNextRender = false;
}

bool RageDisplay_Metal::UploadTexturePixels(
    MetalTexture* texture, RageSurface* img, int xoffset, int yoffset,
    int width, int height) {
  if (texture == nullptr || img == nullptr || m_Presenter == nullptr ||
      width <= 0 || height <= 0 || texture->width <= 0 ||
      texture->height <= 0) {
    return false;
  }

  std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4, 0);
  if (img->pixels != nullptr) {
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
  }

  const size_t bytesPerRow = static_cast<size_t>(width) * 4;
  if (texture->texture != nullptr) {
    return m_Presenter->UpdateRGBA8Texture(
        texture->texture, xoffset, yoffset, width, height, pixels.data(),
        bytesPerRow);
  }

  std::vector<uint8_t> fullPixels(
      static_cast<size_t>(texture->width) * texture->height * 4, 0);
  for (int y = 0; y < height; ++y) {
    std::memcpy(
        fullPixels.data() +
            (static_cast<size_t>(y + yoffset) * texture->width + xoffset) * 4,
        pixels.data() + static_cast<size_t>(y) * width * 4,
        bytesPerRow);
  }

  void* metalTexture = m_Presenter->CreateRGBA8Texture(
      texture->width, texture->height, fullPixels.data(),
      static_cast<size_t>(texture->width) * 4);
  if (metalTexture == nullptr) {
    return false;
  }

  ReleaseTexture(texture);
  texture->texture = metalTexture;
  return true;
}

uintptr_t RageDisplay_Metal::CreateTexture(
    RagePixelFormat pixfmt, RageSurface* img,
    bool /* bGenerateMipMaps */) {
  if (!SupportsTextureFormat(pixfmt) || img == nullptr || img->w <= 0 ||
      img->h <= 0) {
    return 0;
  }

  const uintptr_t handle = m_iNextTextureHandle++;
  if (handle >= m_Textures.size()) {
    m_Textures.resize(handle + 1);
  }

  MetalTexture& texture = m_Textures[handle];
  texture.width = power_of_two(img->w);
  texture.height = power_of_two(img->h);
  if (!UploadTexturePixels(&texture, img, 0, 0, img->w, img->h)) {
    ReleaseTexture(&texture);
    return 0;
  }

  return handle;
}

void RageDisplay_Metal::UpdateTexture(
    uintptr_t iTexHandle, RageSurface* img, int xoffset, int yoffset,
    int width, int height) {
  if (iTexHandle == 0 || iTexHandle >= m_Textures.size()) {
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
      xoffset + width > texture.width || yoffset + height > texture.height) {
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

  const int textureWidth = power_of_two(param.iWidth);
  const int textureHeight = power_of_two(param.iHeight);
  void* colorTexture =
      m_Presenter->CreateBGRA8RenderTargetTexture(textureWidth, textureHeight);
  if (colorTexture == nullptr) {
    LOG->Warn(
        "RageDisplay_Metal: failed to create render target color texture "
        "%dx%d.",
        textureWidth, textureHeight);
    return 0;
  }

  void* depthTexture =
      m_Presenter->CreateDepthRenderTargetTexture(textureWidth, textureHeight);
  if (depthTexture == nullptr) {
    LOG->Warn(
        "RageDisplay_Metal: failed to create render target depth texture "
        "%dx%d.",
        textureWidth, textureHeight);
    m_Presenter->ReleaseTexture(colorTexture);
    return 0;
  }

  const uintptr_t handle = m_iNextTextureHandle++;
  if (handle >= m_Textures.size()) {
    m_Textures.resize(handle + 1);
  }

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
        "requested_float=%d actual_depth=1 actual_format=BGRA8Unorm",
        static_cast<unsigned long>(handle), param.iWidth, param.iHeight,
        textureWidth, textureHeight, param.bWithDepthBuffer ? 1 : 0,
        param.bWithAlpha ? 1 : 0, param.bFloat ? 1 : 0);
  }
  return handle;
}

uintptr_t RageDisplay_Metal::GetRenderTarget() {
  return m_iCurrentRenderTargetHandle;
}

void RageDisplay_Metal::SetRenderTarget(
    uintptr_t iHandle, bool bPreserveTexture) {
  const uintptr_t previousHandle = m_iCurrentRenderTargetHandle;

  FlushBatches();

  if (iHandle == 0) {
    m_iCurrentRenderTargetHandle = 0;
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
  const MetalTexture& texture = m_Textures[iTexHandle];
  if (PerfDiagnosticsEnabled() && texture.renderTarget) {
    LOG->Trace(
        "PERF_TRACE: metal_render_target_deleted handle=%lu has_rendered=%d "
        "logical=%dx%d texture=%dx%d",
        static_cast<unsigned long>(iTexHandle), texture.hasRendered ? 1 : 0,
        texture.renderWidth, texture.renderHeight, texture.width,
        texture.height);
  }
  ReleaseTexture(&m_Textures[iTexHandle]);
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
  m_TextureHandles.fill(0);
  m_iCurrentRenderTargetHandle = 0;
  m_iNextTextureHandle = 1;
}

void RageDisplay_Metal::SetTexture(TextureUnit tu, uintptr_t iTexture) {
  if (tu < 0 || tu >= NUM_TextureUnit) {
    return;
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
  m_fZBias = std::clamp(bias, 0.0f, 1.0f);
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
    const RageColor& diffuse, const RageColor& /* specular */,
    float /* shininess */) {
  m_MaterialDiffuse = diffuse;
  m_MaterialAmbient = ambient;
  m_MaterialEmissive = emissive;
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
    const RageColor& /* specular */, const RageVector3& dir) {
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
  light.direction = dir;
}

void RageDisplay_Metal::SetSphereEnvironmentMapping(
    TextureUnit tu, bool enabled) {
  if (tu < 0 || tu >= NUM_TextureUnit) {
    return;
  }
  m_bSphereMapping = enabled;
}

void RageDisplay_Metal::SetCelShaded(int stage) {
  if (stage < 0 || stage > 2) {
    stage = 0;
  }
  m_iCelShadedStage = stage;
}

RageDisplay_Metal::DrawBatch& RageDisplay_Metal::ActiveBatch() {
  if (m_DrawBatches.empty() ||
      m_DrawBatches.back().textureHandles != m_TextureHandles ||
      m_DrawBatches.back().blendMode != m_BlendMode ||
      m_DrawBatches.back().textureModes != m_TextureModes ||
      m_DrawBatches.back().effectMode != m_EffectMode ||
      m_DrawBatches.back().celStage != m_iCelShadedStage ||
      m_DrawBatches.back().sphereMapping != m_bSphereMapping ||
      m_DrawBatches.back().zBias != m_fZBias ||
      m_DrawBatches.back().zTestMode != m_ZTestMode ||
      m_DrawBatches.back().cullMode != m_CullMode ||
      m_DrawBatches.back().textureWrapping != m_TextureWrapping ||
      m_DrawBatches.back().textureFiltering != m_TextureFiltering ||
      m_DrawBatches.back().zWrite != m_bZWrite ||
      m_DrawBatches.back().alphaTest != m_bAlphaTest) {
    DrawBatch batch;
    batch.textureHandles = m_TextureHandles;
    batch.blendMode = m_BlendMode;
    batch.textureModes = m_TextureModes;
    batch.effectMode = m_EffectMode;
    batch.celStage = m_iCelShadedStage;
    batch.sphereMapping = m_bSphereMapping;
    batch.zBias = m_fZBias;
    batch.zTestMode = m_ZTestMode;
    batch.cullMode = m_CullMode;
    batch.textureWrapping = m_TextureWrapping;
    batch.textureFiltering = m_TextureFiltering;
    batch.zWrite = m_bZWrite;
    batch.alphaTest = m_bAlphaTest;
    m_DrawBatches.push_back(batch);
  }
  return m_DrawBatches.back();
}

void RageDisplay_Metal::BuildMetalBatches(
    const std::vector<DrawBatch>& batches,
    std::vector<MacOSMetalDrawBatch>* metalBatches) const {
  if (metalBatches == nullptr) {
    return;
  }

  metalBatches->clear();
  metalBatches->reserve(batches.size());
  for (const DrawBatch& batch : batches) {
    if (batch.vertices.empty()) {
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
    int texture2Width = 1;
    if (batch.textureHandles[TextureUnit_2] > 0 &&
        batch.textureHandles[TextureUnit_2] < m_Textures.size()) {
      if (m_iCurrentRenderTargetHandle == 0 ||
          batch.textureHandles[TextureUnit_2] != m_iCurrentRenderTargetHandle) {
        texture2 = m_Textures[batch.textureHandles[TextureUnit_2]].texture;
        texture2Width =
            std::max(1, m_Textures[batch.textureHandles[TextureUnit_2]].width);
      }
    }
    metalBatches->push_back(
        {batch.vertices.data(), batch.vertices.size(), texture, textureWidth,
         texture2, texture2Width,
         batch.blendMode, batch.textureModes[TextureUnit_1], batch.effectMode,
         batch.celStage,
         batch.zTestMode,
         batch.cullMode, batch.textureWrapping[TextureUnit_1],
         batch.textureFiltering[TextureUnit_1],
         batch.zWrite, batch.alphaTest});
  }
}

void RageDisplay_Metal::FlushBatches() {
  if (!m_bReady || m_Presenter == nullptr) {
    m_DrawBatches.clear();
    return;
  }

  std::vector<DrawBatch> batches;
  batches.swap(m_DrawBatches);
  std::vector<MacOSMetalDrawBatch> metalBatches;
  BuildMetalBatches(batches, &metalBatches);

  if (m_iCurrentRenderTargetHandle > 0 &&
      m_iCurrentRenderTargetHandle < m_Textures.size()) {
    MetalTexture& target = m_Textures[m_iCurrentRenderTargetHandle];
    if (!target.renderTarget || target.texture == nullptr) {
      LOG->Warn(
          "RageDisplay_Metal: active render target became invalid handle=%lu.",
          static_cast<unsigned long>(m_iCurrentRenderTargetHandle));
      m_iCurrentRenderTargetHandle = 0;
      return;
    }
    const bool preserveColor = target.preserveNextRender && target.hasRendered;
    const int viewportWidth =
        std::min(target.renderWidth > 0 ? target.renderWidth : target.width,
                 target.width);
    const int viewportHeight =
        std::min(target.renderHeight > 0 ? target.renderHeight : target.height,
                 target.height);
    const bool rendered = m_Presenter->RenderSolidBatchesToTexture(
        target.texture, target.depthTexture, metalBatches.data(),
        metalBatches.size(), preserveColor, true,
        0.0, 0.0, 0.0, 0.0, viewportWidth, viewportHeight);
    if (rendered) {
      target.hasRendered = true;
      target.preserveNextRender = true;
    } else {
      LOG->Warn(
          "RageDisplay_Metal: render target submit failed handle=%lu "
          "batches=%zu.",
          static_cast<unsigned long>(m_iCurrentRenderTargetHandle),
          metalBatches.size());
      target.preserveNextRender = preserveColor;
    }
    m_bClearDepthNextFrame = false;
    return;
  }

  const double targetHz =
      m_Params.rate > 1 ? static_cast<double>(m_Params.rate) : 60.0;
  const bool presented = m_Presenter->PresentSolidBatches(
      metalBatches.data(), metalBatches.size(), true,
      0.04, 0.055, 0.075, 1.0, targetHz);
  m_bClearDepthNextFrame = false;
  if (!presented) {
    static uint64_t s_iSkippedClearFrames = 0;
    ++s_iSkippedClearFrames;
    if (s_iSkippedClearFrames <= 3 || s_iSkippedClearFrames % 600 == 0) {
      LOG->Warn(
          "RageDisplay_Metal: clear present skipped; frames=%llu.",
          static_cast<unsigned long long>(s_iSkippedClearFrames));
    }
  }
}

void RageDisplay_Metal::EndFrame() {
  if (m_bReady && m_Presenter) {
    const std::vector<DrawBatch>& batches = m_DrawBatches;
    static uint64_t s_iMetalFrames = 0;
    ++s_iMetalFrames;
    if (PerfDiagnosticsEnabled() &&
        (s_iMetalFrames <= 5 || s_iMetalFrames % 600 == 0)) {
      size_t vertexCount = 0;
      size_t finiteVertexCount = 0;
      size_t insideClipVertexCount = 0;
      float minX = std::numeric_limits<float>::infinity();
      float minY = std::numeric_limits<float>::infinity();
      float minZ = std::numeric_limits<float>::infinity();
      float maxX = -std::numeric_limits<float>::infinity();
      float maxY = -std::numeric_limits<float>::infinity();
      float maxZ = -std::numeric_limits<float>::infinity();
      std::set<uintptr_t> textureHandles;
      for (const DrawBatch& batch : batches) {
        vertexCount += batch.vertices.size();
        for (uintptr_t textureHandle : batch.textureHandles) {
          if (textureHandle != 0) {
            textureHandles.insert(textureHandle);
          }
        }
        for (const MacOSMetalSolidVertex& vertex : batch.vertices) {
          if (!std::isfinite(vertex.x) || !std::isfinite(vertex.y) ||
              !std::isfinite(vertex.z) || !std::isfinite(vertex.w) ||
              vertex.w == 0.0f) {
            continue;
          }
          const float ndcX = vertex.x / vertex.w;
          const float ndcY = vertex.y / vertex.w;
          const float ndcZ = vertex.z / vertex.w;
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
          "textures=%zu finite=%zu inside_clip=%zu "
          "bounds=(%.3f,%.3f,%.3f)..(%.3f,%.3f,%.3f)",
          static_cast<unsigned long long>(s_iMetalFrames), batches.size(),
          vertexCount, textureHandles.size(), finiteVertexCount,
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
  }
  ProcessStatsOnFlip();
}

void RageDisplay_Metal::DrawQuadsInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 4) {
    return;
  }

  DrawBatch& batch = ActiveBatch();
  batch.vertices.reserve(
      batch.vertices.size() + static_cast<size_t>(iNumVerts / 4) * 6);
  const RageMatrix modelViewProjection = CurrentModelViewProjection();
  const RageMatrix textureMatrix = CurrentTextureMatrix();
  for (int i = 0; i + 3 < iNumVerts; i += 4) {
    AppendTriangle(
        &batch.vertices, v[i + 0], v[i + 1], v[i + 2],
        modelViewProjection, textureMatrix, batch.zBias);
    AppendTriangle(
        &batch.vertices, v[i + 2], v[i + 3], v[i + 0],
        modelViewProjection, textureMatrix, batch.zBias);
  }
}

void RageDisplay_Metal::DrawQuadStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 4) {
    return;
  }

  DrawBatch& batch = ActiveBatch();
  batch.vertices.reserve(
      batch.vertices.size() + static_cast<size_t>(iNumVerts - 2) * 3);
  const RageMatrix modelViewProjection = CurrentModelViewProjection();
  const RageMatrix textureMatrix = CurrentTextureMatrix();
  for (int i = 0; i + 3 < iNumVerts; i += 2) {
    AppendTriangle(
        &batch.vertices, v[i + 0], v[i + 1], v[i + 2],
        modelViewProjection, textureMatrix, batch.zBias);
    AppendTriangle(
        &batch.vertices, v[i + 1], v[i + 2], v[i + 3],
        modelViewProjection, textureMatrix, batch.zBias);
  }
}

void RageDisplay_Metal::DrawFanInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 3) {
    return;
  }

  DrawBatch& batch = ActiveBatch();
  batch.vertices.reserve(
      batch.vertices.size() + static_cast<size_t>(iNumVerts - 2) * 3);
  const RageMatrix modelViewProjection = CurrentModelViewProjection();
  const RageMatrix textureMatrix = CurrentTextureMatrix();
  for (int i = 1; i + 1 < iNumVerts; ++i) {
    AppendTriangle(
        &batch.vertices, v[0], v[i], v[i + 1], modelViewProjection,
        textureMatrix, batch.zBias);
  }
}

void RageDisplay_Metal::DrawStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 3) {
    return;
  }

  DrawBatch& batch = ActiveBatch();
  batch.vertices.reserve(
      batch.vertices.size() + static_cast<size_t>(iNumVerts - 2) * 3);
  const RageMatrix modelViewProjection = CurrentModelViewProjection();
  const RageMatrix textureMatrix = CurrentTextureMatrix();
  for (int i = 0; i + 2 < iNumVerts; ++i) {
    if ((i % 2) == 0) {
      AppendTriangle(
          &batch.vertices, v[i], v[i + 1], v[i + 2],
          modelViewProjection, textureMatrix, batch.zBias);
    } else {
      AppendTriangle(
          &batch.vertices, v[i + 1], v[i], v[i + 2],
          modelViewProjection, textureMatrix, batch.zBias);
    }
  }
}

void RageDisplay_Metal::DrawTrianglesInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  if (v == nullptr || iNumVerts < 3) {
    return;
  }

  DrawBatch& batch = ActiveBatch();
  batch.vertices.reserve(
      batch.vertices.size() + static_cast<size_t>(iNumVerts));
  const RageMatrix modelViewProjection = CurrentModelViewProjection();
  const RageMatrix textureMatrix = CurrentTextureMatrix();
  for (int i = 0; i + 2 < iNumVerts; i += 3) {
    AppendTriangle(
        &batch.vertices, v[i + 0], v[i + 1], v[i + 2],
        modelViewProjection, textureMatrix, batch.zBias);
  }
}

void RageDisplay_Metal::DrawCompiledTriangles(
    const std::vector<RageSpriteVertex>& vertices) {
  if (vertices.empty()) {
    return;
  }
  DrawTrianglesInternal(vertices.data(), static_cast<int>(vertices.size()));
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

  const bool translucentModel = m_MaterialDiffuse.a < 0.999f;
  const CullMode previousCullMode = m_CullMode;
  const bool previousZWrite = m_bZWrite;
  if (translucentModel) {
    m_CullMode = CULL_NONE;
    m_bZWrite = false;
  }
  metalGeometry->EmitTo(this, iMeshIndex, ToVertexColor(m_MaterialDiffuse));
  if (translucentModel) {
    m_CullMode = previousCullMode;
    m_bZWrite = previousZWrite;
  }
}

RageSurface* RageDisplay_Metal::CreateScreenshot() {
  if (m_Window == nullptr) {
    return nullptr;
  }

  NSWindow* window = (__bridge NSWindow*)m_Window->GetNativeWindowHandle();
  if (window == nil) {
    return nullptr;
  }

  CGImageRef captured = CGWindowListCreateImage(
      CGRectNull, kCGWindowListOptionIncludingWindow,
      static_cast<CGWindowID>([window windowNumber]),
      kCGWindowImageBoundsIgnoreFraming);
  if (captured == nullptr) {
    LOG->Warn("RageDisplay_Metal::CreateScreenshot: window capture failed.");
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
  DrawBatch& batch = ActiveBatch();
  batch.vertices.reserve(
      batch.vertices.size() + static_cast<size_t>(iNumPieces) * 12);
  const RageMatrix modelViewProjection = CurrentModelViewProjection();
  const RageMatrix textureMatrix = CurrentTextureMatrix();
  for (int i = 0; i < iNumPieces; ++i) {
    const int base = i * 3;
    AppendTriangle(
        &batch.vertices, v[base + 1], v[base + 3], v[base + 0],
        modelViewProjection, textureMatrix, batch.zBias);
    AppendTriangle(
        &batch.vertices, v[base + 1], v[base + 4], v[base + 3],
        modelViewProjection, textureMatrix, batch.zBias);
    AppendTriangle(
        &batch.vertices, v[base + 1], v[base + 5], v[base + 4],
        modelViewProjection, textureMatrix, batch.zBias);
    AppendTriangle(
        &batch.vertices, v[base + 1], v[base + 2], v[base + 5],
        modelViewProjection, textureMatrix, batch.zBias);
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

  m_bReady = false;
  DestroyAllTextures();
  m_Presenter->Shutdown();

  std::string err = m_Window->TryVideoMode(p, bNewDeviceOut);
  if (!err.empty()) {
    return err;
  }
  bNewDeviceOut = true;

  m_Params = m_Window->GetActualVideoModeParams();
  void* nativeWindow = m_Window->GetNativeWindowHandle();
  if (nativeWindow == nullptr) {
    return "Native Metal renderer could not access the macOS window.";
  }

  const double targetHz =
      m_Params.rate > 1 ? static_cast<double>(m_Params.rate) : 60.0;
  if (!m_Presenter->Initialize(
          nativeWindow, std::max(1, m_Params.width),
          std::max(1, m_Params.height), targetHz, false)) {
    return m_Presenter->FailureReason().empty()
               ? "Native Metal presenter initialization failed."
               : m_Presenter->FailureReason();
  }
  if (!m_Presenter->AttachLayerAsContentView(nativeWindow)) {
    return m_Presenter->FailureReason().empty()
               ? "Native Metal presenter layer attachment failed."
               : m_Presenter->FailureReason();
  }

  m_bReady = true;
  return std::string();
}
