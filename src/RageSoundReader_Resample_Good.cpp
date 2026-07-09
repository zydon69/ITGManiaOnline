/*
 * This implements audio resampling, using the method described at:
 *  http://www.dspguru.com/info/faqs/mrfaq.htm
 *
 * Each conversion ratio uses some memory, but the resulting table is
 * shared, so the memory overhead per stream is negligible.
 */
#include "RageSoundReader_Resample_Good.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <numeric>
#include <string>
#include <utility>
#include <vector>

#include "RageSoundReader.h"
#include "RageSoundReader_Filter.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "global.h"

constexpr int FILTER_LENGTH = 8;  // This must be a power of 2.
constexpr float RATE_DISABLED = -1.0f;
constexpr float MAX_REASONABLE_RATE = 64.0f;
constexpr unsigned MAX_RESAMPLE_CHANNELS = 64;
constexpr float MIN_NORMALIZATION_SUM = 0.0000001f;

namespace {
bool IsFinitePositive(float f) { return std::isfinite(f) && f > 0.0f; }

bool IsUsableSource(const RageSoundReader* pSource, int iSampleRate) {
  return pSource != nullptr && pSource->GetSampleRate() > 0 &&
         pSource->GetNumChannels() > 0 &&
         pSource->GetNumChannels() <= MAX_RESAMPLE_CHANNELS &&
         iSampleRate > 0;
}

int ClampInt64ToInt(int64_t value) {
  if (value > std::numeric_limits<int>::max()) {
    return std::numeric_limits<int>::max();
  }
  if (value < std::numeric_limits<int>::min()) {
    return std::numeric_limits<int>::min();
  }
  return static_cast<int>(value);
}

bool CheckedMultiplyInt(int lhs, int rhs, int& out) {
  if (lhs < 0 || rhs < 0) {
    return false;
  }
  if (rhs != 0 && lhs > std::numeric_limits<int>::max() / rhs) {
    return false;
  }
  out = lhs * rhs;
  return true;
}

float sincf(float f) {
  if (f == 0) {
    return 1;
  }
  return std::sin(f) / f;
}

/* Modified Bessel function I0.  From Abramowitz and Stegun "Handbook of
 * Mathematical Functions", "Modified Bessel Functions I and K". */
float BesselI0(float fX) {
  constexpr float COEFFS1[] = {3.5156229f, 3.0899424f, 1.2067492f,
                               0.2659732f, 0.0360768f, 0.0045813f};
  constexpr float COEFFS2[] = {0.39894228f,  0.01328592f,  0.00225319f,
                               -0.00157565f, 0.00916281f,  -0.02057706f,
                               0.02635537f,  -0.01647633f, 0.00392377f};
  float fAbsX = std::abs(fX);
  if (fAbsX < 3.75f) {
    float y = (fX / 3.75f) * (fX / 3.75f);
    float fRet = 1.0f;
    for (float coeff : COEFFS1) {
      fRet += coeff * y;
      y *= y;
    }
    return fRet;
  } else {
    float y = 3.75f / fAbsX;
    float fRet = std::exp(fAbsX) / std::sqrt(fAbsX);
    for (float coeff : COEFFS2) {
      fRet += coeff * y;
      y *= y;
    }
    return fRet;
  }
}

/*
 * Kaiser window:
 *
 * K(n) = I0( B*sqrt(1-(n/p)^2) )
 *        -----------------------
 *                 I0(B)
 *
 * where B is the beta parameter, p is len/2, and n is in [-len/2,+len/2].
 */
bool ApplyKaiserWindow(float* pBuf, int iLen, float fBeta) {
  if (pBuf == nullptr || iLen <= 0 || !std::isfinite(fBeta)) {
    return false;
  }
  constexpr float VERY_TINY_NUMBER =
      0.0000001f;  // a little safer than comparing against zero
  const float fDenom = BesselI0(fBeta);
  if (!std::isfinite(fDenom) || std::abs(fDenom) < VERY_TINY_NUMBER) {
    return false;
  }
  const float p = (iLen - 1) / 2.0f;
  if (!std::isfinite(p) || p <= 0.0f) {
    return false;
  }
  for (int n = 0; n < iLen; ++n) {
    const float fN1 = std::abs((n - p) * (1.0f / p));
    const float fN1Squared = fN1 * fN1;
    const float fNum = BesselI0(
        fBeta * std::sqrt(std::max(1.0f - fN1Squared, VERY_TINY_NUMBER)));
    if (!std::isfinite(fNum)) {
      return false;
    }
    pBuf[n] *= fNum / fDenom;
    if (!std::isfinite(pBuf[n])) {
      return false;
    }
  }
  return true;
}

void MultiplyVector(float* pStart, float* pEnd, float f) {
  for (; pStart != pEnd; ++pStart) {
    *pStart *= f;
  }
}

bool GenerateSincLowPassFilter(float* pFIR, int iWinSize, float fCutoff) {
  if (pFIR == nullptr || iWinSize <= 0 || !IsFinitePositive(fCutoff) ||
      fCutoff > 0.5f) {
    return false;
  }
  constexpr double TWOPI = 2 * 3.141592653589793;
  const float p = (iWinSize - 1) / 2.0;

  for (int n = 0; n < iWinSize; ++n) {
    const float fN1 = (n - p);
    const float fVal = sincf((TWOPI * fCutoff * fN1)) * (2.0f * fCutoff);
    if (!std::isfinite(fVal)) {
      return false;
    }
    pFIR[n] = fVal;
  }
#if 0
		float *pFIRp = pFIR+iWinSize/2;
		for(int i=-iWinSize/2;i<=iWinSize/2;i++)
		{
			float ff = sinc(2*M_PI*fCutoff * (i + 0.0))*(2*fCutoff);

			printf( "%i: %f\n", i, ff );

			pFIRp[i]=ff;
		}
		for( int i=0; i < iWinSize; i++ )
			printf( "sinc: %i: %f\n", i, pFIR[i] );
#endif
  return true;
}

bool NormalizeVector(float* pBuf, int iSize) {
  if (pBuf == nullptr || iSize <= 0) {
    return false;
  }
  float fTotal = std::accumulate(&pBuf[0], &pBuf[iSize], 0.0f);
  if (!std::isfinite(fTotal) || std::abs(fTotal) < MIN_NORMALIZATION_SUM) {
    return false;
  }
  MultiplyVector(&pBuf[0], &pBuf[iSize], 1 / fTotal);
  for (int i = 0; i < iSize; ++i) {
    if (!std::isfinite(pBuf[i])) {
      return false;
    }
  }
  return true;
}

int GCD(int i1, int i2) { return std::gcd(i1, i2); }
}  // namespace

