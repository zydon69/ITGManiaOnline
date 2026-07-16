#include "MovieTexture_Generic.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>
#include <thread>
#include <utility>

#include "Actor.h"
#include "Preference.h"
#include "RageDisplay.h"
#include "RageLog.h"
#include "RageSurface.h"
#include "RageTextureID.h"
#include "RageTextureManager.h"
#include "RageTextureRenderTarget.h"
#include "RageThreads.h"
#include "RageTimer.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Sprite.h"
#include "arch/MovieTexture/MovieTexture.h"
#include "global.h"

#if defined(WIN32)
#include <windows.h>

#include "archutils/Win32/ErrorStrings.h"
#endif

static Preference<bool> g_bMovieTextureDirectUpdates(
    "MovieTextureDirectUpdates", true);

namespace {
constexpr int kMaxMovieDimension = 8192;

bool IsValidMovieDimension(int value) {
  return value > 0 && value <= kMaxMovieDimension;
}

bool IsValidMovieSurface(const RageSurface* surface) {
  return surface != nullptr && surface->format != nullptr &&
         surface->w > 0 && surface->h > 0 && surface->pitch > 0;
}
}  // namespace

MovieTexture_Generic::MovieTexture_Generic(
    RageTextureID ID, std::unique_ptr<MovieDecoder> pDecoder)
    : RageMovieTexture(ID) {
  if (LOG != nullptr) {
    LOG->Trace(
        "MovieTexture_Generic::MovieTexture_Generic(%s)", ID.filename.c_str());
  }

  decoder_ = std::move(pDecoder);

  texture_handle_ = 0;
  render_target_ = nullptr;
  intermediate_texture_ = nullptr;
  loop_ = true;
  surface_ = nullptr;
  texture_lock_ = nullptr;
  rate_ = 1;
  clock_ = 0;
  sprite_ = std::make_unique<Sprite>();
}

std::string MovieTexture_Generic::Init() {
  if (decoder_ == nullptr) {
    SetDecodeFailed();
    return "MovieTexture_Generic: missing decoder";
  }
  std::string err = decoder_->Open(GetID().filename);
  if (err != "") {
    if (LOG != nullptr) {
      LOG->Warn(
          "MovieTexture_Generic::Init: failed to open decoder for file: %s, "
          "with error:\n%s",
          GetID().filename.c_str(), err.c_str());
    }
    return err;
  }

  if (!CreateTexture()) {
    SetDecodeFailed();
    return "MovieTexture_Generic: failed to create texture";
  }
  CreateFrameRects();
  decoder_->SetLooping(loop_);

  decoding_thread_ = std::make_unique<std::thread>([this]() {
    if (LOG != nullptr) {
      LOG->Trace(
          "Beginning to decode video file \"%s\"", GetID().filename.c_str());
    }
    auto timer = RageTimer();

    int ret = decoder_->DecodeMovie();
    if (ret == -1) {
      SetDecodeFailed();
    } else if (ret == -2) {
      SetDecodeFailed(false);
    } else if (ret != 0) {
      if (LOG != nullptr) {
        LOG->Warn("MovieDecoder::DecodeMovie returned unexpected value %d", ret);
      }
      SetDecodeFailed();
    }

    if (LOG != nullptr) {
      LOG->Trace(
          "Done decoding video file \"%s\", took %f seconds",
          GetID().filename.c_str(), timer.Ago());
    }
  });

  if (LOG != nullptr) {
    LOG->Trace(
        "Resolution: %ix%i (%ix%i, %ix%i)", m_iSourceWidth, m_iSourceHeight,
        m_iImageWidth, m_iImageHeight, m_iTextureWidth, m_iTextureHeight);
  }

  CHECKPOINT_M("Generic initialization completed. No errors found.");

  return std::string();
}

MovieTexture_Generic::~MovieTexture_Generic() {
  if (decoder_) {
    decoder_->Cancel();
    if (decoding_thread_ && decoding_thread_->joinable()) {
      decoding_thread_->join();
    }
    decoder_->Close();
  }

  /* sprite_ may reference the texture; delete it before DestroyTexture. */
  sprite_.reset();
  DestroyTexture();
}

