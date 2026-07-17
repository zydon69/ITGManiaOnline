#include "RageSurface_Load_PNG.h"

#include <png.h>

#include <csetjmp>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <new>
#include <string>

#include "RageFile.h"
#include "RageLog.h"
#include "PerfDiagnostics.h"
#include "RageSurface.h"
#include "RageSurface_Load.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "RageUtil/Endian.h"
#include "global.h"
#include "pngconf.h"

#if defined(_MSC_VER)
#if defined(_BINARY_PNG)
#pragma comment(lib, "libpng.lib")
#endif
#pragma warning(disable : 4611) /* interaction between '_setjmp' and C++ \
                                   object destruction is non-portable */
#endif                          // _MSC_VER

namespace {
void RageFile_png_read(png_struct* png, png_byte* p, png_size_t size) {
  if (LogVerboseContentLoadDiagnosticsEnabled()) {
    CHECKPOINT_M("Reading the png file.");
  }
  RageFile* f = static_cast<RageFile*>(png_get_io_ptr(png));
  if (f == nullptr ||
      size > static_cast<png_size_t>(std::numeric_limits<int>::max())) {
    png_error(png, "Invalid PNG read request");
    return;
  }

  int got = f->Read(p, size);
  if (got == -1) {
    /* png_error will call PNG_Error, which will longjmp.  If we just pass
     * GetError().c_str() to it, a temporary may be created; since control
     * never returns here, it may never be destructed and we could leak. */
    static char error[256];
    strncpy(error, f->GetError().c_str(), sizeof(error));
    error[sizeof(error) - 1] = 0;
    png_error(png, error);
  } else if (got != (int)size) {
    png_error(png, "Unexpected EOF");
  }
}

struct error_info {
  char* err;
  const char* fn;
};

void PNG_Error(png_struct* png, const char* error) {
  CHECKPOINT_M(ssprintf(
      "PNG error during processing: %s",
      error != nullptr ? error : "Unknown PNG error"));
  error_info* info = static_cast<error_info*>(png_get_error_ptr(png));
  if (info != nullptr && info->err != nullptr) {
    strncpy(info->err, error != nullptr ? error : "Unknown PNG error", 1024);
    info->err[1023] = 0;
    if (LOG != nullptr) {
      LOG->Trace(
          "loading \"%s\": err: %s", info->fn != nullptr ? info->fn : "",
          info->err);
    }
  }
  longjmp(png_jmpbuf(png), 1);
}

void PNG_Warning(png_struct* png, const char* warning) {
  if (LogVerboseContentLoadDiagnosticsEnabled()) {
    CHECKPOINT_M(ssprintf("PNG warning during processing: %s", warning));
  }
  error_info* info = static_cast<error_info*>(png_get_error_ptr(png));
  if (LOG != nullptr) {
    LOG->Trace(
        "loading \"%s\": warning: %s",
        info != nullptr && info->fn != nullptr ? info->fn : "",
        warning != nullptr ? warning : "Unknown PNG warning");
  }
}

/* Since libpng forces us to use longjmp (gross!), this function shouldn't
 * create any C++ objects, and needs to watch out for memleaks. */
static RageSurface* RageSurface_Load_PNG(
    RageFile* f, const char* fn, char errorbuf[1024], bool bHeaderOnly) {
  errorbuf[0] = '\0';
  error_info error;
  error.err = errorbuf;
  error.fn = fn;

  png_struct* png = png_create_read_struct(
      PNG_LIBPNG_VER_STRING, &error, PNG_Error, PNG_Warning);

  if (png == nullptr) {
    sprintf(errorbuf, "creating png_create_read_struct failed");
    return nullptr;
  }

  png_info* info_ptr = png_create_info_struct(png);
  if (info_ptr == nullptr) {
    png_destroy_read_struct(&png, nullptr, nullptr);
    sprintf(errorbuf, "creating png_create_info_struct failed");
    return nullptr;
  }

  RageSurface* volatile img = nullptr;
  if (LogVerboseContentLoadDiagnosticsEnabled()) {
    CHECKPOINT_M("PNG longjmp guard installed.");
  }

  png_byte** row_pointers = nullptr;

  // Throwing an exception in the error callback would make the exception
  // pass through C code, which is undefined behavior.  Works fine on Linux,
  // and on macOS with C++11, but does not work on macOS without C++11. -Kyz
  if (setjmp(png_jmpbuf(png))) {
    png_destroy_read_struct(&png, &info_ptr, nullptr);
    delete img;
    if (row_pointers != nullptr) {
      delete[] row_pointers;
    }
    return nullptr;
  }

  png_set_read_fn(png, f, RageFile_png_read);

  png_read_info(png, info_ptr);

  png_uint_32 width, height;
  int bit_depth, color_type;
  png_get_IHDR(
      png, info_ptr, &width, &height, &bit_depth, &color_type, nullptr, nullptr,
      nullptr);

  constexpr uint64_t kMaxDecodedPngBytes = 256ULL * 1024ULL * 1024ULL;
  if (width == 0 || height == 0 ||
      width > static_cast<png_uint_32>(std::numeric_limits<int>::max()) ||
      height > static_cast<png_uint_32>(std::numeric_limits<int>::max())) {
    png_error(png, "PNG dimensions exceed the supported decode limit");
  }
  const uint64_t decodedPixels =
      static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
  if (decodedPixels > kMaxDecodedPngBytes / 4ULL) {
    png_error(png, "PNG dimensions exceed the supported decode limit");
  }

  /* If bHeaderOnly is true, don't allocate the pixel storage space or
   * decompress the image.  Just return an empty surface with only the width and
   * height set. */
  if (bHeaderOnly) {
    if (LogVerboseContentLoadDiagnosticsEnabled()) {
      CHECKPOINT_M("PNG header-only load.");
    }
    try {
      img = CreateSurfaceFrom(
          width, height, 32, 0, 0, 0, 0, nullptr,
          static_cast<uint32_t>(width * 4));
    } catch (const std::bad_alloc&) {
      png_error(png, "Could not allocate PNG header surface");
    }
    if (img == nullptr) {
      png_error(png, "Could not allocate PNG header surface");
    }
    png_destroy_read_struct(&png, &info_ptr, nullptr);
    return img;
  }

  png_set_strip_16(png); /* 16bit->8bit */
  png_set_packing(png);  /* 1,2,4 bit->8 bit */

  /* Expand grayscale images to the full 8 bits from 1, 2, or 4 bits/pixel */
  if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8) {
    png_set_expand_gray_1_2_4_to_8(png);
  }

