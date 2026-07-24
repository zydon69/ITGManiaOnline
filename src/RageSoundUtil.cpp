#include "RageSoundUtil.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

#include "PerfDiagnostics.h"
#include "RageUtil.h"

namespace {
void TraceInvalid(
    const char* finding, const char* operation, const char* reason) {
  LogRuntimeValidationDiagnostics(
      "%s RageSoundUtil::%s refused invalid input: %s",
      finding, operation, reason);
}

void TraceSanitizedSamples(
    const char* finding, const char* operation, size_t count) {
  if (count == 0) {
    return;
  }
  LogRuntimeValidationDiagnostics(
      "%s RageSoundUtil::%s sanitized %zu non-finite samples",
      finding, operation, count);
}

float SanitizeControl(
    float value, const char* finding, const char* operation,
    const char* name) {
  if (std::isfinite(value)) {
    return value;
  }
  LogRuntimeValidationDiagnostics(
      "%s RageSoundUtil::%s replaced non-finite %s with 0",
      finding, operation, name);
  return 0.0f;
}

float SanitizeSample(float sample, size_t& sanitized) {
  if (std::isfinite(sample)) {
    return sample;
  }
  ++sanitized;
  return 0.0f;
}

bool CheckedMul(size_t lhs, size_t rhs, size_t& out) {
  if (lhs != 0 && rhs > std::numeric_limits<size_t>::max() / lhs) {
    return false;
  }
  out = lhs * rhs;
  return true;
}
}  // namespace

bool RageSoundUtil::Attenuate(float* pBuf, size_t iSamples, float fVolume) {
  if (iSamples == 0) {
    return true;
  }
  if (pBuf == nullptr) {
    TraceInvalid("RageSoundUtil", "Attenuate", "null buffer");
    return false;
  }

  fVolume = SanitizeControl(fVolume, "RageSoundUtil", "Attenuate", "volume");
  size_t sanitized = 0;
  for (size_t i = 0; i < iSamples; ++i) {
    pBuf[i] = SanitizeSample(pBuf[i], sanitized) * fVolume;
  }
  TraceSanitizedSamples("RageSoundUtil", "Attenuate", sanitized);
  return true;
}

/* Pan buffer left or right; fPos is -1...+1. */
bool RageSoundUtil::Pan(
    float* buffer, size_t frames, unsigned channels, float fPos) {
  if (frames == 0) {
    return true;
  }
  if (buffer == nullptr) {
    TraceInvalid("RageSoundUtil", "Pan", "null buffer");
    return false;
  }
  if (channels != 2) {
    TraceInvalid("RageSoundUtil", "Pan", "pan requires a stereo buffer");
    return false;
  }
  size_t samples = 0;
  if (!CheckedMul(frames, static_cast<size_t>(channels), samples)) {
    TraceInvalid("RageSoundUtil", "Pan", "sample count overflow");
    return false;
  }

  fPos = SanitizeControl(fPos, "RageSoundUtil", "Pan", "pan");
  fPos = std::clamp(fPos, -1.0f, 1.0f);
  if (fPos == 0.0f) {
    size_t sanitized = 0;
    for (size_t i = 0; i < samples; ++i) {
      buffer[i] = SanitizeSample(buffer[i], sanitized);
    }
    TraceSanitizedSamples("RageSoundUtil", "Pan", sanitized);
    return true;
  }

  bool bSwap = fPos < 0;
  if (bSwap) {
    fPos = -fPos;
  }

  float fLeftFactors[2] = {1 - fPos, 0};
  float fRightFactors[2] = {
      SCALE(fPos, 0, 1, 0.5f, 0), SCALE(fPos, 0, 1, 0.5f, 1)};

  if (bSwap) {
    std::swap(fLeftFactors[0], fRightFactors[0]);
    std::swap(fLeftFactors[1], fRightFactors[1]);
  }

  size_t sanitized = 0;
  for (size_t samp = 0; samp < frames; ++samp) {
    const float left = SanitizeSample(buffer[0], sanitized);
    const float right = SanitizeSample(buffer[1], sanitized);
    const float l = left * fLeftFactors[0] + right * fLeftFactors[1];
    const float r = left * fRightFactors[0] + right * fRightFactors[1];
    buffer[0] = l;
    buffer[1] = r;
    buffer += 2;
  }
  TraceSanitizedSamples("RageSoundUtil", "Pan", sanitized);
  return true;
}