/* Delete the surface and texture.  The decoding thread must be stopped, and
 * this is normally done after destroying the decoder. */
void MovieTexture_Generic::DestroyTexture() {
  delete surface_;
  surface_ = nullptr;

  delete texture_lock_;
  texture_lock_ = nullptr;

  if (DISPLAY != nullptr && texture_handle_) {
    DISPLAY->DeleteTexture(texture_handle_);
  }
  texture_handle_ = 0;

  render_target_.reset();
  intermediate_texture_ = nullptr;
}

class RageMovieTexture_Generic_Intermediate : public RageTexture {
 public:
  RageMovieTexture_Generic_Intermediate(
      RageTextureID ID, int iWidth, int iHeight, int iImageWidth,
      int iImageHeight, int iTextureWidth, int iTextureHeight,
      RageSurfaceFormat SurfaceFormat, RagePixelFormat pixfmt)
      : RageTexture(ID), m_SurfaceFormat(SurfaceFormat) {
    m_PixFmt = pixfmt;
    m_iSourceWidth = iWidth;
    m_iSourceHeight = iHeight;

    m_iImageWidth = iImageWidth;
    m_iImageHeight = iImageHeight;
    m_iTextureWidth = iTextureWidth;
    m_iTextureHeight = iTextureHeight;

    CreateFrameRects();

    texture_handle_ = 0;
    CreateTexture();
  }
  virtual ~RageMovieTexture_Generic_Intermediate() {
    if (DISPLAY != nullptr && texture_handle_) {
      DISPLAY->DeleteTexture(texture_handle_);
      texture_handle_ = 0;
    }
  }

  virtual void Invalidate() { texture_handle_ = 0; }
  virtual void Reload() {}
  virtual uintptr_t GetTexHandle() const { return texture_handle_; }

  bool IsAMovie() const { return true; }

 private:
  void CreateTexture() {
    if (DISPLAY == nullptr || texture_handle_) {
      return;
    }

    RageSurface* pSurface = CreateSurfaceFrom(
        m_iImageWidth, m_iImageHeight, m_SurfaceFormat.BitsPerPixel,
        m_SurfaceFormat.Mask[0], m_SurfaceFormat.Mask[1],
        m_SurfaceFormat.Mask[2], m_SurfaceFormat.Mask[3], nullptr, 1);

    if (pSurface != nullptr) {
      texture_handle_ = DISPLAY->CreateTexture(m_PixFmt, pSurface, false);
    }
    delete pSurface;
  }

  uintptr_t texture_handle_;
  RageSurfaceFormat m_SurfaceFormat;
  RagePixelFormat m_PixFmt;
};

void MovieTexture_Generic::Invalidate() {
  texture_handle_ = 0;
  if (render_target_ != nullptr) {
    render_target_->Invalidate();
  }
  if (intermediate_texture_ != nullptr) {
    intermediate_texture_->Invalidate();
  }
}

