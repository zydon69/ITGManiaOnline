#ifndef RAGE_SOUND_UTIL_H
#define RAGE_SOUND_UTIL_H

#include <cstddef>
#include <cstdint>

/** @brief Simple utilities that operate on sound buffers. */
namespace RageSoundUtil {
bool Attenuate(float* pBuf, size_t iSamples, float fVolume);
bool Pan(float* pBuffer, size_t iFrames, unsigned iChannels, float fPos);
bool Fade(
    float* pBuffer, size_t iFrames, unsigned iChannels, float fStartVolume,
    float fEndVolume);
bool ConvertMonoToStereoInPlace(
    float* pBuffer, size_t iFrames, size_t iOutputSamplesCapacity);
bool ConvertNativeInt16ToFloat(
    const int16_t* pFrom, float* pTo, size_t iSamples);
bool ConvertFloatToNativeInt16(
    const float* pFrom, int16_t* pTo, size_t iSamples);
}  // namespace RageSoundUtil

#endif

/*
 * Copyright (c) 2002-2004 Glenn Maynard
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
