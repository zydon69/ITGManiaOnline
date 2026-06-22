/* RageTexture - Abstract class for a texture and metadata.  */

#ifndef RAGE_TEXTURE_H
#define RAGE_TEXTURE_H

#include <cstdint>
#include <limits>
#include <string>
#include <vector>

#include "RageTextureID.h"
#include "RageTypes.h"

struct lua_State;
class RageTexture {
 public:
  RageTexture(RageTextureID file);
  virtual ~RageTexture() = 0;
  virtual void Update(float /* fDeltaTime */) {}
  virtual void Reload() {}
  virtual void Invalidate() {
  } /* only called by RageTextureManager::InvalidateTextures */
  virtual uintptr_t GetTexHandle() const = 0;  // accessed by RageDisplay

  // movie texture/animated texture stuff
  virtual void SetPosition(float /* fSeconds */) {}  // seek
  virtual void UpdateMovie(float /* fSeconds */) {}  // decode and update
  virtual void SetPlaybackRate(float) {}
  virtual bool IsAMovie() const { return false; }
  virtual void SetLooping(bool) {}

  int GetSourceWidth() const { return m_iSourceWidth; }
  int GetSourceHeight() const { return m_iSourceHeight; }
  int GetTextureWidth() const { return m_iTextureWidth; }
  int GetTextureHeight() const { return m_iTextureHeight; }
  int GetImageWidth() const { return m_iImageWidth; }
  int GetImageHeight() const { return m_iImageHeight; }

  int GetFramesWide() const { return m_iFramesWide; }
  int GetFramesHigh() const { return m_iFramesHigh; }

  int GetSourceFrameWidth() const {
    return GetFramesWide() > 0 ? GetSourceWidth() / GetFramesWide() : 0;
  }
  int GetSourceFrameHeight() const {
    return GetFramesHigh() > 0 ? GetSourceHeight() / GetFramesHigh() : 0;
  }
  int GetTextureFrameWidth() const {
    return GetFramesWide() > 0 ? GetTextureWidth() / GetFramesWide() : 0;
  }
  int GetTextureFrameHeight() const {
    return GetFramesHigh() > 0 ? GetTextureHeight() / GetFramesHigh() : 0;
  }
  int GetImageFrameWidth() const {
    return GetFramesWide() > 0 ? GetImageWidth() / GetFramesWide() : 0;
  }
  int GetImageFrameHeight() const {
    return GetFramesHigh() > 0 ? GetImageHeight() / GetFramesHigh() : 0;
  }

  // Use these to convert between the different coordinate systems:
  float GetSourceToImageCoordsRatioX() const {
    return GetSourceWidth() > 0 ? float(GetImageWidth()) / GetSourceWidth()
                                : 0.0f;
  }
  float GetImageToTexCoordsRatioX() const {
    return GetTextureWidth() > 0 ? 1.0f / GetTextureWidth() : 0.0f;
  }
  float GetSourceToTexCoordsRatioX() const {
    return GetSourceToImageCoordsRatioX() * GetImageToTexCoordsRatioX();
  }
  float GetSourceToImageCoordsRatioY() const {
    return GetSourceHeight() > 0 ? float(GetImageHeight()) / GetSourceHeight()
                                 : 0.0f;
  }
  float GetImageToTexCoordsRatioY() const {
    return GetTextureHeight() > 0 ? 1.0f / GetTextureHeight() : 0.0f;
  }
  float GetSourceToTexCoordsRatioY() const {
    return GetSourceToImageCoordsRatioY() * GetImageToTexCoordsRatioY();
  }

  const RectF* GetTextureCoordRect(int frameNo) const;
  int GetNumFrames() const {
    const int64_t frames =
        static_cast<int64_t>(m_iFramesWide) * m_iFramesHigh;
    if (frames <= 0) {
      return 0;
    }
    if (frames > std::numeric_limits<int>::max()) {
      return std::numeric_limits<int>::max();
    }
    return static_cast<int>(frames);
  }

  // Used by RageTextureManager. Order is important; see RageTextureManager.cpp.
  const RageTextureID::TexPolicy& GetPolicy() const { return m_ID.Policy; }
  RageTextureID::TexPolicy& GetPolicy() { return m_ID.Policy; }
  int m_iRefCount;
  bool m_bWasUsed;

  // The ID that we were asked to load:
  const RageTextureID& GetID() const { return m_ID; }

  static void GetFrameDimensionsFromFileName(
      std::string sPath, int* puFramesWide, int* puFramesHigh,
      int source_width = 0, int source_height = 0);

  // Lua
  virtual void PushSelf(lua_State* L);

 private:
  /* We might change settings when loading (due to hints, hardware
   * limitations, etc). The data actually loaded is here: */
  RageTextureID m_ID;

 protected:
  int m_iSourceWidth,
      m_iSourceHeight;  // dimensions of the original image loaded from disk
  int m_iTextureWidth, m_iTextureHeight;  // dimensions of the texture in memory
  int m_iImageWidth, m_iImageHeight;  // dimensions of the image in the texture
  int m_iFramesWide, m_iFramesHigh;   // The number of frames of animation in
                                      // each row and column of this texture
  std::vector<RectF>
      m_TextureCoordRects;  // size = m_iFramesWide * m_iFramesHigh

  virtual void CreateFrameRects();
};

#endif

/*
 * Copyright (c) 2001-2004 Chris Danford
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