#if 0
void RunFIRFilter( float *pIn, float *pOut, int iInputValues, float *pFIR, int iWinSize )
{
	for( int i = 0; i < iInputValues; ++i )
	{
		float fSum = 0;
		const float *pInData = &pIn[i];
		for( int j = 0; j < iWinSize; ++j )
		{
			float in = pInData[j];
			fSum += in*pFIR[j];
			printf( "%i: in %f * %f, += %f\n", j, pInData[j], pFIR[j], in*pFIR[j] );
		}

		pOut[i] = fSum;
	}
}
#endif

template <typename T>
class AlignedBuffer {
 public:
  explicit AlignedBuffer(size_t iSize)
      : m_iSize(iSize), m_pBuf(iSize == 0 ? nullptr : new T[iSize]) {}

  AlignedBuffer(const AlignedBuffer& cpy)
      : m_iSize(cpy.m_iSize),
        m_pBuf(m_iSize == 0 ? nullptr : new T[m_iSize]) {
    if (m_iSize != 0) {
      memcpy(m_pBuf.get(), cpy.m_pBuf.get(), sizeof(T) * m_iSize);
    }
  }
  AlignedBuffer& operator=(const AlignedBuffer& rhs) = delete;
  T& operator[](size_t i) { return m_pBuf[i]; }
  const T& operator[](size_t i) const { return m_pBuf[i]; }
  operator T*() { return m_pBuf.get(); }
  operator const T*() const { return m_pBuf.get(); }

 private:
  size_t m_iSize;
  std::unique_ptr<T[]> m_pBuf;
};

struct PolyphaseFilter {
  struct State {
    State(int iUpFactor) : m_fBuf(FILTER_LENGTH * 2) {
      m_iPolyIndex = iUpFactor - 1;
      m_iFilled = 0;
      m_iBufNext = 0;
    }

    int m_iPolyIndex;
    int m_iFilled;

    /* This buffer is duplicated.  If the circular buffer is size L, the actual
     * buffer is size L*2, and data at buf[N] is also at buf[N+L].  That way, we
     * can access up to buf[N*2-1] without having to wrap. */
    AlignedBuffer<float> m_fBuf;
    int m_iBufNext;
  };
  friend struct State;

  PolyphaseFilter(int iUpFactor) : m_pPolyphase(FILTER_LENGTH * iUpFactor) {
    m_iUpFactor = iUpFactor;
  }

  void Generate(const float* pFIR);
  int RunPolyphaseFilter(
      State& State, const float* pIn, int iSamplesIn, int iDownFactor,
      float* pOut, int iSamplesOut, int iSampleStride) const;
  int GetLatency() const { return FILTER_LENGTH / 2; }

  int NumInputsForOutputSamples(
      const State& State, int iOut, int iDownFactor) const;

 private:
  AlignedBuffer<float> m_pPolyphase;
  int m_iUpFactor;
};

/*
 * Convert an FIR filter to a polyphase filter.
 *
 * pFIR is the input FIR filter, which has iL*iUpFactor values.
 * iL is the number of real samples each output sample looks at.
 * iUpFactor is the actual upsampling factor; the amount of zero-stuffing
 * between each real sample. pOutput is the 2D output polyphase filter, with
 * iL*iL values.
 *
 * With an upsampling factor (iUpFactor) of 3, and a sinc filter length of 12
 * (iL*iUpFactor),
 *
 * input     first output sample (before decimation)
 * sample          second output sample
 *                     third output sample
 *
 * 0         0
 * 0         1     0
 * 1592      2     1   0
 * 0         3     2   1
 * 0         4     3   2
 * 1623      5     4   3
 * 0         6     5   4
 * 0         7     6   5
 * 1682      8     7   6
 * 0         9     8   7
 * 0         10    9   8
 * 1730      11    10  9
 * 0               11  10
 * 0                   11
 *
 * first row: 2, 5, 8, 11
 * second: 1, 4, 7, 10
 * third: 0, 3, 6, 9
 * Read a new sample after passing the last line.
 */
void PolyphaseFilter::Generate(const float* pFIR) {
  float* pOutput = m_pPolyphase;
  const int iInputSize = FILTER_LENGTH * m_iUpFactor;

  for (int iRow = 0; iRow < m_iUpFactor; ++iRow) {
    int iInputOffset = (m_iUpFactor - iRow - 1) % m_iUpFactor;
    for (int iCol = 0; iCol < FILTER_LENGTH; ++iCol) {
      *pOutput = pFIR[iInputOffset];
      ++pOutput;
      iInputOffset += m_iUpFactor;
      iInputOffset %= iInputSize;
    }
  }
}

