#include "RageTextureRenderTarget.h"

#include "RageDisplay.h"
#include "RageLog.h"
#include "RageTexture.h"
#include "RageTextureID.h"

RageTextureRenderTarget::RageTextureRenderTarget(
    RageTextureID name, const RenderTargetParam& param)
    : RageTexture(name),
      m_Param(param),
      m_iTexHandle(0),
      m_iPreviousRenderTarget(0),
      m_bValid(false),
      m_bRendering(false),
      m_bWarnedInvalidUse(false) {
  Create();
}

RageTextureRenderTarget::~RageTextureRenderTarget() { Destroy(); }

void RageTextureRenderTarget::Reload() {
  Destroy();
  Create();
}

/* RageTextureID identifies a file and a mechanism for loading it. We don't use
 * any of that, except as a unique identifier for this texture, so it can be
 * loaded elsewhere. Render targets can't be loaded blindly like a regular
 * texture, anyway, since something has to render into it. */
void RageTextureRenderTarget::Create() {
  m_iTexHandle = 0;
  m_iTextureWidth = 0;
  m_iTextureHeight = 0;
  m_bValid = false;
  m_bRendering = false;
  m_bWarnedInvalidUse = false;

  /* All render targets support non-power-of-two targets,
   * but some require that the resulting texture dimensions be powers of two.
   * CreateRenderTarget returns the actual resolution. */
  if (DISPLAY == nullptr) {
    LOG->Warn(
        "RageTextureRenderTarget: failed to create render target '%s' without "
        "a display backend.",
        GetID().filename.c_str());
    return;
  }
  m_iTexHandle =
      DISPLAY->CreateRenderTarget(m_Param, m_iTextureWidth, m_iTextureHeight);

  m_iSourceWidth = m_Param.iWidth;
  m_iSourceHeight = m_Param.iHeight;
  m_iImageWidth = m_Param.iWidth;
  m_iImageHeight = m_Param.iHeight;
  m_iFramesWide = m_iFramesHigh = 1;

  CreateFrameRects();

  m_bValid =
      m_iTexHandle != 0 && m_iTextureWidth > 0 && m_iTextureHeight > 0;
  if (!m_bValid) {
    LOG->Warn(
        "RageTextureRenderTarget: failed to create render target '%s' "
        "requested=%dx%d depth=%d alpha=%d float=%d. Rendering to this "
        "target will be skipped instead of falling back to the main "
        "framebuffer.",
        GetID().filename.c_str(), m_Param.iWidth, m_Param.iHeight,
        m_Param.bWithDepthBuffer ? 1 : 0, m_Param.bWithAlpha ? 1 : 0,
        m_Param.bFloat ? 1 : 0);
  }
}

void RageTextureRenderTarget::Destroy() {
  if (DISPLAY != nullptr && m_iTexHandle != 0) {
    DISPLAY->DeleteTexture(m_iTexHandle);
  }
  m_iTexHandle = 0;
  m_bValid = false;
  m_bRendering = false;
}

void RageTextureRenderTarget::BeginRenderingTo(bool bPreserveTexture) {
  if (DISPLAY == nullptr || !m_bValid) {
    if (!m_bWarnedInvalidUse) {
      LOG->Warn(
          "RageTextureRenderTarget: ignoring BeginRenderingTo() for invalid "
          "render target '%s'.",
          GetID().filename.c_str());
      m_bWarnedInvalidUse = true;
    }
    return;
  }

  m_iPreviousRenderTarget = DISPLAY->GetRenderTarget();
  DISPLAY->SetRenderTarget(m_iTexHandle, bPreserveTexture);
  m_bRendering = true;

  /* We're rendering to a texture, not the framebuffer.
   * Stash away the centering matrix, and set it to identity. */
  DISPLAY->CenteringPushMatrix();
  DISPLAY->ChangeCentering(0, 0, 0, 0);

  // Reset the perspective to fit the new target.
  DISPLAY->CameraPushMatrix();
  DISPLAY->LoadMenuPerspective(
      0, (float)m_iImageWidth, (float)m_iImageHeight, (float)m_iImageWidth / 2,
      (float)m_iImageHeight / 2);  // 0 FOV = ortho

  DISPLAY->PushMatrix();
  DISPLAY->LoadIdentity();
}

void RageTextureRenderTarget::FinishRenderingTo() {
  if (DISPLAY == nullptr || !m_bRendering) {
    return;
  }

  // Restore the matrixes.
  DISPLAY->CenteringPopMatrix();
  DISPLAY->CameraPopMatrix();
  DISPLAY->PopMatrix();

  DISPLAY->SetRenderTarget(m_iPreviousRenderTarget);
  m_bRendering = false;
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the RageTextureRenderTarget. */
class LunaRageTextureRenderTarget : public Luna<RageTextureRenderTarget> {
 public:
  static int BeginRenderingTo(T* p, lua_State* L) {
    bool bPreserveTexture = !!luaL_opt(L, lua_toboolean, 1, false);
    p->BeginRenderingTo(bPreserveTexture);
    COMMON_RETURN_SELF;
  }
  static int FinishRenderingTo(T* p, lua_State* L) {
    p->FinishRenderingTo();
    COMMON_RETURN_SELF;
  }

  LunaRageTextureRenderTarget() {
    ADD_METHOD(BeginRenderingTo);
    ADD_METHOD(FinishRenderingTo);
  }
};

LUA_REGISTER_DERIVED_CLASS(RageTextureRenderTarget, RageTexture)
// lua end

/*
 * Copyright (c) 2001-2006 Glenn Maynard, Chris Danford
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