bool MovieTexture_Generic::CreateTexture() {
  if (texture_handle_ ||
      (render_target_ != nullptr && render_target_->IsValid())) {
    return true;
  }
  if (render_target_ != nullptr) {
    sprite_->UnloadTexture();
    intermediate_texture_.reset();
    render_target_.reset();
  }
  if (DISPLAY == nullptr || TEXTUREMAN == nullptr || decoder_ == nullptr) {
    return false;
  }

  CHECKPOINT;

  m_iSourceWidth = decoder_->GetWidth();
  m_iSourceHeight = decoder_->GetHeight();
  if (!IsValidMovieDimension(m_iSourceWidth) ||
      !IsValidMovieDimension(m_iSourceHeight)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "MovieTexture_Generic: invalid source dimensions %ix%i for \"%s\"",
          m_iSourceWidth, m_iSourceHeight, GetID().filename.c_str());
    }
    return false;
  }

  /* Adjust m_iSourceWidth to support different source aspect ratios. */
  float fSourceAspectRatio = decoder_->GetSourceAspectRatio();
  if (!std::isfinite(fSourceAspectRatio) || fSourceAspectRatio <= 0.0f) {
    fSourceAspectRatio = 1.0f;
  }
  if (fSourceAspectRatio < 1.0f) {
    const double scaled = m_iSourceHeight / fSourceAspectRatio;
    if (scaled > kMaxMovieDimension) {
      return false;
    }
    m_iSourceHeight = std::lrint(scaled);
  } else if (fSourceAspectRatio > 1.0f) {
    const double scaled = m_iSourceWidth * fSourceAspectRatio;
    if (scaled > kMaxMovieDimension) {
      return false;
    }
    m_iSourceWidth = std::lrint(scaled);
  }
  if (!IsValidMovieDimension(m_iSourceWidth) ||
      !IsValidMovieDimension(m_iSourceHeight)) {
    return false;
  }

  /* HACK: Don't cap movie textures to the max texture size, since we
   * render them onto the texture at the source dimensions.  If we find a
   * fast way to resize movies, we can change this back. */
  m_iImageWidth = m_iSourceWidth;
  m_iImageHeight = m_iSourceHeight;

  /* Texture dimensions need to be a power of two; jump to the next. */
  m_iTextureWidth = power_of_two(m_iImageWidth);
  m_iTextureHeight = power_of_two(m_iImageHeight);
  if (!IsValidMovieDimension(m_iTextureWidth) ||
      !IsValidMovieDimension(m_iTextureHeight)) {
    return false;
  }
  MovieDecoderPixelFormatYCbCr fmt = PixelFormatYCbCr_Invalid;
  if (surface_ == nullptr) {
    ASSERT(texture_lock_ == nullptr);
    if (g_bMovieTextureDirectUpdates) {
      texture_lock_ = DISPLAY->CreateTextureLock();
    }

    surface_ = decoder_->CreateCompatibleSurface(
        m_iImageWidth, m_iImageHeight,
        TEXTUREMAN->GetPrefs().m_iMovieColorDepth == 32, fmt);
    if (!IsValidMovieSurface(surface_)) {
      delete surface_;
      surface_ = nullptr;
      delete texture_lock_;
      texture_lock_ = nullptr;
      return false;
    }
    if (texture_lock_ != nullptr) {
      delete[] surface_->pixels;
      surface_->pixels = nullptr;
    }
  }

  RagePixelFormat pixfmt = DISPLAY->FindPixelFormat(
      surface_->format->BitsPerPixel, surface_->format->Mask[0],
      surface_->format->Mask[1], surface_->format->Mask[2],
      surface_->format->Mask[3]);

  if (pixfmt == RagePixelFormat_Invalid) {
    /* We weren't given a natively-supported pixel format.  Pick a supported
     * one.  This is a fallback case, and implies a second conversion. */
    int depth = TEXTUREMAN->GetPrefs().m_iMovieColorDepth;
    switch (depth) {
      default:
        if (LOG != nullptr) {
          LOG->Warn("Unsupported movie color depth: %i", depth);
        }
        depth = 32;
        [[fallthrough]];
      case 16:
        if (DISPLAY->SupportsTextureFormat(RagePixelFormat_RGB5)) {
          pixfmt = RagePixelFormat_RGB5;
        } else {
          pixfmt = RagePixelFormat_RGBA4;
        }

        break;

      case 32:
        if (DISPLAY->SupportsTextureFormat(RagePixelFormat_RGB8)) {
          pixfmt = RagePixelFormat_RGB8;
        } else if (DISPLAY->SupportsTextureFormat(RagePixelFormat_RGBA8)) {
          pixfmt = RagePixelFormat_RGBA8;
        } else if (DISPLAY->SupportsTextureFormat(RagePixelFormat_RGB5)) {
          pixfmt = RagePixelFormat_RGB5;
        } else {
          pixfmt = RagePixelFormat_RGBA4;
        }
        break;
    }
  }

  if (fmt != PixelFormatYCbCr_Invalid) {
    intermediate_texture_.reset();
    sprite_->UnloadTexture();

    /* Create the render target.  This will receive the final, converted
     * texture. */
    RenderTargetParam param;
    param.iWidth = m_iImageWidth;
    param.iHeight = m_iImageHeight;

    RageTextureID TargetID(GetID());
    TargetID.filename += " target";
    render_target_ = std::make_unique<RageTextureRenderTarget>(TargetID, param);
    if (!render_target_->IsValid()) {
      render_target_.reset();
      return false;
    }

    /* Create the intermediate texture.  This receives the YUV image. */
    RageTextureID IntermedID(GetID());
    IntermedID.filename += " intermediate";

    intermediate_texture_ =
        std::make_unique<RageMovieTexture_Generic_Intermediate>(
            IntermedID, decoder_->GetWidth(), decoder_->GetHeight(),
            surface_->w, surface_->h, power_of_two(surface_->w),
            power_of_two(surface_->h), *surface_->format, pixfmt);
    if (intermediate_texture_->GetTexHandle() == 0) {
      intermediate_texture_.reset();
      render_target_.reset();
      return false;
    }

    /* Configure the sprite.  This blits the intermediate onto the ifnal render
     * target. */
    sprite_->SetHorizAlign(align_left);
    sprite_->SetVertAlign(align_top);

    /* Hack: Sprite wants to take ownership of the texture, and will decrement
     * the refcount when it unloads the texture.  Normally we'd make a "copy",
     * but we can't access RageTextureManager from here.  Just increment the
     * refcount. */
    RageTexture* sprite_texture =
        TEXTUREMAN->CopyTexture(intermediate_texture_.get());
    if (sprite_texture == nullptr) {
      intermediate_texture_.reset();
      render_target_.reset();
      return false;
    }
    sprite_->SetTexture(sprite_texture);
    sprite_->SetEffectMode(GetEffectMode(fmt));

    return true;
  }

  texture_handle_ = DISPLAY->CreateTexture(pixfmt, surface_, false);
  return texture_handle_ != 0;
}