/*
 * We only want one boundary check when running the filter; either on the
 * number of inputs used, or the number of outputs produced.  Otherwise, we'll
 * have to maintain two counters, and check two values per iteration.
 *
 * First, call NumInputsForOutputSamples(out), to find out how many inputs to
 * supply to get the desired number of outputs.  Then, pass the data, the input
 * count and the output count to RunPolyphaseFilter.
 *
 * - When downsampling, we use the number of inputs as the boundary.  For
 * example, if the ratio is 1:3 (downsample x3), and the user gives us 10
 * samples, then we process until we've consumed all of the input.  (This will
 * result in exactly the number of samples the user asked for with
 * NumInputsForOutputSamples.)
 *
 * - When upsampling, we use the number of outputs as the boundary.  For
 * example, if the ratio is 3:1 (upsample x3), and the user wants 8 samples to
 * be output, we'll have been given 3 samples as input.  Process until we've
 * produced 8 samples.
 *
 * In both cases, we have overlap.  In the first, it's possible that we could
 * have consumed an additional input without producing an output.  In the
 * second, it's possible that we could have produced an additional output
 * without consuming an input.
 */
int PolyphaseFilter::RunPolyphaseFilter(
    State& State, const float* pIn, int iSamplesIn, int iDownFactor,
    float* pOut, int iSamplesOut, int iSampleStride) const {
  if (pIn == nullptr || pOut == nullptr || iSamplesIn < 0 ||
      iSamplesOut < 0 || iSampleStride <= 0 || iDownFactor <= 0 ||
      m_iUpFactor <= 0) {
    return RageSoundReader::ERROR;
  }
  if ((iSamplesIn != 0 &&
       iSampleStride > std::numeric_limits<int>::max() / iSamplesIn) ||
      (iSamplesOut != 0 &&
       iSampleStride > std::numeric_limits<int>::max() / iSamplesOut)) {
    return RageSoundReader::ERROR;
  }

  float* pOutOrig = pOut;
  const ptrdiff_t iInOffset =
      static_cast<ptrdiff_t>(iSamplesIn) * static_cast<ptrdiff_t>(iSampleStride);
  const ptrdiff_t iOutOffset =
      static_cast<ptrdiff_t>(iSamplesOut) *
      static_cast<ptrdiff_t>(iSampleStride);
  const float* pInEnd = pIn + iInOffset;
  const float* pOutEnd = pOut + iOutOffset;

  int iFilled = State.m_iFilled;
  int iPolyIndex = State.m_iPolyIndex;
  while (pOut != pOutEnd) {
    if (iFilled < FILTER_LENGTH) {
      if (pIn == pInEnd) {
        break;
      }

      State.m_fBuf[State.m_iBufNext] = *pIn;
      State.m_fBuf[State.m_iBufNext + FILTER_LENGTH] = *pIn;
      ++State.m_iBufNext;
      State.m_iBufNext &= FILTER_LENGTH - 1;

      pIn += iSampleStride;
      ++iFilled;
      continue;
    }

    while (pOut != pOutEnd) {
      const float* pCurPoly = &m_pPolyphase[iPolyIndex * FILTER_LENGTH];
      const float* pInData = &State.m_fBuf[State.m_iBufNext];

      float fTot = 0;
      for (int j = 0; j < FILTER_LENGTH; ++j) {
        fTot += pInData[j] * pCurPoly[j];
      }
      *pOut = fTot;
      pOut += iSampleStride;

      iPolyIndex += iDownFactor;
      if (iPolyIndex >= m_iUpFactor) {
        break;
      }
    }
    iFilled -= iPolyIndex / m_iUpFactor;
    iPolyIndex %= m_iUpFactor;
  }

  State.m_iFilled = iFilled;
  State.m_iPolyIndex = iPolyIndex;

  const ptrdiff_t iRetSamples = pOut - pOutOrig;
  const ptrdiff_t iRetFrames = iRetSamples / iSampleStride;
  if (iRetFrames > std::numeric_limits<int>::max()) {
    return RageSoundReader::ERROR;
  }
  return static_cast<int>(iRetFrames);
}

/*
 * Return the number of input samples needed to produce the given number of
 * output samples.  This is dependent on the number of bytes in the buffer and
 * the current position of the stream.
 */
