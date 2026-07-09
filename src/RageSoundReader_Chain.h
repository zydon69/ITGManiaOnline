/* RageSoundReader_Chain - Chain sounds together */

#ifndef RAGE_SOUND_READER_CHAIN
#define RAGE_SOUND_READER_CHAIN

#include <cstdint>
#include <memory>
#include <map>
#include <limits>
#include <string>
#include <utility>
#include <vector>

#include "RageSoundConstants.h"
#include "RageSoundReader.h"

class RageSoundReader_Chain : public RageSoundReader {
 public:
  RageSoundReader_Chain();
  RageSoundReader_Chain(const RageSoundReader_Chain& rhs) = delete;
  RageSoundReader_Chain& operator=(const RageSoundReader_Chain& rhs) = delete;
  ~RageSoundReader_Chain();
  RageSoundReader_Chain* Copy() const override;

  /* Set the preferred sample rate.  This will only be used if the source sounds
   * use different sample rates. */
  void SetPreferredSampleRate(int iSampleRate) {
    m_iPreferredSampleRate = iSampleRate > 0 ? iSampleRate : FALLBACK_SAMPLE_RATE;
  }

  int LoadSound(std::string sPath);
  int LoadSound(RageSoundReader* pSound);

  /* Add the given sound to play after fOffsetSecs seconds.  Takes ownership
   * of pSound. */
  void AddSound(int iIndex, float fOffsetSecs, float fPan);

  /* Finish adding sounds. */
  void Finish();

  /* Return the number of added sounds. */
  int GetNumSounds() const {
    return m_aSounds.size() > static_cast<size_t>(std::numeric_limits<int>::max())
               ? std::numeric_limits<int>::max()
               : static_cast<int>(m_aSounds.size());
  }

  int GetLength() const override;
  int GetLength_Fast() const override;
  int SetPosition(int iFrame) override;
  int Read(float* pBuf, int iFrames) override;
  int GetSampleRate() const override;
	  unsigned GetNumChannels() const override { return m_iChannels; }
	  bool SetProperty(const std::string& sProperty, float fValue) override;
	  int GetNextSourceFrame() const override;
  std::int64_t GetNextSourceFrame64() const override;
	  float GetStreamToSourceRatio() const override;
	  std::string GetError() const override;

 private:
  int GetSampleRateInternal() const;
  void ClearError() const;
  void SetError(const std::string& sError) const;
  void RemoveNamedSoundPointersTo(const RageSoundReader* pSound);
  void ReplaceNamedSoundPointer(
      const RageSoundReader* pOldSound, RageSoundReader* pNewSound);
  bool IsSoundTopologyUsable(const RageSoundReader* pSound) const;
  bool ApplyPendingProperties(RageSoundReader* pSound) const;

  int m_iPreferredSampleRate;
  int m_iActualSampleRate;
  unsigned m_iChannels;

  std::map<std::string, RageSoundReader*> m_apNamedSounds;
  std::vector<std::unique_ptr<RageSoundReader>> m_apLoadedSounds;
  std::vector<std::pair<std::string, float>> m_aPendingProperties;
  mutable std::string m_sError;

  struct Sound {
    int iIndex;  // into m_apLoadedSounds
    int iOffsetMS;
    float fPan;
    RageSoundReader* pSound;  // nullptr if not activated

    std::int64_t GetOffsetFrame64(int iSampleRate) const {
      if (iSampleRate <= 0) {
        iSampleRate = FALLBACK_SAMPLE_RATE;
      }
      const int64_t frames = int64_t(iOffsetMS) * iSampleRate / 1000;
      return frames;
    }

    int GetOffsetFrame(int iSampleRate) const {
      const int64_t frames = GetOffsetFrame64(iSampleRate);
      if (frames > std::numeric_limits<int>::max()) {
        return std::numeric_limits<int>::max();
      }
      if (frames < std::numeric_limits<int>::min()) {
        return std::numeric_limits<int>::min();
      }
      return static_cast<int>(frames);
    }
    bool operator<(const Sound& rhs) const { return iOffsetMS < rhs.iOffsetMS; }
  };
  std::vector<Sound> m_aSounds;

  /* Read state: */
  std::int64_t m_iCurrentFrame;
  size_t m_iNextSound;
  std::vector<Sound*> m_apActiveSounds;

  bool ActivateSound(Sound* s);
  void ReleaseSound(Sound* s);
};

#endif

/*
 * Copyright (c) 2004-2006 Glenn Maynard
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
