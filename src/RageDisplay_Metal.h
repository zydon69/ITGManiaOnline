/* RageDisplay_Metal - Native Metal renderer entry point. */

#ifndef RAGE_DISPLAY_METAL_H
#define RAGE_DISPLAY_METAL_H

#include <memory>
#include <string>

#include "RageDisplay.h"
#include "RageTypes.h"

class LowLevelWindow;
class MacOSMetalPresenter;

/*
 * This class is intentionally only a renderer-registration skeleton for now.
 * It lets VideoRenderers=metal,opengl exercise the factory path and fall back
 * to OpenGL cleanly until the native Metal state machine is implemented.
 */
class RageDisplay_Metal : public RageDisplay {
 public:
  RageDisplay_Metal();
  ~RageDisplay_Metal() override;

  std::string Init(
      const VideoModeParams& p, bool bAllowUnacceleratedRenderer) override;

  std::string GetApiDescription() const override { return "Metal"; }
  void GetDisplaySpecs(DisplaySpecs& out) const override;
  const RagePixelFormatDesc* GetPixelFormatDesc(RagePixelFormat pf)
      const override;

  bool BeginFrame() override { return m_bReady; }
  void EndFrame() override;
  ActualVideoModeParams GetActualVideoModeParams() const override {
    return m_Params;
  }
  void SetBlendMode(BlendMode) override {}
  bool SupportsTextureFormat(
      RagePixelFormat, bool /* realtime */ = false) override {
    return true;
  }
  bool SupportsPerVertexMatrixScale() override { return false; }

  uintptr_t CreateTexture(
      RagePixelFormat, RageSurface* /* img */,
      bool /* bGenerateMipMaps */) override;
  void UpdateTexture(
      uintptr_t /* iTexHandle */, RageSurface* /* img */, int /* xoffset */,
      int /* yoffset */, int /* width */, int /* height */) override {}
  void DeleteTexture(uintptr_t /* iTexHandle */) override {}
  void ClearAllTextures() override {}
  int GetNumTextureUnits() override { return 1; }
  void SetTexture(TextureUnit, uintptr_t /* iTexture */) override {}
  void SetTextureMode(TextureUnit, TextureMode) override {}
  void SetTextureWrapping(TextureUnit, bool) override {}
  int GetMaxTextureSize() const override { return 16384; }
  void SetTextureFiltering(TextureUnit, bool) override {}

  bool IsZWriteEnabled() const override { return false; }
  bool IsZTestEnabled() const override { return false; }
  void SetZWrite(bool) override {}
  void SetZBias(float) override {}
  void SetZTestMode(ZTestMode) override {}
  void ClearZBuffer() override {}
  void SetCullMode(CullMode) override {}
  void SetAlphaTest(bool) override {}
  void SetMaterial(
      const RageColor& emissive, const RageColor& ambient,
      const RageColor& diffuse, const RageColor& specular,
      float shininess) override {}
  void SetLighting(bool) override {}
  void SetLightOff(int index) override {}
  void SetLightDirectional(
      int index, const RageColor& ambient, const RageColor& diffuse,
      const RageColor& specular, const RageVector3& dir) override {}
  void SetSphereEnvironmentMapping(TextureUnit tu, bool b) override {}
  void SetCelShaded(int stage) override {}

  RageCompiledGeometry* CreateCompiledGeometry() override;
  void DeleteCompiledGeometry(RageCompiledGeometry*) override;
  RageSurface* CreateScreenshot() override { return nullptr; }

 protected:
  void DrawQuadsInternal(
      const RageSpriteVertex v[], int iNumVerts) override {}
  void DrawQuadStripInternal(
      const RageSpriteVertex v[], int iNumVerts) override {}
  void DrawFanInternal(const RageSpriteVertex v[], int iNumVerts) override {}
  void DrawStripInternal(const RageSpriteVertex v[], int iNumVerts) override {}
  void DrawTrianglesInternal(
      const RageSpriteVertex v[], int iNumVerts) override {}
  void DrawCompiledGeometryInternal(
      const RageCompiledGeometry* p, int iMeshIndex) override {}
  void DrawLineStripInternal(
      const RageSpriteVertex v[], int iNumVerts, float LineWidth) override {}
  void DrawSymmetricQuadStripInternal(
      const RageSpriteVertex v[], int iNumVerts) override {}

  std::string TryVideoMode(
      const VideoModeParams& p, bool& bNewDeviceOut) override;

 private:
  ActualVideoModeParams m_Params;
  std::unique_ptr<LowLevelWindow> m_Window;
  std::unique_ptr<MacOSMetalPresenter> m_Presenter;
  uintptr_t m_iNextTextureHandle;
  bool m_bReady;
};

#endif