int PolyphaseFilter::NumInputsForOutputSamples(
    const State& State, int iOut, int iDownFactor) const {
  if (iOut < 0 || iDownFactor <= 0 || m_iUpFactor <= 0) {
    return RageSoundReader::ERROR;
  }
  int64_t iIn = 0;
  int64_t iFilled = State.m_iFilled;
  int64_t iPolyIndex = State.m_iPolyIndex;

#if 0
	while( iOut > 0 )
	{
		if( iFilled < FILTER_LENGTH )
		{
			int iToFill = FILTER_LENGTH-iFilled;
			iIn += iToFill;
			iFilled += iToFill;
		}

		while( iFilled == FILTER_LENGTH && iOut )
		{
			--iOut;
			iPolyIndex += iDownFactor;

			if( iPolyIndex >= m_iUpFactor )
				break;
		}
		iFilled -= iPolyIndex/m_iUpFactor;
		iPolyIndex %= m_iUpFactor;
	}
#endif

  if (iOut > 0) {
    if (iFilled < FILTER_LENGTH) {
      int64_t iToFill = FILTER_LENGTH - iFilled;
      iIn += iToFill;
    }

    // The -1 here is because we don't refill m_fBuf after writing the last
    // output.
    iPolyIndex +=
        static_cast<int64_t>(iDownFactor) * static_cast<int64_t>(iOut - 1);
    iIn += iPolyIndex / m_iUpFactor;
  }

  if (iIn > std::numeric_limits<int>::max()) {
    return RageSoundReader::ERROR;
  }
  return static_cast<int>(iIn);
}
/** @brief Utilities for working with the PolyphaseFilter cache. */
namespace PolyphaseFilterCache {
/* Cache filter data, and reuse it without copying.  All operations after
 * creation are const, so this doesn't cause thread-safety problems. */
typedef std::map<std::pair<int, float>, PolyphaseFilter*> FilterMap;
static RageMutex PolyphaseFiltersLock("PolyphaseFiltersLock");
static FilterMap g_mapPolyphaseFilters;

const PolyphaseFilter* MakePolyphaseFilter(
    int iUpFactor, float fCutoffFrequency) {
  if (iUpFactor <= 0 || iUpFactor > std::numeric_limits<int>::max() /
                                          FILTER_LENGTH ||
      !IsFinitePositive(fCutoffFrequency) || fCutoffFrequency > 0.5f) {
    return nullptr;
  }

  const std::pair<int, float> params(
      std::make_pair(iUpFactor, fCutoffFrequency));
  {
    LockMutex lock(PolyphaseFiltersLock);
    FilterMap::const_iterator it = g_mapPolyphaseFilters.find(params);
    if (it != g_mapPolyphaseFilters.end()) {
      /* We already have a filter for this upsampling factor and cutoff; use it.
       */
      return it->second;
    }
  }

  std::unique_ptr<float[]> pFIR;
  std::unique_ptr<PolyphaseFilter> pPolyphase;
  try {
    int iWinSize = 0;
    if (!CheckedMultiplyInt(FILTER_LENGTH, iUpFactor, iWinSize) ||
        iWinSize <= 0) {
      return nullptr;
    }
    pFIR.reset(new float[iWinSize]);
    if (!GenerateSincLowPassFilter(pFIR.get(), iWinSize, fCutoffFrequency) ||
        !ApplyKaiserWindow(pFIR.get(), iWinSize, 8) ||
        !NormalizeVector(pFIR.get(), iWinSize)) {
      return nullptr;
    }
    MultiplyVector(&pFIR[0], &pFIR[iWinSize], (float)iUpFactor);
    for (int i = 0; i < iWinSize; ++i) {
      if (!std::isfinite(pFIR[i])) {
        return nullptr;
      }
    }

    pPolyphase.reset(new PolyphaseFilter(iUpFactor));
    pPolyphase->Generate(pFIR.get());
  } catch (const std::bad_alloc&) {
    return nullptr;
  }

  LockMutex lock(PolyphaseFiltersLock);
  FilterMap::const_iterator it = g_mapPolyphaseFilters.find(params);
  if (it != g_mapPolyphaseFilters.end()) {
    return it->second;
  }
  PolyphaseFilter* pRaw = pPolyphase.get();
  try {
    std::pair<FilterMap::iterator, bool> inserted =
        g_mapPolyphaseFilters.insert(std::make_pair(params, pRaw));
    if (!inserted.second) {
      return inserted.first->second;
    }
  } catch (const std::bad_alloc&) {
    return nullptr;
  }
  pPolyphase.release();
  return pRaw;
}

const PolyphaseFilter* FindNearestPolyphaseFilter(
    int iUpFactor, float fCutoffFrequency) {
  if (iUpFactor <= 0 || !std::isfinite(fCutoffFrequency)) {
    return nullptr;
  }
  /* Find a cached filter with the same iUpFactor and a nearby cutoff frequency.
   * Round the cutoff down, if possible; it's better to filter out too much than
   * too little. */
  LockMutex lock(PolyphaseFiltersLock);
  std::pair<int, float> params(
      std::make_pair(iUpFactor, fCutoffFrequency + 0.0001f));
  FilterMap::const_iterator it = g_mapPolyphaseFilters.upper_bound(params);
  if (g_mapPolyphaseFilters.empty()) {
    return nullptr;
  }
  if (it != g_mapPolyphaseFilters.begin()) {
    --it;
  }
  if (it == g_mapPolyphaseFilters.end() || it->first.first != iUpFactor) {
    return nullptr;
  }
  PolyphaseFilter* pPolyphase = it->second;
  return pPolyphase;
}
}  // namespace PolyphaseFilterCache

/*
 * Interface to PolyphaseFilter, providing a simple resampling interface.  This
 * handles reuse of PolyphaseFilters.  This does not handle delay, flushing, or
 * multiple channels.
 */
class RageSoundResampler_Polyphase {
 public:
  /* Note that going outside of [iMinDownFactor,iMaxDownFactor] while resampling
   * isn't fatal.  It'll only cause aliasing, by not having a LPF that's low
   * enough, or cause too much filtering, by not having a LPF that's high
   * enough. */
  RageSoundResampler_Polyphase(
      int iUpFactor, int iMinDownFactor, int iMaxDownFactor) {
    /* Cache filters between iMinDownFactor and iMaxDownFactor.  Do them in
     * iFilterIncrement increments; we'll round down to the closest match
     * when filtering.  This will only cause the low-pass filter to be rounded;
     * the conversion ratio will always be exact. */
    m_iUpFactor = iUpFactor;
    m_pPolyphase = nullptr;
    m_pState.reset();
    m_iDownFactor = 1;
    if (iUpFactor <= 0 || iMinDownFactor <= 0 || iMaxDownFactor <= 0 ||
        iMinDownFactor > iMaxDownFactor) {
      return;
    }

    int iFilterIncrement = std::max((iMaxDownFactor - iMinDownFactor) / 10, 1);
    for (int iDownFactor = iMinDownFactor;;) {
      float fCutoffFrequency = GetCutoffFrequency(iDownFactor);
      if (PolyphaseFilterCache::MakePolyphaseFilter(
              m_iUpFactor, fCutoffFrequency) == nullptr) {
        return;
      }
      if (iMaxDownFactor - iDownFactor <= iFilterIncrement) {
        break;
      }
      iDownFactor += iFilterIncrement;
    }

    if (!SetDownFactor(iUpFactor)) {
      return;
    }

    try {
      m_pState.reset(new PolyphaseFilter::State(iUpFactor));
    } catch (const std::bad_alloc&) {
      m_pPolyphase = nullptr;
    }
  }

