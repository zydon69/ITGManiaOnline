/* RageDisplay_Metal - Native Metal renderer entry point. */

#include "RageDisplay_Metal.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "DisplaySpec.h"
#include "ModelTypes.h"
#include "RageDisplay.h"
#include "RageLog.h"
#include "RageMath.h"
#include "RageSurface.h"
#include "RageSurfaceUtils.h"
#include "RageUtil.h"
#include "arch/LowLevelWindow/LowLevelWindow.h"
#include "arch/LowLevelWindow/MacOSMetalPresenter.h"
#include "global.h"

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

class RageCompiledGeometryMetalStub : public RageCompiledGeometry {
 public:
  void Allocate(const std::vector<msMesh>&) override {}
  void Change(const std::vector<msMesh>&) override {}
  void Draw(int /* iMeshIndex */) const override {}
};

float ByteColorToFloat(uint8_t value) {
  return static_cast<float>(value) / 255.0f;
}

RageMatrix RageDisplay_Metal::CurrentModelViewProjection() const {
  RageMatrix projection;
  RageMatrixMultiply(&projection, GetCentering(), GetProjectionTop());

  RageMatrix modelView;
  RageMatrixMultiply(&modelView, GetViewTop(), GetWorldTop());

  RageMatrix modelViewProjection;
  RageMatrixMultiply(&modelViewProjection, &modelView, &projection);
  return modelViewProjection;
}

MacOSMetalSolidVertex ToMetalSolidVertex(
    const RageSpriteVertex& v, const RageMatrix& modelViewProjection) {
  RageVector3 transformed;
  RageVec3TransformCoord(&transformed, &v.p, &modelViewProjection);

  MacOSMetalSolidVertex out;
  out.x = transformed.x;
  out.y = transformed.y;
  out.z = transformed.z;
  out.u = v.t.x;
  out.v = v.t.y;
  out.r = ByteColorToFloat(v.c.r);
  out.g = ByteColorToFloat(v.c.g);
  out.b = ByteColorToFloat(v.c.b);
  out.a = ByteColorToFloat(v.c.a);
  return out;
}

void AppendTriangle(
    std::vector<MacOSMetalSolidVertex>* vertices,
    const RageSpriteVertex& a, const RageSpriteVertex& b,
    const RageSpriteVertex& c, const RageMatrix& modelViewProjection) {
  vertices->push_back(ToMetalSolidVertex(a, modelViewProjection));
  vertices->push_back(ToMetalSolidVertex(b, modelViewProjection));
  vertices->push_back(ToMetalSolidVertex(c, modelViewProjection));
}

RageDisplay_Metal::RageDisplay_Metal()
    : m_iActiveTextureHandle(0), m_iNextTextureHandle(1), m_bReady(false) {
  m_Textures.resize(1);
  LOG->MapLog("renderer", "Current renderer: metal");
}

RageDisplay_Metal::~RageDisplay_Metal() {
  ClearAllTextures();
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
      "RageDisplay_Metal initialized in hello-frame mode: size=%dx%d "
      "rate=%d windowed=%d",
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
    case RagePixelFormat_RGB8:
    case RagePixelFormat_BGR8:
      return true;
    default:
      return false;
  }
}

void RageDisplay_Metal::ReleaseTexture(MetalTexture* texture) {
  if (texture == nullptr) {
    return;
  }
  if (texture->texture != nullptr && m_Presenter) {
    m_Presenter->ReleaseTexture(texture->texture);
  }
  texture->texture = nullptr;
  texture->width = 0;
  texture->height = 0;
}

