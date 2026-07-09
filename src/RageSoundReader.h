/* RageSoundReader - Data source for a RageSound. */

#ifndef RAGE_SOUND_READER_H
#define RAGE_SOUND_READER_H

#include <cstdint>
#include <string>

class RageSoundReader {
 public:
  enum class PropertySetStatus {
    APPLIED,
    INVALID_REQUEST,
    UNSUPPORTED_OR_REJECTED
  };

  struct PropertySetResult {
    PropertySetStatus status = PropertySetStatus::UNSUPPORTED_OR_REJECTED;
    bool Applied() const { return status == PropertySetStatus::APPLIED; }
  };

  RageSoundReader() = default;
  RageSoundReader(const RageSoundReader&) = default;
  RageSoundReader& operator=(const RageSoundReader&) = default;
  virtual int GetLength() const = 0;                         /* ms */
  virtual int GetLength_Fast() const { return GetLength(); } /* ms */
  virtual int SetPosition(int iFrame) = 0;
  virtual int Read(float* pBuf, int iFrames) = 0;
  virtual ~RageSoundReader() = default;
  virtual RageSoundReader* Copy() const = 0;
  static RageSoundReader* CopyReader(const RageSoundReader* pCopy);
  virtual int GetSampleRate() const = 0;
  virtual unsigned GetNumChannels() const = 0;
  virtual bool SetProperty(
      const std::string& /* sProperty */, float /* fValue */) {
    return false;
  }
  PropertySetResult TrySetProperty(const std::string& sProperty, float fValue);
  static const char* PropertySetStatusToString(PropertySetStatus status);
  virtual RageSoundReader* GetSource() { return nullptr; }
  virtual std::string GetSourcePath() const { return std::string(); }
  virtual void SetDebugSourcePath(const std::string& /* sPath */) {}

  /* Return values for Read(). */
  enum {
    /* An error occurred; GetError() will return a description of the error. */
    ERROR = -1,
    END_OF_FILE = -2,

    /* A nonblocking buffer in the filter chain has underrun, and no data is
     * currently available. */
    WOULD_BLOCK = -3,

    /* The source position has changed in an expected way, such as looping.
     * Seeking manually will not cause this. */
    STREAM_LOOPED = -4,
  };

  /* GetNextSourceFrame() provides the source frame associated with the next
   * frame that will be read via Read().  GetStreamToSourceRatio() returns the
   * ratio for extrapolating the source frames of the remainder of the block.
   * These values are valid so long as no parameters are changed before the next
   * Read(). */
  virtual int GetNextSourceFrame() const = 0;
  virtual std::int64_t GetNextSourceFrame64() const {
    return GetNextSourceFrame();
  }
  virtual float GetStreamToSourceRatio() const = 0;

  virtual std::string GetError() const { return m_sBaseError; }
  std::string GetBaseError() const { return m_sBaseError; }
  void ClearBaseError() const { m_sBaseError.clear(); }
  void SetBaseError(const std::string& sError) const { m_sBaseError = sError; }
  static int ClampSourceFrameToInt(std::int64_t iFrame);
  int RetriedRead(
      float* pBuffer, int iFrames, std::int64_t* iSourceFrame = nullptr,
      float* fRate = nullptr);
  int RetriedRead(
      float* pBuffer, int iFrames, int* iSourceFrame,
      float* fRate);

 private:
  mutable std::string m_sBaseError;
};

#endif

/*
 * Copyright (c) 2002-2003 Glenn Maynard
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