  ~RageSoundResampler_Polyphase() = default;

  bool SetDownFactor(int iDownFactor) {
    if (iDownFactor <= 0) {
      return false;
    }
    const PolyphaseFilter* pFilter = GetFilter(iDownFactor);
    if (pFilter == nullptr) {
      return false;
    }
    m_iDownFactor = iDownFactor;
    m_pPolyphase = pFilter;
    return true;
  }

  int Run(
      const float* pIn, int iSamplesIn, float* pOut, int iSamplesOut,
      int iSampleStride) const {
    if (m_pPolyphase == nullptr || m_pState == nullptr || pIn == nullptr ||
        pOut == nullptr || iSamplesIn < 0 || iSamplesOut < 0 ||
        iSampleStride <= 0 || m_iDownFactor <= 0) {
      return RageSoundReader::ERROR;
    }
    return m_pPolyphase->RunPolyphaseFilter(
        *m_pState, pIn, iSamplesIn, m_iDownFactor, pOut, iSamplesOut,
        iSampleStride);
  }

  bool Reset() {
    if (m_iUpFactor <= 0) {
      m_pState.reset();
      return false;
    }
    try {
      std::unique_ptr<PolyphaseFilter::State> pNewState(
          new PolyphaseFilter::State(m_iUpFactor));
      m_pState.swap(pNewState);
    } catch (const std::bad_alloc&) {
      return false;
    }
    return true;
  }

  int NumInputsForOutputSamples(int iOut) const {
    if (m_pPolyphase == nullptr || m_pState == nullptr || iOut < 0 ||
        m_iDownFactor <= 0) {
      return RageSoundReader::ERROR;
    }
    return m_pPolyphase->NumInputsForOutputSamples(
        *m_pState, iOut, m_iDownFactor);
  }
  int GetLatency() const {
    return m_pPolyphase == nullptr ? 0 : m_pPolyphase->GetLatency();
  }
  int GetFilled() const { return m_pState == nullptr ? 0 : m_pState->m_iFilled; }
  bool IsUsable() const {
    return m_pPolyphase != nullptr && m_pState != nullptr &&
           m_iUpFactor > 0 && m_iDownFactor > 0;
  }

  RageSoundResampler_Polyphase(const RageSoundResampler_Polyphase& cpy) {
    m_pPolyphase = cpy.m_pPolyphase;  // don't copy
    if (cpy.m_pState != nullptr) {
      m_pState.reset(new PolyphaseFilter::State(*cpy.m_pState));
    }
    m_iUpFactor = cpy.m_iUpFactor;
    m_iDownFactor = cpy.m_iDownFactor;
  }
  RageSoundResampler_Polyphase& operator=(
      const RageSoundResampler_Polyphase& rhs) = delete;

 private:
  float GetCutoffFrequency(int iDownFactor) const {
    /*
     * If we're upsampling, we want the low-pass filter to cut off at the
     * nyquist frequency of the original sample.
     *
     * If we're downsampling, we want the low-pass filter to cut off at the
     * nyquist frequency of the new sample.
     */

    float fCutoffFrequency;
    fCutoffFrequency = 1.0f / (2 * m_iUpFactor);
    fCutoffFrequency = std::min(fCutoffFrequency, 1.0f / (2 * iDownFactor));
    return fCutoffFrequency;
  }

  const PolyphaseFilter* GetFilter(int iDownFactor) const {
    float fCutoffFrequency = GetCutoffFrequency(iDownFactor);
    return PolyphaseFilterCache::FindNearestPolyphaseFilter(
        m_iUpFactor, fCutoffFrequency);
  }

  const PolyphaseFilter* m_pPolyphase;
  std::unique_ptr<PolyphaseFilter::State> m_pState;
  int m_iUpFactor;
  int m_iDownFactor;
};

int RageSoundReader_Resample_Good::GetNextSourceFrame() const {
  std::lock_guard<std::mutex> lock(m_StateMutex);
  if (!IsUsableLocked()) {
    return 0;
  }
  int64_t iPosition = m_pSource->GetNextSourceFrame();
  iPosition -= m_apResamplers[0]->GetFilled();

  const int iSourceSampleRate = m_pSource->GetSampleRate();
  if (iSourceSampleRate <= 0 ||
      (iPosition > 0 &&
       iPosition >
           std::numeric_limits<int64_t>::max() / m_iSampleRate) ||
      (iPosition < 0 &&
       iPosition <
           std::numeric_limits<int64_t>::min() / m_iSampleRate)) {
    return 0;
  }
  iPosition *= m_iSampleRate;
  iPosition /= iSourceSampleRate;
  return ClampInt64ToInt(iPosition);
}

bool RageSoundReader_Resample_Good::SetProperty(
    const std::string& sProperty, float fValue) {
  if (sProperty == "Rate") {
    return SetRate(fValue);
  }

  std::lock_guard<std::mutex> lock(m_StateMutex);
  return m_pSource.isNull() ? false : m_pSource->SetProperty(sProperty, fValue);
}