bool RageSoundUtil::Fade(
    float* pBuffer, size_t iFrames, unsigned iChannels, float fStartVolume,
    float fEndVolume) {
  if (iFrames == 0) {
    return true;
  }
  if (pBuffer == nullptr) {
    TraceInvalid("RageSoundUtil", "Fade", "null buffer");
    return false;
  }
  if (iChannels == 0) {
    TraceInvalid("RageSoundUtil", "Fade", "zero channels");
    return false;
  }
  size_t samples = 0;
  if (!CheckedMul(iFrames, static_cast<size_t>(iChannels), samples)) {
    TraceInvalid("RageSoundUtil", "Fade", "sample count overflow");
    return false;
  }

  fStartVolume =
      SanitizeControl(fStartVolume, "RageSoundUtil", "Fade", "start volume");
  fEndVolume = SanitizeControl(fEndVolume, "RageSoundUtil", "Fade", "end volume");
  /* If the whole buffer is full volume, skip. */
  if (fStartVolume > .9999f && fEndVolume > .9999f) {
    size_t sanitized = 0;
    for (size_t i = 0; i < samples; ++i) {
      pBuffer[i] = SanitizeSample(pBuffer[i], sanitized);
    }
    TraceSanitizedSamples("RageSoundUtil", "Fade", sanitized);
    return true;
  }

  size_t sanitized = 0;
  for (size_t iFrame = 0; iFrame < iFrames; ++iFrame) {
    const float fVolPercent = std::clamp(
        iFrames == 1
            ? fEndVolume
            : SCALE(
                  static_cast<float>(iFrame), 0.0f,
                  static_cast<float>(iFrames - 1), fStartVolume, fEndVolume),
        0.f, 1.f);

    for (unsigned i = 0; i < iChannels; ++i) {
      *pBuffer = SanitizeSample(*pBuffer, sanitized) * fVolPercent;
      pBuffer++;
    }
  }
  TraceSanitizedSamples("RageSoundUtil", "Fade", sanitized);
  return true;
}

/* Dupe mono to stereo in-place; do it in reverse, to handle overlap. */
bool RageSoundUtil::ConvertMonoToStereoInPlace(
    float* data, size_t iFrames, size_t iOutputSamplesCapacity) {
  if (iFrames == 0) {
    return true;
  }
  if (data == nullptr) {
    TraceInvalid("RageSoundUtil", "ConvertMonoToStereoInPlace", "null buffer");
    return false;
  }
  size_t requiredSamples = 0;
  if (!CheckedMul(iFrames, static_cast<size_t>(2), requiredSamples)) {
    TraceInvalid(
        "RageSoundUtil", "ConvertMonoToStereoInPlace", "output size overflow");
    return false;
  }
  if (iOutputSamplesCapacity < requiredSamples) {
    TraceInvalid(
        "RageSoundUtil", "ConvertMonoToStereoInPlace",
        "output capacity is smaller than stereo expansion");
    return false;
  }

  float* input = data;
  float* output = input;
  input += iFrames;
  output += requiredSamples;
  while (iFrames--) {
    input -= 1;
    output -= 2;
    output[0] = input[0];
    output[1] = input[0];
  }
  return true;
}

bool RageSoundUtil::ConvertNativeInt16ToFloat(
    const int16_t* pFrom, float* pTo, size_t iSamples) {
  if (iSamples == 0) {
    return true;
  }
  if (pFrom == nullptr || pTo == nullptr) {
    TraceInvalid("RageSoundUtil", "ConvertNativeInt16ToFloat", "null buffer");
    return false;
  }
  for (size_t i = 0; i < iSamples; ++i) {
    pTo[i] = pFrom[i] / 32768.0f;
  }
  return true;
}

bool RageSoundUtil::ConvertFloatToNativeInt16(
    const float* pFrom, int16_t* pTo, size_t iSamples) {
  if (iSamples == 0) {
    return true;
  }
  if (pFrom == nullptr || pTo == nullptr) {
    TraceInvalid("RageSoundUtil", "ConvertFloatToNativeInt16", "null buffer");
    return false;
  }
  size_t sanitized = 0;
  for (size_t i = 0; i < iSamples; ++i) {
    float sample = SanitizeSample(pFrom[i], sanitized);
    sample = std::clamp(sample, -1.0f, 1.0f);
    const long iOut =
        sample <= -1.0f ? -32768L : std::lround(sample * 32767.0f);
    pTo[i] = static_cast<int16_t>(std::clamp<long>(iOut, -32768, 32767));
  }
  TraceSanitizedSamples("RageSoundUtil", "ConvertFloatToNativeInt16", sanitized);
  return true;
}

/*
 * Copyright (c) 2002-2007 Glenn Maynard
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