  /* These are set for type == PALETTE. */
  RageSurfaceColor colors[256]{};
  int iColorKey = -1;

  /* We import three types of files: paletted, RGBX and RGBA.  The only
   * difference between RGBX and RGBA is that RGBX won't set the alpha mask, so
   * it's easier to tell later on that there's no alpha (without actually having
   * to do a pixel scan). */
  enum { PALETTE, RGBX, RGBA } type;
  switch (color_type) {
    case PNG_COLOR_TYPE_GRAY:
      /* Fake PNG_COLOR_TYPE_GRAY. */
      for (int i = 0; i < 256; ++i) {
        colors[i].r = colors[i].g = colors[i].b = (int8_t)i;
        colors[i].a = 0xFF;
      }

      type = PALETTE;
      break;

    case PNG_COLOR_TYPE_GRAY_ALPHA:
      type = RGBA;
      png_set_gray_to_rgb(png);
      break;
    case PNG_COLOR_TYPE_PALETTE:
      type = PALETTE;
      break;
    case PNG_COLOR_TYPE_RGB:
      type = RGBX;
      break;
    case PNG_COLOR_TYPE_RGB_ALPHA:
      type = RGBA;
      break;
    default:
      png_error(png, "Unsupported PNG color type");
      return nullptr;
  }