float RageSoundReader_Resample_Good::GetStreamToSourceRatio() const {
  std::lock_guard<std::mutex> lock(m_StateMutex);
  if (m_pSource.isNull()) {
    return 1.0f;
  }
  float fRatio = m_pSource->GetStreamToSourceRatio();
  if (m_fRate != RATE_DISABLED) {
    fRatio *= m_fRate;
  }
  return std::isfinite(fRatio) && fRatio > 0.0f ? fRatio : 1.0f;
}

RageSoundReader_Resample_Good::RageSoundReader_Resample_Good(
    RageSoundReader* pSource, int iSampleRate)
    : RageSoundReader_Filter(pSource), m_iSampleRate(0), m_fRate(RATE_DISABLED) {
  m_iSampleRate = iSampleRate > 0 ? iSampleRate : 0;
  if (!IsUsableSource(pSource, m_iSampleRate)) {
    SetError(
        "SRC_AUDIT_FIX SRC-2837: Resample_Good received an invalid source "
        "reader or sample rate");
    return;
  }
  float fActualRate = RATE_DISABLED;
  if (!ReopenResamplerLocked(RATE_DISABLED, &fActualRate)) {
    SetError(
        "SRC_AUDIT_FIX SRC-2834: Resample_Good could not build its initial "
        "resampler topology");
  }
}

void RageSoundReader_Resample_Good::ClearResamplers() {
  for (size_t iChannel = 0; iChannel < m_apResamplers.size(); ++iChannel) {
    delete m_apResamplers[iChannel];
  }
  m_apResamplers.clear();
}

RageSoundReader_Resample_Good::~RageSoundReader_Resample_Good() {
  ClearResamplers();
}

bool RageSoundReader_Resample_Good::IsUsableLocked() const {
  if (!IsUsableSource(m_pSource.isNull() ? nullptr : &*m_pSource,
                      m_iSampleRate)) {
    return false;
  }
  if (m_apResamplers.size() != m_pSource->GetNumChannels() ||
      m_apResamplers.empty()) {
    return false;
  }
  for (size_t i = 0; i < m_apResamplers.size(); ++i) {
    if (m_apResamplers[i] == nullptr || !m_apResamplers[i]->IsUsable()) {
      return false;
    }
  }
  return true;
}

bool RageSoundReader_Resample_Good::ResetLocked() {
  if (m_pSource.isNull()) {
    SetError("SRC_AUDIT_FIX SRC-2837: Resample_Good reset has no source");
    return false;
  }
  for (size_t iChannel = 0; iChannel < m_pSource->GetNumChannels() &&
                              iChannel < m_apResamplers.size();
       ++iChannel) {
    if (m_apResamplers[iChannel] == nullptr ||
        !m_apResamplers[iChannel]->Reset()) {
      SetError(
          "SRC_AUDIT_FIX SRC-2833: Resample_Good could not reset resampler "
          "state");
      return false;
    }
  }
  ClearError();
  return true;
}

bool RageSoundReader_Resample_Good::GetFactorsLocked(
    float fRate, int& iDownFactor, int& iUpFactor,
    int& iAppliedDownFactor) const {
  iDownFactor = m_pSource.isNull() ? 0 : m_pSource->GetSampleRate();
  iUpFactor = m_iSampleRate;
  iAppliedDownFactor = iDownFactor;
  if (iDownFactor <= 0 || iUpFactor <= 0) {
    return false;
  }

  const int iGCD = GCD(iUpFactor, iDownFactor);
  if (iGCD <= 0) {
    return false;
  }
  iUpFactor /= iGCD;
  iDownFactor /= iGCD;
  iAppliedDownFactor = iDownFactor;

  if (fRate != RATE_DISABLED) {
    if (!IsFinitePositive(fRate) || fRate > MAX_REASONABLE_RATE ||
        iUpFactor > std::numeric_limits<int>::max() / 100 ||
        iDownFactor > std::numeric_limits<int>::max() / 100) {
      return false;
    }
    iUpFactor *= 100;
    iDownFactor *= 100;
    const double fAppliedDownFactor =
        static_cast<double>(fRate) * static_cast<double>(iDownFactor);
    if (!std::isfinite(fAppliedDownFactor) || fAppliedDownFactor <= 0.0 ||
        fAppliedDownFactor >
            static_cast<double>(std::numeric_limits<int>::max())) {
      return false;
    }
    iAppliedDownFactor =
        static_cast<int>(std::floor(fAppliedDownFactor + 0.5));
    if (iAppliedDownFactor <= 0) {
      return false;
    }
  }
  return true;
}

