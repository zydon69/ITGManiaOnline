/* RageDisplay_Metal - Native Metal renderer entry point. */

#include "RageDisplay_Metal.h"

#include <string>
#include <vector>

#include "DisplaySpec.h"
#include "ModelTypes.h"
#include "RageDisplay.h"
#include "RageLog.h"
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

RageDisplay_Metal::RageDisplay_Metal() {
  LOG->MapLog("renderer", "Current renderer: metal");
}

std::string RageDisplay_Metal::Init(
    const VideoModeParams& /* p */,
    bool /* bAllowUnacceleratedRenderer */) {
  const std::string reason =
      "Native Metal renderer is registered but not implemented yet. "
      "Falling back to the next configured video renderer.";

  LOG->Warn("RageDisplay_Metal: %s", reason.c_str());
  return reason;
}

void RageDisplay_Metal::GetDisplaySpecs(DisplaySpecs& out) const {
  out.clear();
}

const RageDisplay::RagePixelFormatDesc* RageDisplay_Metal::GetPixelFormatDesc(
    RagePixelFormat pf) const {
  ASSERT(pf >= 0 && pf < NUM_RagePixelFormat);
  return &PIXEL_FORMAT_DESC[pf];
}

void RageDisplay_Metal::EndFrame() { ProcessStatsOnFlip(); }

RageCompiledGeometry* RageDisplay_Metal::CreateCompiledGeometry() {
  return new RageCompiledGeometryMetalStub;
}

void RageDisplay_Metal::DeleteCompiledGeometry(RageCompiledGeometry* p) {
  delete p;
}

std::string RageDisplay_Metal::TryVideoMode(
    const VideoModeParams& p, bool& bNewDeviceOut) {
  m_Params = ActualVideoModeParams(p);
  bNewDeviceOut = false;
  return "Native Metal renderer video mode setup is not implemented yet.";
}