bool RageDisplay_Metal::UploadTexturePixels(
    MetalTexture* texture, RageSurface* img, int xoffset, int yoffset,
    int width, int height) {
  if (texture == nullptr || img == nullptr || m_Presenter == nullptr ||
      width <= 0 || height <= 0 || texture->width <= 0 ||
      texture->height <= 0) {
    return false;
  }

  const RagePixelFormatDesc* rgbaDesc =
      GetPixelFormatDesc(RagePixelFormat_RGBA8);
  std::vector<uint8_t> pixels(
      static_cast<size_t>(texture->width) * texture->height * 4, 0);
  if (img->pixels != nullptr) {
    RageSurface* rgba = CreateSurface(
        width, height, rgbaDesc->bpp, rgbaDesc->masks[0], rgbaDesc->masks[1],
        rgbaDesc->masks[2], rgbaDesc->masks[3]);
    if (rgba == nullptr) {
      return false;
    }
    RageSurfaceUtils::Blit(img, rgba, width, height);
    for (int y = 0; y < height; ++y) {
      const uint8_t* src = rgba->pixels + static_cast<size_t>(y) * rgba->pitch;
      uint8_t* dst =
          pixels.data() +
          (static_cast<size_t>(y + yoffset) * texture->width + xoffset) * 4;
      std::memcpy(dst, src, static_cast<size_t>(width) * 4);
    }
    delete rgba;
  }

  void* metalTexture = m_Presenter->CreateRGBA8Texture(
      texture->width, texture->height, pixels.data(),
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

  if (xoffset != 0 || yoffset != 0 || width != texture.width ||
      height != texture.height) {
    static bool s_bWarnedPartialTextureUpdate = false;
    if (!s_bWarnedPartialTextureUpdate) {
      LOG->Warn(
          "RageDisplay_Metal: partial texture updates are rebuilt as full "
          "textures in the experimental renderer.");
      s_bWarnedPartialTextureUpdate = true;
    }
  }
  texture.width = power_of_two(width);
  texture.height = power_of_two(height);
  UploadTexturePixels(&texture, img, 0, 0, width, height);
}

void RageDisplay_Metal::DeleteTexture(uintptr_t iTexHandle) {
  if (iTexHandle == 0 || iTexHandle >= m_Textures.size()) {
    return;
  }
  ReleaseTexture(&m_Textures[iTexHandle]);
}

void RageDisplay_Metal::ClearAllTextures() {
  for (MetalTexture& texture : m_Textures) {
    ReleaseTexture(&texture);
  }
  m_Textures.clear();
  m_Textures.resize(1);
  m_iActiveTextureHandle = 0;
}

void RageDisplay_Metal::SetTexture(TextureUnit tu, uintptr_t iTexture) {
  if (tu != TextureUnit_1) {
    return;
  }
  m_iActiveTextureHandle = iTexture;
}

RageDisplay_Metal::DrawBatch& RageDisplay_Metal::ActiveBatch() {
  if (m_DrawBatches.empty() ||
      m_DrawBatches.back().textureHandle != m_iActiveTextureHandle) {
    DrawBatch batch;
    batch.textureHandle = m_iActiveTextureHandle;
    m_DrawBatches.push_back(batch);
  }
  return m_DrawBatches.back();
}

void RageDisplay_Metal::EndFrame() {
  if (m_bReady && m_Presenter) {
    const double targetHz =
        m_Params.rate > 1 ? static_cast<double>(m_Params.rate) : 60.0;
    std::vector<DrawBatch> batches;
    batches.swap(m_DrawBatches);
    if (batches.empty()) {
      DrawBatch batch;
      batch.vertices.push_back(
          {-0.95f, 0.95f, 0.0f, 0.0f, 0.0f, 0.15f, 0.85f, 1.0f, 1.0f});
      batch.vertices.push_back(
          {-0.70f, 0.95f, 0.0f, 0.0f, 0.0f, 1.0f, 0.35f, 0.55f, 1.0f});
      batch.vertices.push_back(
          {-0.95f, 0.70f, 0.0f, 0.0f, 0.0f, 0.95f, 0.95f, 0.2f, 1.0f});
      batches.push_back(batch);
    }
    std::vector<MacOSMetalDrawBatch> metalBatches;
    metalBatches.reserve(batches.size());
    for (const DrawBatch& batch : batches) {
      if (batch.vertices.empty()) {
        continue;
      }
      void* texture = nullptr;
      if (batch.textureHandle > 0 && batch.textureHandle < m_Textures.size()) {
        texture = m_Textures[batch.textureHandle].texture;
      }
      metalBatches.push_back(
          {batch.vertices.data(), batch.vertices.size(), texture});
    }
    const bool presented = m_Presenter->PresentSolidBatches(
        metalBatches.data(), metalBatches.size(), 0.04, 0.055, 0.075, 1.0,
        targetHz);
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
  for (int i = 0; i + 3 < iNumVerts; i += 4) {
    AppendTriangle(
        &batch.vertices, v[i + 0], v[i + 1], v[i + 2],
        modelViewProjection);
    AppendTriangle(
        &batch.vertices, v[i + 2], v[i + 1], v[i + 3],
        modelViewProjection);
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
  for (int i = 0; i + 3 < iNumVerts; i += 2) {
    AppendTriangle(
        &batch.vertices, v[i + 0], v[i + 1], v[i + 2],
        modelViewProjection);
    AppendTriangle(
        &batch.vertices, v[i + 2], v[i + 1], v[i + 3],
        modelViewProjection);
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
  for (int i = 1; i + 1 < iNumVerts; ++i) {
    AppendTriangle(
        &batch.vertices, v[0], v[i], v[i + 1], modelViewProjection);
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
  for (int i = 0; i + 2 < iNumVerts; ++i) {
    if ((i % 2) == 0) {
      AppendTriangle(
          &batch.vertices, v[i], v[i + 1], v[i + 2],
          modelViewProjection);
    } else {
      AppendTriangle(
          &batch.vertices, v[i + 1], v[i], v[i + 2],
          modelViewProjection);
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
  for (int i = 0; i + 2 < iNumVerts; i += 3) {
    AppendTriangle(
        &batch.vertices, v[i + 0], v[i + 1], v[i + 2],
        modelViewProjection);
  }
}

RageCompiledGeometry* RageDisplay_Metal::CreateCompiledGeometry() {
  return new RageCompiledGeometryMetalStub;
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
  ClearAllTextures();
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
          std::max(1, m_Params.height), targetHz)) {
    return m_Presenter->FailureReason().empty()
               ? "Native Metal presenter initialization failed."
               : m_Presenter->FailureReason();
  }
  if (!m_Presenter->AttachLayerToWindow(nativeWindow)) {
    return m_Presenter->FailureReason().empty()
               ? "Native Metal presenter layer attachment failed."
               : m_Presenter->FailureReason();
  }

  m_bReady = true;
  return std::string();
}
