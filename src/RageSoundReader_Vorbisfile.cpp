#include "RageSoundReader_Vorbisfile.h"

#include "PerfDiagnostics.h"
#include "RageException.h"
#include "RageFileBasic.h"
#include "RageLog.h"
#include "RageSoundReader.h"
#include "RageSoundReader_FileReader.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "global.h"
#include "ogg/os_types.h"
#include "vorbis/codec.h"

#if defined(INTEGER_VORBIS)
#include <tremor/ivorbisfile.h>

#include <string>
#else
#include <vorbis/vorbisfile.h>
#endif

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdarg>
#include <cstddef>
#include <cstring>
#include <limits>
#include <new>
#include <string>

static void TraceReviewSrcError(const std::string& sError) {
  LogReviewSrcDiagnostics("%s", sError.c_str());
}

static size_t OggRageFile_read_func(
    void* ptr, size_t size, size_t nmemb, void* datasource) {
  if (ptr == nullptr || datasource == nullptr || size == 0 || nmemb == 0) {
    return 0;
  }
  const size_t maxElementsByCount =
      static_cast<size_t>(std::numeric_limits<int>::max());
  const size_t maxElementsByBytes =
      static_cast<size_t>(std::numeric_limits<int>::max()) / size;
  const size_t elementsToRead =
      std::min(nmemb, std::min(maxElementsByCount, maxElementsByBytes));
  if (elementsToRead == 0) {
    return 0;
  }

  RageFileBasic* f = (RageFileBasic*)datasource;
  const int ret = f->Read(ptr, size, static_cast<int>(elementsToRead));
  return ret < 0 ? 0 : static_cast<size_t>(ret);
}

static int OggRageFile_seek_func(
    void* datasource, ogg_int64_t offset, int whence) {
  if (datasource == nullptr || offset < std::numeric_limits<int>::min() ||
      offset > std::numeric_limits<int>::max()) {
    return -1;
  }
  RageFileBasic* f = (RageFileBasic*)datasource;
  return f->Seek((int)offset, whence) < 0 ? -1 : 0;
}

static int OggRageFile_close_func(void* datasource) { return 0; }

static long OggRageFile_tell_func(void* datasource) {
  if (datasource == nullptr) {
    return -1;
  }
  RageFileBasic* f = (RageFileBasic*)datasource;
  return f->Tell();
}

static std::string ov_ssprintf(int err, const char* fmt, ...) {
  va_list va;
  va_start(va, fmt);
  std::string s = vssprintf(fmt, va);
  va_end(va);

  std::string errstr;
  switch (err) {
    // OV_FALSE, OV_EOF, and OV_HOLE were added to this switch because
    // OV_EOF cases were being reported as unknown. -Kyz
    case OV_FALSE:
      errstr = "OV_FALSE";
      break;
    case OV_EOF:
      errstr = "OV_EOF";
      break;
    case OV_HOLE:
      errstr = "OV_HOLE";
      break;
    /* XXX: In the case of OV_EREAD, can we snoop at errno? */
    case OV_EREAD:
      errstr = "Read error";
      break;
    case OV_EFAULT:
      errstr = "Internal error";
      break;
    case OV_EIMPL:
      errstr = "Feature not implemented";
      break;
    case OV_EINVAL:
      errstr = "Invalid argument";
      break;
    case OV_ENOTVORBIS:
      errstr = "Not Vorbis data";
      break;
    case OV_EBADHEADER:
      errstr = "Invalid Vorbis bitstream header";
      break;
    case OV_EVERSION:
      errstr = "Vorbis version mismatch";
      break;
    case OV_ENOTAUDIO:
      errstr = "OV_ENOTAUDIO";
      break;
    case OV_EBADPACKET:
      errstr = "OV_EBADPACKET";
      break;
    case OV_EBADLINK:
      errstr = "Link corrupted";
      break;
    case OV_ENOSEEK:
      errstr = "Stream is not seekable";
      break;
    default:
      errstr = ssprintf("unknown error %i", err);
      break;
  }

  return s + ssprintf(" (%s)", errstr.c_str());
}

