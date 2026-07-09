#ifndef RAGE_SOUND_READER_MERGE
#define RAGE_SOUND_READER_MERGE

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "RageSoundReader.h"

/** @brief Mix multiple sound readers into one stream. */
class RageSoundReader_Merge : public RageSoundReader {
 public:
  RageSoundReader_Merge();
  RageSoundReader_Merge(const RageSoundReader_Merge& cpy) = delete;
  RageSoundReader_Merge& operator=(const RageSoundReader_Merge& cpy) = delete;
  ~RageSoundReader_Merge() override;
  RageSoundReader_Merge* Copy() const override;

  int GetLength() const override;
  int GetLength_Fast() const override;
  int SetPosition(int iFrame) override;
  int Read(float* pBuf, int iFrames) override;
  int GetSampleRate() const override { return m_iSampleRate; }
  unsigned GetNumChannels() const override { return m_iChannels; }
  bool SetProperty(const std::string& sProperty, float fValue) override;
  int GetNextSourceFrame() const override;
  std::int64_t GetNextSourceFrame64() const override;
  float GetStreamToSourceRatio() const override {
    return m_fCurrentStreamToSourceRatio;
  }
  std::string GetError() const override;

  /* Takes ownership of pSound. */
  void AddSound(RageSoundReader* pSound);

  /**
   * @brief Finish adding sounds.
   * @param iPreferredSampleRate the sample rate for the sounds. */
  void Finish(int iPreferredSampleRate);

 private:
  int GetSampleRateInternal() const;
  void ClearError() const;
  void SetError(const std::string& sError) const;
  bool IsSoundTopologyUsable(const RageSoundReader* pSound) const;
  void EraseNullSounds();

  int m_iSampleRate = -1;
  unsigned m_iChannels = 0;
  bool m_bFinished = false;

  std::vector<std::unique_ptr<RageSoundReader>> m_aSounds;
  mutable std::string m_sError;

  /* Read state: */
  std::int64_t m_iNextSourceFrame = 0;
  float m_fCurrentStreamToSourceRatio = 1.0f;
};

#endif

/**
 * @file
 * @author Glenn Maynard (c) 2004-2006
 * @section LICENSE
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
