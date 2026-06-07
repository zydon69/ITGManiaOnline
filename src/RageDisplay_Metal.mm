/* RageDisplay_Metal - Native Metal renderer entry point. */

#include "RageDisplay_Metal.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "DisplaySpec.h"
#include "ModelTypes.h"
#include "RageDisplay.h"
#include "RageLog.h"
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

RageDisplay_Metal::RageDisplay_Metal()
    : m_iNextTextureHandle(1), m_bReady(false) {
  LOG->MapLog("renderer", "Current renderer: metal");
}

RageDisplay_Metal::~RageDisplay_Metal() {
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

uintptr_t RageDisplay_Metal::CreateTexture(
    RagePixelFormat /* pixfmt */, RageSurface* /* img */,
    bool /* bGenerateMipMaps */) {
  return m_iNextTextureHandle++;
}

void RageDisplay_Metal::EndFrame() {
  if (m_bReady && m_Presenter) {
    const double targetHz =
        m_Params.rate > 1 ? static_cast<double>(m_Params.rate) : 60.0;
    const bool presented =
        m_Presenter->PresentClearFrame(0.04, 0.055, 0.075, 1.0, targetHz);
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
  m_Presenter->Shutdown();

  std::string err = m_Window->TryVideoMode(p, bNewDeviceOut);
  if (!err.empty()) {
    return err;
  }

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