/*
 * Returns:
 *  <= 0 if it's time for the next frame to display
 *   > 0 (seconds) if it's not yet time to display
 */
float MovieTexture_Generic::CheckFrameTime() {
  if (!std::isfinite(rate_) || rate_ == 0) {
    return 1;  // "a long time until the next frame"
  }
  return (decoder_->GetTimestamp() - clock_) / rate_;
}

void MovieTexture_Generic::UpdateMovie(float seconds) {
  // Quick exit in case we failed to decode the movie.
  if (HasDecodeFailed()) {
    return;
  }
  if (decoder_ == nullptr || !std::isfinite(seconds) || !std::isfinite(rate_)) {
    return;
  }
  clock_ += seconds * rate_;
  if (!std::isfinite(clock_)) {
    clock_ = 0.0f;
    return;
  }

  // If the frame isn't ready, don't update. This does mean the video
  // will "speed up" to catch up when decoding does outpace display.
  //
  // In practice, display should rarely, if ever, outpace decoding.
  if (decoder_->IsCurrentFrameReady() && CheckFrameTime() <= 0) {
    UpdateFrame();
    return;
  }
}

void MovieTexture_Generic::UpdateFrame() {
  if (finished_) {
    return;
  }
  if (DISPLAY == nullptr || decoder_ == nullptr) {
    SetDecodeFailed();
    return;
  }

  /* Just in case we were invalidated: */
  if (!CreateTexture() || !IsValidMovieSurface(surface_)) {
    SetDecodeFailed();
    return;
  }

  if (texture_lock_ != nullptr) {
    uintptr_t iHandle = intermediate_texture_ != nullptr
                            ? intermediate_texture_->GetTexHandle()
                            : this->GetTexHandle();
    if (iHandle == 0) {
      return;
    }
    texture_lock_->Lock(iHandle, surface_);
  }

  int frame_ret = -1;
  // Our frame buffer should (almost) always be 50 ahead of our current frame to
  // display, which is when IsCurrentFrameReady will evaluate to false. This
  // loop will continue attempting to find a displayable frame until we hit that
  // limit. If we really can't find a frame after that, then the currently
  // displayed frame will appear stuck.
  constexpr int kMaxSkippedFramesPerUpdate = 256;
  int skipped_frames = 0;
  while (frame_ret < 0 && decoder_->IsCurrentFrameReady() &&
         skipped_frames < kMaxSkippedFramesPerUpdate) {
    frame_ret = decoder_->GetFrame(surface_);
    ++skipped_frames;

    // Are we looping?
    if (decoder_->EndOfMovie() && loop_) {
      if (LOG != nullptr) {
        LOG->Info("File \"%s\" looping", GetID().filename.c_str());
      }
      decoder_->Rollover();
      clock_ = 0.0;
    } else if (decoder_->EndOfMovie()) {
      // At the end of the movie, and not looping.
      finished_ = true;
    }

    // If we failed to display the frame, it's getting skipped, advance the
    // clock.
    if (frame_ret < 0) {
      clock_ += (decoder_->GetTimestamp() - clock_);
    }
  }

  // There's an issue with the frame, make sure it does not get
  // uploaded.
  if (frame_ret < 0) {
    if (texture_lock_ != nullptr) {
      texture_lock_->Unlock(surface_, true);
    }
    return;
  }

  if (texture_lock_ != nullptr) {
    texture_lock_->Unlock(surface_, true);
  }

  if (render_target_ != nullptr) {
    CHECKPOINT_M("About to upload the texture.");

    /* If we have no texture_lock_, we still have to upload the texture. */
    if (texture_lock_ == nullptr) {
      if (intermediate_texture_ == nullptr ||
          intermediate_texture_->GetTexHandle() == 0) {
        return;
      }
      DISPLAY->UpdateTexture(
          intermediate_texture_->GetTexHandle(), surface_, 0, 0, surface_->w,
          surface_->h);
    }
    if (!render_target_->IsValid()) {
      return;
    }
    render_target_->BeginRenderingTo(false);
    try {
      sprite_->Draw();
    } catch (...) {
      render_target_->FinishRenderingTo();
      throw;
    }
    render_target_->FinishRenderingTo();
  } else {
    if (texture_lock_ == nullptr) {
      if (texture_handle_ == 0) {
        return;
      }
      DISPLAY->UpdateTexture(
          texture_handle_, surface_, 0, 0, m_iImageWidth, m_iImageHeight);
    }
  }
}