  if (LogVerboseContentLoadDiagnosticsEnabled()) {
    CHECKPOINT_M("PNG color analysis.");
  }
  if (color_type == PNG_COLOR_TYPE_GRAY) {
    png_color_16* trans;
    if (png_get_tRNS(png, info_ptr, nullptr, nullptr, &trans) ==
        PNG_INFO_tRNS) {
      iColorKey = trans->gray;
    }
  } else if (color_type == PNG_COLOR_TYPE_PALETTE) {
    int num_palette;
    png_color* palette;
    int ret = png_get_PLTE(png, info_ptr, &palette, &num_palette);
    if (ret != PNG_INFO_PLTE || palette == nullptr || num_palette <= 0 ||
        num_palette > 256) {
      png_error(png, "Invalid PNG palette");
    }

    png_byte* trans = nullptr;
    int num_trans = 0;
    png_get_tRNS(png, info_ptr, &trans, &num_trans, nullptr);

    for (int i = 0; i < num_palette; ++i) {
      colors[i].r = palette[i].red;
      colors[i].g = palette[i].green;
      colors[i].b = palette[i].blue;
      colors[i].a = 0xFF;
      if (i < num_trans) {
        colors[i].a = trans[i];
      }
    }
  } else {
    /* If we have RGB image and tRNS, it's a color key.  Just convert it to
     * RGBA. */
    if (png_get_valid(png, info_ptr, PNG_INFO_tRNS)) {
      /* We don't care about RGB color keys; just convert them to alpha. */
      png_set_tRNS_to_alpha(png);
      type = RGBA;
    }

    /* RGB->RGBX */
    png_set_filler(png, 0xff, PNG_FILLER_AFTER);
  }

  png_set_interlace_handling(png);

  png_read_update_info(png, info_ptr);

  switch (type) {
    case PALETTE:
      try {
        img = CreateSurface(width, height, 8, 0, 0, 0, 0);
      } catch (const std::bad_alloc&) {
        png_error(png, "Could not allocate paletted PNG surface");
      }
      if (img == nullptr || img->fmt.palette == nullptr) {
        png_error(png, "Could not allocate paletted PNG surface");
      }
      memcpy(img->fmt.palette->colors, colors, 256 * sizeof(RageSurfaceColor));

      if (iColorKey != -1) {
        img->format->palette->colors[iColorKey].a = 0;
      }

      break;
    case RGBX:
    case RGBA:
      try {
        img = CreateSurface(
            width, height, 32, Swap32BE(0xFF000000), Swap32BE(0x00FF0000),
            Swap32BE(0x0000FF00),
            Swap32BE(type == RGBA ? 0x000000FF : 0x00000000));
      } catch (const std::bad_alloc&) {
        png_error(png, "Could not allocate true-color PNG surface");
      }
      break;
    default:
      png_error(png, "Invalid PNG output format");
      return nullptr;
  }
  if (img == nullptr || img->pixels == nullptr) {
    png_error(png, "Could not allocate PNG surface");
  }

  row_pointers = new (std::nothrow) png_byte*[height];
  if (row_pointers == nullptr) {
    png_error(png, "Could not allocate PNG row table");
  }
  if (LogVerboseContentLoadDiagnosticsEnabled()) {
    CHECKPOINT_M(
        ssprintf("PNG row pointer table %p.", static_cast<void*>(row_pointers)));
  }

  for (unsigned y = 0; y < height; ++y) {
    png_byte* p = (png_byte*)img->pixels;
    row_pointers[y] = p + img->pitch * y;
  }

  png_read_image(png, row_pointers);

  png_read_end(png, info_ptr);
  png_destroy_read_struct(&png, &info_ptr, nullptr);

  if (row_pointers != nullptr) {
    delete[] row_pointers;
  }

  return img;
}

};  // namespace

RageSurfaceUtils::OpenResult RageSurface_Load_PNG(
    const std::string& sPath, RageSurface*& ret, bool bHeaderOnly,
    std::string& error) {
  RageFile f;
  if (!f.Open(sPath)) {
    error = f.GetError();
    return RageSurfaceUtils::OPEN_FATAL_ERROR;
  }

  char errorbuf[1024];
  ret = RageSurface_Load_PNG(&f, sPath.c_str(), errorbuf, bHeaderOnly);
  if (ret == nullptr) {
    error = errorbuf;
    return RageSurfaceUtils::OPEN_UNKNOWN_FILE_FORMAT;  // XXX
  }

  return RageSurfaceUtils::OPEN_OK;
}

/*
 * (c) 2004 Glenn Maynard
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
