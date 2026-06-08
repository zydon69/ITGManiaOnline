/* RageDisplay_Metal - Native Metal renderer entry point. */

#ifndef RAGE_DISPLAY_METAL_H
#define RAGE_DISPLAY_METAL_H

#include <memory>
#include <string>
#include <array>
#include <vector>

#include "RageDisplay.h"
#include "RageTypes.h"
#include "arch/LowLevelWindow/MacOSMetalPresenter.h"

class LowLevelWindow;
struct RageMatrix;

/*
 * Experimental native Metal renderer.  OpenGL remains the production default;
 * this backend is advanced in small, testable milestones.
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

  bool BeginFrame() override;
  void EndFrame() override;
  ActualVideoModeParams GetActualVideoModeParams() const override {
    return m_Params;
  }
  void SetBlendMode(BlendMode mode) override;
  bool SupportsTextureFormat(
      RagePixelFormat pixfmt, bool realtime = false) override;
  bool SupportsPerVertexMatrixScale() override { return true; }

  uintptr_t CreateTexture(
      RagePixelFormat, RageSurface* /* img */,
      bool /* bGenerateMipMaps */) override;
  void UpdateTexture(
      uintptr_t iTexHandle, RageSurface* img, int xoffset,
      int yoffset, int width, int height) override;
  RageTextureLock* CreateTextureLock() override;
  void DeleteTexture(uintptr_t iTexHandle) override;
  void ClearAllTextures() override;
  int GetNumTextureUnits() override { return 2; }
  void SetTexture(TextureUnit, uintptr_t iTexture) override;
  void SetTextureMode(TextureUnit tu, TextureMode mode) override;
  void SetTextureWrapping(TextureUnit tu, bool wrapping) override;
  int GetMaxTextureSize() const override { return 16384; }
  void SetTextureFiltering(TextureUnit tu, bool filtering) override;
  void SetEffectMode(EffectMode effect) override;
  bool IsEffectModeSupported(EffectMode effect) override;
  bool SupportsRenderToTexture() const override { return true; }
  uintptr_t CreateRenderTarget(
      const RenderTargetParam& param, int& iTextureWidthOut,
      int& iTextureHeightOut) override;
  uintptr_t GetRenderTarget() override;
  void SetRenderTarget(
      uintptr_t iHandle, bool bPreserveTexture = true) override;

  bool IsZWriteEnabled() const override { return m_bZWrite; }
  bool IsZTestEnabled() const override { return m_ZTestMode != ZTEST_OFF; }
  void SetZWrite(bool write) override;
  void SetZBias(float bias) override;
  void SetZTestMode(ZTestMode mode) override;
  void ClearZBuffer() override;
  void SetCullMode(CullMode mode) override;
  void SetAlphaTest(bool enabled) override;
  void SetMaterial(
      const RageColor& emissive, const RageColor& ambient,
      const RageColor& diffuse, const RageColor& specular,
      float shininess) override;
  void SetLighting(bool enabled) override;
  void SetLightOff(int index) override;
  void SetLightDirectional(
      int index, const RageColor& ambient, const RageColor& diffuse,
      const RageColor& specular, const RageVector3& dir) override;
  void SetSphereEnvironmentMapping(TextureUnit tu, bool b) override;
  void SetCelShaded(int stage) override;

  RageCompiledGeometry* CreateCompiledGeometry() override;
  void DeleteCompiledGeometry(RageCompiledGeometry*) override;
  RageSurface* CreateScreenshot() override;

 protected:
  void DrawQuadsInternal(
      const RageSpriteVertex v[], int iNumVerts) override;
  void DrawQuadStripInternal(
      const RageSpriteVertex v[], int iNumVerts) override;
  void DrawFanInternal(const RageSpriteVertex v[], int iNumVerts) override;
  void DrawStripInternal(const RageSpriteVertex v[], int iNumVerts) override;
  void DrawTrianglesInternal(
      const RageSpriteVertex v[], int iNumVerts) override;
  void DrawCompiledGeometryInternal(
      const RageCompiledGeometry* p, int iMeshIndex) override;
  void DrawLineStripInternal(
      const RageSpriteVertex v[], int iNumVerts, float LineWidth) override;
  void DrawSymmetricQuadStripInternal(
      const RageSpriteVertex v[], int iNumVerts) override;

  std::string TryVideoMode(
      const VideoModeParams& p, bool& bNewDeviceOut) override;

 private:
  friend class RageCompiledGeometryMetal;

  struct MetalTexture {
    void* texture = nullptr;
    void* depthTexture = nullptr;
    int width = 0;
    int height = 0;
    int renderWidth = 0;
    int renderHeight = 0;
    bool renderTarget = false;
    bool requestedDepth = false;
    bool requestedAlpha = false;
    bool requestedFloat = false;
    bool hasRendered = false;
    bool preserveNextRender = false;
  };

  struct DrawBatch {
    std::array<uintptr_t, NUM_TextureUnit> textureHandles = {};
    BlendMode blendMode = BLEND_NORMAL;
    std::array<TextureMode, NUM_TextureUnit> textureModes = {};
    EffectMode effectMode = EffectMode_Normal;
    int celStage = 0;
    bool sphereMapping = false;
    float zBias = 0.0f;
    ZTestMode zTestMode = ZTEST_OFF;
    CullMode cullMode = CULL_NONE;
    std::array<bool, NUM_TextureUnit> textureWrapping = {};
    std::array<bool, NUM_TextureUnit> textureFiltering = {};
    bool zWrite = false;
    bool alphaTest = false;
    std::vector<MacOSMetalSolidVertex> vertices;
  };

  RageMatrix CurrentModelViewProjection() const;
  RageMatrix CurrentTextureMatrix() const;
  RageColor ComputeModelColor(const RageVector3& normal) const;
  DrawBatch& ActiveBatch();
  void ClearActiveBatches();
  void FlushBatches();
  void BuildMetalBatches(
      const std::vector<DrawBatch>& batches, size_t batchCount,
      std::vector<MacOSMetalDrawBatch>* metalBatches) const;
  void ReleaseTexture(MetalTexture* texture);
  void DestroyAllTextures();
  bool UploadTexturePixels(
      MetalTexture* texture, RageSurface* img, int xoffset, int yoffset,
      int width, int height);
  void DrawCompiledTriangles(
      const std::vector<RageSpriteVertex>& vertices);

  ActualVideoModeParams m_Params;
  std::unique_ptr<LowLevelWindow> m_Window;
  std::unique_ptr<MacOSMetalPresenter> m_Presenter;
  std::vector<DrawBatch> m_DrawBatches;
  size_t m_iActiveDrawBatchCount = 0;
  std::vector<MacOSMetalDrawBatch> m_MetalDrawBatches;
  std::vector<MetalTexture> m_Textures;
  std::array<uintptr_t, NUM_TextureUnit> m_TextureHandles;
  BlendMode m_BlendMode;
  std::array<TextureMode, NUM_TextureUnit> m_TextureModes;
  EffectMode m_EffectMode;
  int m_iCelShadedStage;
  bool m_bSphereMapping;
  float m_fZBias;
  ZTestMode m_ZTestMode;
  CullMode m_CullMode;
  std::array<bool, NUM_TextureUnit> m_TextureWrapping;
  std::array<bool, NUM_TextureUnit> m_TextureFiltering;
  bool m_bZWrite;
  bool m_bAlphaTest;
  bool m_bClearDepthNextFrame;
  uintptr_t m_iCurrentRenderTargetHandle;
  RageColor m_MaterialDiffuse;
  RageColor m_MaterialAmbient;
  RageColor m_MaterialEmissive;
  bool m_bLighting;
  struct DirectionalLight {
    bool enabled = false;
    RageColor ambient = RageColor(0.0f, 0.0f, 0.0f, 1.0f);
    RageColor diffuse = RageColor(1.0f, 1.0f, 1.0f, 1.0f);
    RageVector3 direction = RageVector3(0.0f, 0.0f, 1.0f);
  };
  std::vector<DirectionalLight> m_Lights;
  uintptr_t m_iNextTextureHandle;
  bool m_bReady;
};

#endif
