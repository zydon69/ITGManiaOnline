/* RageDisplay_Legacy: OpenGL renderer. */

#ifndef RAGE_DISPLAY_OGL_H
#define RAGE_DISPLAY_OGL_H

#ifdef __APPLE__
#define GL_SILENCE_DEPRECATION 1
#endif

#include <cstdint>
#include <string>

#include "RageDisplay.h"
#include "RageTextureRenderTarget.h"
#include "RageTypes.h"
#include "global.h"

/* Making an OpenGL call doesn't also flush the error state; if we happen
 * to have an error from a previous call, then the assert below will fail.
 * Flush it. */
#define FlushGLErrors() \
  do {                  \
  } while (glGetError() != GL_NO_ERROR)
#define AssertNoGLError()                                                     \
  {                                                                           \
    GLenum error = glGetError();                                              \
    ASSERT_M(                                                                 \
        error == GL_NO_ERROR, RageDisplay_Legacy_Helpers::GLToString(error)); \
  }

#if defined(DEBUG) || !defined(GL_GET_ERROR_IS_SLOW)
#define DebugFlushGLErrors() FlushGLErrors()
#define DebugAssertNoGLError() AssertNoGLError()
#else
#define DebugFlushGLErrors()
#define DebugAssertNoGLError()
#endif

class RageDisplay_Legacy : public RageDisplay {
 public:
  RageDisplay_Legacy();
  ~RageDisplay_Legacy() override;
  std::string Init(
      const VideoModeParams& p, bool bAllowUnacceleratedRenderer) override;

  std::string GetApiDescription() const override;
  std::string GetPresentationStats() const override;
  void GetDisplaySpecs(DisplaySpecs& out) const override;
  void ResolutionChanged() override;
  void ResetFramePresentationTelemetry() override;
  void PrepareForTextureManagerShutdown() override;
  const RagePixelFormatDesc* GetPixelFormatDesc(
      RagePixelFormat pf) const override;

  bool SupportsThreadedRendering() override;
  void BeginConcurrentRenderingMainThread() override;
  void EndConcurrentRenderingMainThread() override;
  void BeginConcurrentRendering() override;
  void EndConcurrentRendering() override;

  bool BeginFrame() override;
  void EndFrame() override;
  ActualVideoModeParams GetActualVideoModeParams() const override;
  void SetBlendMode(BlendMode mode) override;
  bool SupportsTextureFormat(
      RagePixelFormat pixfmt, bool realtime = false) override;
  bool SupportsPerVertexMatrixScale() override;
  uintptr_t CreateTexture(
      RagePixelFormat pixfmt, RageSurface* img,
      bool bGenerateMipMaps) override;
  void UpdateTexture(
      uintptr_t iTexHandle, RageSurface* img, int xoffset, int yoffset,
      int width, int height) override;
  void DeleteTexture(uintptr_t iTexHandle) override;
  bool UseOffscreenRenderTarget();
  RageSurface* GetTexture(uintptr_t iTexture) override;
  RageTextureLock* CreateTextureLock() override;

  void ClearAllTextures() override;
  int GetNumTextureUnits() override;
  void SetTexture(TextureUnit tu, uintptr_t iTexture) override;
  void SetTextureMode(TextureUnit tu, TextureMode tm) override;
  void SetTextureWrapping(TextureUnit tu, bool b) override;
  int GetMaxTextureSize() const override;
  void SetTextureFiltering(TextureUnit tu, bool b) override;
  void SetEffectMode(EffectMode effect) override;
  bool IsEffectModeSupported(EffectMode effect) override;
  bool SupportsRenderToTexture() const override;
  bool SupportsFullscreenBorderlessWindow() const override;
  uintptr_t CreateRenderTarget(
      const RenderTargetParam& param, int& iTextureWidthOut,
      int& iTextureHeightOut) override;
  uintptr_t GetRenderTarget() override;
  void SetRenderTarget(
      uintptr_t iHandle, bool bPreserveTexture) override;
  bool IsZWriteEnabled() const override;
  bool IsZTestEnabled() const override;
  void SetZWrite(bool b) override;
  void SetZBias(float f) override;
  void SetZTestMode(ZTestMode mode) override;
  void ClearZBuffer() override;
  void SetCullMode(CullMode mode) override;
  void SetAlphaTest(bool b) override;
  void SetMaterial(
      const RageColor& emissive, const RageColor& ambient,
      const RageColor& diffuse, const RageColor& specular,
      float shininess) override;
  void SetLighting(bool b) override;
  void SetLightOff(int index) override;
  void SetLightDirectional(
      int index, const RageColor& ambient, const RageColor& diffuse,
      const RageColor& specular, const RageVector3& dir) override;

  void SetSphereEnvironmentMapping(TextureUnit tu, bool b) override;
  void SetCelShaded(int stage) override;

  RageCompiledGeometry* CreateCompiledGeometry() override;
  void DeleteCompiledGeometry(RageCompiledGeometry* p) override;

  // hacks for cell-shaded models
  void SetPolygonMode(PolygonMode pm) override;
  void SetLineWidth(float fWidth) override;

  std::string GetTextureDiagnostics(uintptr_t id) const override;

 protected:
  void DrawQuadsInternal(
      const RageSpriteVertex v[], int iNumVerts) override;
  void DrawQuadStripInternal(
      const RageSpriteVertex v[], int iNumVerts) override;
  void DrawFanInternal(
      const RageSpriteVertex v[], int iNumVerts) override;
  void DrawStripInternal(
      const RageSpriteVertex v[], int iNumVerts) override;
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
  RageSurface* CreateScreenshot() override;
  RagePixelFormat GetImgPixelFormat(
      RageSurface*& img, bool& FreeImg, int width, int height,
      bool bPalettedTexture);
  bool SupportsSurfaceFormat(RagePixelFormat pixfmt);

  void SendCurrentMatrices();

 private:
  void ReleaseOffscreenRenderTarget();
  RageTextureRenderTarget* offscreenRenderTarget;
};

#endif

/*
 * Copyright (c) 2001-2011 Chris Danford, Glenn Maynard, Colby Klein
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, and/or sell copies of the Software, and to permit persons to
 * whom the Software is furnished to do so, provided that the above
 * copyright notice(s) and this permission notice appear in all copies of
 * the Software and that both the above copyright notice(s) and this
 * permission notice appear in supporting documentation.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
 * THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
 * INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT
 * OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 */