static EffectMode EffectModes[] = {
    EffectMode_YUYV422,
};
static_assert(ARRAYLEN(EffectModes) == NUM_PixelFormatYCbCr);

EffectMode MovieTexture_Generic::GetEffectMode(
    MovieDecoderPixelFormatYCbCr fmt) {
  if (fmt < 0 || fmt >= NUM_PixelFormatYCbCr) {
    return EffectMode_Normal;
  }
  return EffectModes[fmt];
}

void MovieTexture_Generic::Reload() {}

void MovieTexture_Generic::SetPosition(float seconds) {
  if (!std::isfinite(seconds) || decoder_ == nullptr) {
    return;
  }
  // TODO: The only non-zero use case of this function would be practice mode.
  // Implement this by mathing out fSeconds and frame counts to seek the
  // video.
  if (seconds != 0) {
    if (LOG != nullptr) {
      LOG->Warn(
          "MovieTexture_Generic::SetPosition(%f): non-0 seeking unsupported; "
          "ignored",
          seconds);
    }
    return;
  }

  if (LOG != nullptr) {
    LOG->Trace("Seek to %f", seconds);
  }
  clock_ = 0;
  decoder_->Rewind();
}

void MovieTexture_Generic::SetPlaybackRate(float rate) {
  if (!std::isfinite(rate) || rate < 0.0f) {
    rate = 0.0f;
  }
  rate_ = rate;
}

void MovieTexture_Generic::SetLooping(bool looping) {
  loop_ = looping;
  if (decoder_ != nullptr) {
    decoder_->SetLooping(loop_);
  }
}

uintptr_t MovieTexture_Generic::GetTexHandle() const {
  if (render_target_ != nullptr) {
    return render_target_->GetTexHandle();
  }

  return texture_handle_;
}

/*
 * (c) 2003-2005 Glenn Maynard
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