bool RageSoundReader_Resample_Good::ReopenResamplerLocked(
    float fRate, float* fActualRate) {
  if (fActualRate != nullptr) {
    *fActualRate = fRate;
  }
  if (!IsUsableSource(m_pSource.isNull() ? nullptr : &*m_pSource,
                      m_iSampleRate)) {
    SetError(
        "SRC_AUDIT_FIX SRC-2834: Resample_Good refused invalid source "
        "topology");
    return false;
  }

  int iDownFactor = 0;
  int iUpFactor = 0;
  int iAppliedDownFactor = 0;
  if (!GetFactorsLocked(fRate, iDownFactor, iUpFactor, iAppliedDownFactor)) {
    SetError("SRC_AUDIT_FIX SRC-2838: Resample_Good rejected rate factors");
    return false;
  }

  std::vector<std::unique_ptr<RageSoundResampler_Polyphase>> apNewResamplers;
  try {
    apNewResamplers.reserve(m_pSource->GetNumChannels());
    for (size_t iChannel = 0; iChannel < m_pSource->GetNumChannels();
         ++iChannel) {
      int iMinDownFactor = iDownFactor;
      int iMaxDownFactor = std::max(iDownFactor, iAppliedDownFactor);
      if (fRate != RATE_DISABLED) {
        if (iMaxDownFactor > std::numeric_limits<int>::max() / 5) {
          SetError(
              "SRC_AUDIT_FIX SRC-2838: Resample_Good rejected huge filter "
              "factor");
          return false;
        }
        iMaxDownFactor = std::max(iMaxDownFactor, iDownFactor * 5);
      }

      std::unique_ptr<RageSoundResampler_Polyphase> p(
          new RageSoundResampler_Polyphase(
              iUpFactor, iMinDownFactor, iMaxDownFactor));
      if (!p->IsUsable() || !p->SetDownFactor(iAppliedDownFactor)) {
        SetError(
            "SRC_AUDIT_FIX SRC-2834: Resample_Good could not build a usable "
            "channel resampler");
        return false;
      }
      apNewResamplers.push_back(std::move(p));
    }
  } catch (const std::bad_alloc&) {
    SetError(
        "SRC_AUDIT_FIX SRC-2834: Resample_Good ran out of memory rebuilding "
        "resamplers");
    return false;
  }

  std::vector<RageSoundResampler_Polyphase*> apRawResamplers;
  try {
    apRawResamplers.reserve(apNewResamplers.size());
    for (size_t i = 0; i < apNewResamplers.size(); ++i) {
      apRawResamplers.push_back(apNewResamplers[i].get());
    }
  } catch (const std::bad_alloc&) {
    SetError(
        "SRC_AUDIT_FIX SRC-2834: Resample_Good ran out of memory publishing "
        "resamplers");
    return false;
  }

  ClearResamplers();
  m_apResamplers.swap(apRawResamplers);
  for (size_t i = 0; i < apNewResamplers.size(); ++i) {
    apNewResamplers[i].release();
  }
  if (fActualRate != nullptr && fRate != RATE_DISABLED) {
    *fActualRate = static_cast<float>(iAppliedDownFactor) /
                   static_cast<float>(iUpFactor);
  }
  ClearError();
  return true;
}

/* iFrame is in the destination rate.  Seek the source in its own sample rate.
 */
int RageSoundReader_Resample_Good::SetPosition(int iFrame) {
  std::lock_guard<std::mutex> lock(m_StateMutex);
  if (m_pSource.isNull() || m_iSampleRate <= 0 ||
      m_pSource->GetSampleRate() <= 0) {
    SetError(
        "SRC_AUDIT_FIX SRC-2837: Resample_Good rejected SetPosition topology");
    return RageSoundReader::ERROR;
  }
  if (!ResetLocked()) {
    SetError(
        "SRC_AUDIT_FIX SRC-2837: Resample_Good could not reset before "
        "SetPosition");
    return RageSoundReader::ERROR;
  }
  /* Negative positions are valid during gameplay lead-in.  The wrapped reader
   * decides whether to clamp to zero or synthesize silence before the song. */
  const int64_t iSourceFrame =
      static_cast<int64_t>(iFrame) *
      static_cast<int64_t>(m_pSource->GetSampleRate()) / m_iSampleRate;
  return m_pSource->SetPosition(ClampInt64ToInt(iSourceFrame));
}

int RageSoundReader_Resample_Good::Read(float* pBuf, int iFrames) {
  if (iFrames == 0) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(m_StateMutex);
  if (pBuf == nullptr) {
    SetError(
        "SRC_AUDIT_FIX SRC-2837: Resample_Good Read called with null buffer");
    return RageSoundReader::ERROR;
  }
  if (iFrames < 0) {
    SetError(
        "SRC_AUDIT_FIX SRC-2837: Resample_Good Read called with negative frame "
        "count");
    return RageSoundReader::ERROR;
  }
  if (!IsUsableLocked()) {
    SetError(
        "SRC_AUDIT_FIX SRC-2837: Resample_Good Read has no usable topology");
    return RageSoundReader::ERROR;
  }
  const int iChannels = static_cast<int>(m_apResamplers.size());

  int iFramesRead = 0;

  /* If the ratio is 1:1, then we're effectively disabled, and we can read
   * directly into the buffer. */
  int iDownFactor = 0;
  int iUpFactor = 0;
  int iAppliedDownFactor = 0;
  if (!GetFactorsLocked(m_fRate, iDownFactor, iUpFactor, iAppliedDownFactor)) {
    SetError("SRC_AUDIT_FIX SRC-2838: Resample_Good has invalid rate factors");
    return RageSoundReader::ERROR;
  }

  const float fCurrentRate = m_fRate == RATE_DISABLED ? 1.0f : m_fRate;
  if (m_apResamplers[0]->GetFilled() == 0 &&
      iAppliedDownFactor == iUpFactor && fCurrentRate == 1.0f) {
    ClearError();
    return m_pSource->Read(pBuf, iFrames);
  }

  int iFramesNeeded = m_apResamplers[0]->NumInputsForOutputSamples(iFrames);
  if (iFramesNeeded < 0 ||
      static_cast<size_t>(iFramesNeeded) >
          std::numeric_limits<size_t>::max() /
              static_cast<size_t>(iChannels)) {
    SetError(
        "SRC_AUDIT_FIX SRC-2838: Resample_Good input frame request overflow");
    return RageSoundReader::ERROR;
  }
  if (iFramesNeeded == 0) {
    return 0;
  }

  std::vector<float> tmpBuf;
  try {
    tmpBuf.resize(
        static_cast<size_t>(iFramesNeeded) * static_cast<size_t>(iChannels));
  } catch (const std::bad_alloc&) {
    SetError(
        "SRC_AUDIT_FIX SRC-2837: Resample_Good could not allocate read buffer");
    return RageSoundReader::ERROR;
  }

  int iFramesIn = m_pSource->Read(&tmpBuf[0], iFramesNeeded);
  if (iFramesIn < 0) {
    return iFramesIn;
  }
  if (iFramesIn > iFramesNeeded) {
    SetError(
        "SRC_AUDIT_FIX SRC-2837: Resample_Good source returned too many "
        "frames");
    return RageSoundReader::ERROR;
  }

  for (int iChannel = 0; iChannel < iChannels; ++iChannel) {
    int iGotFrames = m_apResamplers[iChannel]->Run(
        &tmpBuf[0] + iChannel, iFramesIn, pBuf + iChannel, iFrames, iChannels);
    if (iGotFrames < 0 || iGotFrames > iFrames) {
      SetError("SRC_AUDIT_FIX SRC-2837: Resample_Good channel run failed");
      return RageSoundReader::ERROR;
    }

    if (iChannel == 0) {
      iFramesRead += iGotFrames;
    }
  }

  ClearError();
  return iFramesRead;
}