RageSoundReader_FileReader::OpenResult RageSoundReader_Vorbisfile::Open(
    RageFileBasic* pFile) {
  Close();
  if (pFile == nullptr) {
    SetError("No file handle");
    return OPEN_FATAL_ERROR;
  }

  m_pFile = pFile;
  OggVorbis_File* newVf = nullptr;
  try {
    newVf = new OggVorbis_File;
  } catch (const std::bad_alloc&) {
    const std::string error =
        "SRC_AUDIT_FIX SRC-2802: Vorbis reader allocation failed";
    SetError(error);
    TraceReviewSrcError(error);
    m_pFile = nullptr;
    return OPEN_FATAL_ERROR;
  }
  memset(newVf, 0, sizeof(*newVf));

  ov_callbacks callbacks;
  callbacks.read_func = OggRageFile_read_func;
  callbacks.seek_func = OggRageFile_seek_func;
  callbacks.close_func = OggRageFile_close_func;
  callbacks.tell_func = OggRageFile_tell_func;

  int ret = ov_open_callbacks(pFile, newVf, nullptr, 0, callbacks);
  if (ret < 0) {
    SetError(ov_ssprintf(ret, "ov_open failed"));
    delete newVf;
    m_pFile = nullptr;
    switch (ret) {
      case OV_ENOTVORBIS:
        return OPEN_UNKNOWN_FILE_FORMAT;
      default:
        return OPEN_FATAL_ERROR;
    }
  }

  vf = newVf;
  eof = false;
  read_offset = ov_pcm_tell(vf);
  if (read_offset < 0) {
    const std::string error =
        "SRC_AUDIT_FIX SRC-2803: Vorbis stream position unavailable after "
        "open";
    SetError(error);
    TraceReviewSrcError(error);
    ResetDecoderState();
    return OPEN_FATAL_ERROR;
  }

  vorbis_info* vi = ov_info(vf, -1);
  if (vi == nullptr || vi->channels <= 0 || vi->channels > 2 ||
      vi->rate <= 0) {
    SetError("Invalid Vorbis stream metadata");
    ResetDecoderState();
    return OPEN_FATAL_ERROR;
  }
  channels = vi->channels;

  return OPEN_OK;
}

int RageSoundReader_Vorbisfile::GetLength() const {
  if (vf == nullptr) {
    return 0;
  }
#if defined(INTEGER_VORBIS)
  const ogg_int64_t len = ov_time_total(vf, -1);
  if (len <= 0) {
    return 0;
  }
  if (len > std::numeric_limits<int>::max()) {
    return std::numeric_limits<int>::max();
  }
  return static_cast<int>(len);
#else
  const double lenSeconds = ov_time_total(vf, -1);
  if (!std::isfinite(lenSeconds) || lenSeconds <= 0.0) {
    return 0;
  }
  const double maxSeconds =
      static_cast<double>(std::numeric_limits<int>::max()) / 1000.0;
  if (lenSeconds >= maxSeconds) {
    return std::numeric_limits<int>::max();
  }
  return static_cast<int>(lenSeconds * 1000.0);
#endif
}

int RageSoundReader_Vorbisfile::SetPosition(int iFrame) {
  if (vf == nullptr) {
    return ERROR;
  }
  eof = false;

  const ogg_int64_t sample = ogg_int64_t(std::max(0, iFrame));

  int ret = ov_pcm_seek(vf, sample);
  if (ret < 0) {
    /* Returns OV_EINVAL on EOF. */
    if (ret == OV_EINVAL || ret == OV_EOF) {
      eof = true;
      return 0;
    }
    SetError(ov_ssprintf(ret, "ogg: SetPosition failed"));
    return -1;
  }
  read_offset = ov_pcm_tell(vf);
  if (read_offset < 0) {
    const std::string error =
        "SRC_AUDIT_FIX SRC-2803: Vorbis stream position unavailable after "
        "seek";
    SetError(error);
    TraceReviewSrcError(error);
    return -1;
  }

  return 1;
}

