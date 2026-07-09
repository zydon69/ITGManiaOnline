/* RageSoundReader_Extend - Add looping, delay and truncation and fading. */

#ifndef RAGE_SOUND_READER_EXTEND
#define RAGE_SOUND_READER_EXTEND

#include <cstdint>
#include <string>

#include "RageSoundReader.h"
#include "RageSoundReader_Filter.h"

class RageSoundReader_Extend : public RageSoundReader_Filter {
 public:
  RageSoundReader_Extend(RageSoundReader* pSource);
  RageSoundReader_Extend(const RageSoundReader_Extend& cpy) = delete;
  RageSoundReader_Extend& operator=(const RageSoundReader_Extend& cpy) = delete;
  ~RageSoundReader_Extend() override = default;
  RageSoundReader_Extend* Copy() const override;

  int GetLength() const override;
  int GetLength_Fast() const override;
  int SetPosition(int iFrame) override;
  int Read(float* pBuffer, int iFrames) override;
  int GetNextSourceFrame() const override;
  bool SetProperty(const std::string& sProperty, float fValue) override;
  std::string GetError() const override;

 private:
  bool GetEndFrame(std::int64_t* pEndFrame) const;
  int GetData(
      float* pBuffer, int iFrames, bool* pAdvancedPosition,
      std::int64_t* pBlockStartFrame);
  void ClearError() const;
  void SetError(const std::string& sError) const;

  std::int64_t m_iPositionFrames = 0;

  enum StopMode { M_LOOP, M_STOP, M_CONTINUE };
  StopMode m_StopMode = M_STOP;
  std::int64_t m_iStartFrames = 0;
  std::int64_t m_iLengthFrames = -1;
  std::int64_t m_iFadeInFrames = 0;
  std::int64_t m_iFadeOutFrames = 0;
  bool m_bIgnoreFadeInFrames = false;
  mutable std::string m_sError;
};

#endif

/*
 * Copyright (c) 2003-2006 Glenn Maynard
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