/*
 * A resampler is commonly used for two things: to change the sample rate of
 * audio, in order to give an audio driver what it wants (SetSampleRate), and to
 * change the sound of audio, changing its speed and pitch (SetRate).  These are
 * the same operation, and we do both in the same pass; the only difference is
 * that SetSampleRate causes GetSampleRate() to change, while SetRate() causes
 * GetStreamToSourceRatio() to change.
 *
 * Changing these values will take effect immediately, with a buffering latency
 * of L/4 frames.
 */
bool RageSoundReader_Resample_Good::SetRate(float fRatio) {
  std::lock_guard<std::mutex> lock(m_StateMutex);
  if (!IsFinitePositive(fRatio) || fRatio > MAX_REASONABLE_RATE) {
    SetError("SRC_AUDIT_FIX SRC-2835: Resample_Good rejected unsafe rate");
    return false;
  }
  if (!IsUsableLocked()) {
    SetError(
        "SRC_AUDIT_FIX SRC-2835: Resample_Good refused rate change without a "
        "usable topology");
    return false;
  }

  float fActualRate = fRatio;
  if (!ReopenResamplerLocked(fRatio, &fActualRate) ||
      !IsFinitePositive(fActualRate)) {
    SetError("SRC_AUDIT_FIX SRC-2835: Resample_Good failed to apply rate");
    return false;
  }

  m_fRate = fActualRate;
  ClearError();
  return true;
}

float RageSoundReader_Resample_Good::GetRate() const {
  std::lock_guard<std::mutex> lock(m_StateMutex);
  if (m_fRate == RATE_DISABLED) {
    return 1.0f;
  } else {
    return m_fRate;
  }
}

RageSoundReader_Resample_Good::RageSoundReader_Resample_Good(
    const RageSoundReader_Resample_Good& cpy)
    : RageSoundReader_Filter(cpy), m_iSampleRate(0), m_fRate(RATE_DISABLED) {
  std::lock_guard<std::mutex> lock(cpy.m_StateMutex);
  this->m_iSampleRate = cpy.m_iSampleRate;
  this->m_fRate = cpy.m_fRate;

  std::vector<std::unique_ptr<RageSoundResampler_Polyphase>> apNewResamplers;
  try {
    apNewResamplers.reserve(cpy.m_apResamplers.size());
    for (size_t i = 0; i < cpy.m_apResamplers.size(); ++i) {
      if (cpy.m_apResamplers[i] == nullptr) {
        SetError(
            "SRC_AUDIT_FIX SRC-2840: Resample_Good copy found null channel "
            "resampler");
        return;
      }
      std::unique_ptr<RageSoundResampler_Polyphase> p(
          new RageSoundResampler_Polyphase(*cpy.m_apResamplers[i]));
      if (!p->IsUsable()) {
        SetError(
            "SRC_AUDIT_FIX SRC-2840: Resample_Good copy produced unusable "
            "channel resampler");
        return;
      }
      apNewResamplers.push_back(std::move(p));
    }
    m_apResamplers.reserve(apNewResamplers.size());
    for (size_t i = 0; i < apNewResamplers.size(); ++i) {
      m_apResamplers.push_back(apNewResamplers[i].get());
    }
  } catch (const std::bad_alloc&) {
    ClearResamplers();
    SetError("SRC_AUDIT_FIX SRC-2840: Resample_Good copy ran out of memory");
    return;
  }

  for (size_t i = 0; i < apNewResamplers.size(); ++i) {
    apNewResamplers[i].release();
  }
}

RageSoundReader_Resample_Good* RageSoundReader_Resample_Good::Copy() const {
  try {
    std::unique_ptr<RageSoundReader_Resample_Good> pCopy(
        new RageSoundReader_Resample_Good(*this));
    {
      std::lock_guard<std::mutex> lock(pCopy->m_StateMutex);
      if (!pCopy->IsUsableLocked()) {
        return nullptr;
      }
    }
    return pCopy.release();
  } catch (const std::bad_alloc&) {
    return nullptr;
  }
}

std::string RageSoundReader_Resample_Good::GetError() const {
  {
    std::lock_guard<std::mutex> lock(m_ErrorMutex);
    if (!m_sError.empty()) {
      return m_sError;
    }
  }
  return RageSoundReader_Filter::GetError();
}

void RageSoundReader_Resample_Good::ClearError() const {
  std::lock_guard<std::mutex> lock(m_ErrorMutex);
  m_sError.clear();
}

void RageSoundReader_Resample_Good::SetError(const std::string& sError) const {
  std::lock_guard<std::mutex> lock(m_ErrorMutex);
  m_sError = sError;
}

/*
 * (c) 2006 Glenn Maynard
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