int RageSoundReader_Vorbisfile::Read(float* buf, int iFrames) {
  if (iFrames == 0) {
    return 0;
  }
  if (vf == nullptr || buf == nullptr || iFrames < 0 || channels == 0 ||
      channels > static_cast<unsigned>(std::numeric_limits<int>::max())) {
    return ERROR;
  }
  const int channel_count = static_cast<int>(channels);
  int frames_read = 0;
  unsigned consecutiveHoles = 0;
  static constexpr unsigned kMaxConsecutiveHoles = 1024;

  while (iFrames && !eof) {
    if (channel_count >
        std::numeric_limits<int>::max() / static_cast<int>(sizeof(float))) {
      return ERROR;
    }
    const int bytes_per_frame = static_cast<int>(sizeof(float)) * channel_count;

    int iFramesRead = 0;

    {
      const ogg_int64_t curofs = ov_pcm_tell(vf);
      if (curofs < 0) {
        const std::string error =
            "SRC_AUDIT_FIX SRC-2803: Vorbis stream position unavailable during "
            "read";
        SetError(error);
        TraceReviewSrcError(error);
        return ERROR;
      }
      if (curofs < read_offset) {
        /* The timestamps moved backwards.  Ignore it.  This file probably
         * won't sync correctly. */
        if (LOG != nullptr) {
          LOG->Trace(
              "p ahead %p %lld < %lld, we're ahead by %lld",
              static_cast<void*>(this), static_cast<long long>(curofs),
              static_cast<long long>(read_offset),
              static_cast<long long>(read_offset - curofs));
        }
        read_offset = curofs;
      } else if (curofs > read_offset) {
        /* Our offset doesn't match.  We have a hole in the data, or corruption.
         * If we're reading with accurate syncing, insert silence to line it up.
         * That way, corruptions in the file won't casue desyncs. */

        /* In bytes: */
        int iSilentFrames = static_cast<int>(
            std::min<ogg_int64_t>(curofs - read_offset, iFrames));
        if (iSilentFrames >
            std::numeric_limits<int>::max() / bytes_per_frame) {
          return ERROR;
        }
        int silence = iSilentFrames * bytes_per_frame;
        CHECKPOINT_M(ssprintf(
            "p %lld,%lld: %i frames of silence needed",
            static_cast<long long>(curofs), static_cast<long long>(read_offset),
            silence));

        memset(buf, 0, silence);
        iFramesRead = iSilentFrames;
      }
    }

    if (iFramesRead == 0) {
      int bstream;
#if defined(INTEGER_VORBIS)
      const int integer_bytes_per_frame =
          channel_count * static_cast<int>(sizeof(int16_t));
      if (integer_bytes_per_frame <= 0 ||
          iFrames > std::numeric_limits<int>::max() / integer_bytes_per_frame) {
        return ERROR;
      }
      int ret = ov_read(
          vf, (char*)buf, iFrames * integer_bytes_per_frame, &bstream);
#else  // float vorbis decoder
      float** pcm;
      int ret = ov_read_float(vf, &pcm, iFrames, &bstream);
#endif

      {
        vorbis_info* vi = ov_info(vf, -1);
        if (vi == nullptr) {
          SetError("Vorbis stream info unavailable");
          return ERROR;
        }

        if (vi->channels != channel_count) {
          SetError(ssprintf(
              "File \"%s\" changes channel count from %i to %i; not "
              "supported.",
              GetSourcePath().c_str(), channel_count, (int)vi->channels));
          return ERROR;
        }
      }

      if (ret == OV_HOLE) {
        if (++consecutiveHoles > kMaxConsecutiveHoles) {
          SetError("Vorbis read aborted after too many consecutive holes");
          return ERROR;
        }
        continue;
      }
      if (ret == OV_EBADLINK) {
        SetError(ssprintf("Read: OV_EBADLINK"));
        return ERROR;
      }
      if (ret < 0) {
        SetError(ov_ssprintf(ret, "Vorbis read failed"));
        return ERROR;
      }

      if (ret == 0) {
        eof = true;
        continue;
      }
      consecutiveHoles = 0;

#if defined(INTEGER_VORBIS)
      if (ret > 0) {
        int iSamplesRead = ret / sizeof(int16_t);
        iFramesRead = iSamplesRead / channel_count;

        /* Convert in reverse, so we can do it in-place. */
        const int16_t* pIn = (int16_t*)buf;
        float* pOut = (float*)buf;
        for (int i = iSamplesRead - 1; i >= 0; --i) {
          pOut[i] = pIn[i] / 32768.0f;
        }
      }
#else
      if (ret > 0) {
        if (pcm == nullptr) {
          SetError("Vorbis decoder returned no PCM planes");
          return ERROR;
        }
        iFramesRead = ret;

        int iNumChannels = channel_count;
        for (int iChannel = 0; iChannel < iNumChannels; ++iChannel) {
          const float* pChannelIn = pcm[iChannel];
          if (pChannelIn == nullptr) {
            SetError("Vorbis decoder returned a null PCM channel");
            return ERROR;
          }
          float* pChannelOut = &buf[iChannel];
          for (int i = 0; i < iFramesRead; ++i) {
            *pChannelOut = *pChannelIn;
            ++pChannelIn;
            pChannelOut += iNumChannels;
          }
        }
      }
#endif
    }

    read_offset += iFramesRead;

    buf += iFramesRead * channel_count;
    frames_read += iFramesRead;
    iFrames -= iFramesRead;
  }

  if (!frames_read) {
    return END_OF_FILE;
  }

  return frames_read;
}

int RageSoundReader_Vorbisfile::GetSampleRate() const {
  if (vf == nullptr) {
    return 0;
  }

  vorbis_info* vi = ov_info(vf, -1);
  if (vi == nullptr) {
    return 0;
  }

  return vi->rate;
}

int RageSoundReader_Vorbisfile::GetNextSourceFrame() const {
  if (vf == nullptr) {
    return 0;
  }

  const ogg_int64_t iFrame = ov_pcm_tell(vf);
  if (iFrame <= 0) {
    return 0;
  }
  if (iFrame > std::numeric_limits<int>::max()) {
    return std::numeric_limits<int>::max();
  }
  return static_cast<int>(iFrame);
}

RageSoundReader_Vorbisfile::RageSoundReader_Vorbisfile() = default;

RageSoundReader_Vorbisfile::~RageSoundReader_Vorbisfile() { Close(); }

void RageSoundReader_Vorbisfile::ResetDecoderState() {
  if (vf != nullptr) {
    ov_clear(vf);
  }
  delete vf;
  vf = nullptr;
  m_pFile = nullptr;
  eof = true;
  read_offset = 0;
  channels = 0;
}

void RageSoundReader_Vorbisfile::Close() {
  ResetDecoderState();
  SetError("");
}

RageSoundReader_Vorbisfile* RageSoundReader_Vorbisfile::Copy() const {
  if (m_pFile.isNull()) {
    return nullptr;
  }
  RageFileBasic* pFile = m_pFile->Copy();
  if (pFile == nullptr) {
    return nullptr;
  }
  if (pFile->Seek(0) == -1) {
    const std::string error =
        "SRC_AUDIT_FIX SRC-3320: Vorbis copy could not rewind its file";
    TraceReviewSrcError(error);
    delete pFile;
    return nullptr;
  }
  RageSoundReader_Vorbisfile* ret = nullptr;
  try {
    ret = new RageSoundReader_Vorbisfile;
  } catch (const std::bad_alloc&) {
    delete pFile;
    return nullptr;
  }

  /* If we were able to open the sound in the first place, we expect to
   * be able to reopen it. */
  if (ret->Open(pFile) != OPEN_OK) {
    delete ret;
    return nullptr;
  }

  return ret;
}

/*
 * Copyright (c) 2003 Glenn Maynard
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
