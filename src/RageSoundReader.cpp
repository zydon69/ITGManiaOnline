#include "RageSoundReader.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <new>
#include <string>

#include "PerfDiagnostics.h"
#include "RageLog.h"
#include "RageUtil_AutoPtr.h"

REGISTER_CLASS_TRAITS(RageSoundReader, RageSoundReader::CopyReader(pCopy));

namespace {
constexpr unsigned kMaxImmediateReadRetries = 50;

std::string ReaderSourcePathOrUnknown(const RageSoundReader& reader) {
  std::string sourcePath = reader.GetSourcePath();
  return sourcePath.empty() ? std::string("<unknown>") : sourcePath;
}

}  // namespace

RageSoundReader* RageSoundReader::CopyReader(const RageSoundReader* pCopy) {
  if (pCopy == nullptr) {
    LogReviewSrcDiagnostics(
        "SRC_AUDIT_FIX SRC-2905: refused to copy a null sound reader");
    return nullptr;
  }

  try {
    RageSoundReader* pReader = pCopy->Copy();
    if (pReader == nullptr) {
      LogReviewSrcDiagnostics(
          "SRC_AUDIT_FIX SRC-2905: sound reader Copy returned null for '%s'",
          ReaderSourcePathOrUnknown(*pCopy).c_str());
    }
    return pReader;
  } catch (const std::bad_alloc&) {
    LogReviewSrcDiagnostics(
        "SRC_AUDIT_FIX SRC-2905: sound reader copy allocation failed for '%s'",
        ReaderSourcePathOrUnknown(*pCopy).c_str());
  } catch (...) {
    LogReviewSrcDiagnostics(
        "SRC_AUDIT_FIX SRC-2905: sound reader copy threw for '%s'",
        ReaderSourcePathOrUnknown(*pCopy).c_str());
  }
  return nullptr;
}

RageSoundReader::PropertySetResult RageSoundReader::TrySetProperty(
    const std::string& sProperty, float fValue) {
  if (sProperty.empty() || !std::isfinite(fValue)) {
    return {PropertySetStatus::INVALID_REQUEST};
  }
  return {SetProperty(sProperty, fValue)
              ? PropertySetStatus::APPLIED
              : PropertySetStatus::UNSUPPORTED_OR_REJECTED};
}

const char* RageSoundReader::PropertySetStatusToString(
    PropertySetStatus status) {
  switch (status) {
    case PropertySetStatus::APPLIED:
      return "applied";
    case PropertySetStatus::INVALID_REQUEST:
      return "invalid_request";
    case PropertySetStatus::UNSUPPORTED_OR_REJECTED:
      return "unsupported_or_rejected";
  }
  return "unknown";
}

int RageSoundReader::ClampSourceFrameToInt(std::int64_t iFrame) {
  if (iFrame > std::numeric_limits<int>::max()) {
    LogReviewSrcDiagnostics(
        "SRC_AUDIT_FIX SRC-2902: clamped source frame %lld to INT_MAX",
        static_cast<long long>(iFrame));
    return std::numeric_limits<int>::max();
  }
  if (iFrame < std::numeric_limits<int>::min()) {
    LogReviewSrcDiagnostics(
        "SRC_AUDIT_FIX SRC-2902: clamped source frame %lld to INT_MIN",
        static_cast<long long>(iFrame));
    return std::numeric_limits<int>::min();
  }
  return static_cast<int>(iFrame);
}

/* Read(), handling the STREAM_LOOPED and empty return cases. */
int RageSoundReader::RetriedRead(
    float* pBuffer, int iFrames, std::int64_t* iSourceFrame, float* fRate) {
  if (iFrames == 0) {
    ClearBaseError();
    return 0;
  }
  if (iFrames < 0 || pBuffer == nullptr) {
    SetBaseError(
        "SRC_AUDIT_FIX SRC-2901: RetriedRead received an invalid data request");
    LogReviewSrcDiagnostics("%s", GetBaseError().c_str());
    if (LOG != nullptr) {
      LOG->Warn(
          "RageSoundReader::RetriedRead called with invalid buffer/frame "
          "count.");
    }
    return RageSoundReader::ERROR;
  }

  unsigned zeroProgressReads = 0;
  unsigned streamLoopedReads = 0;
  for (unsigned retryCount = 0; retryCount < kMaxImmediateReadRetries;
       ++retryCount) {
    const float nextRate = this->GetStreamToSourceRatio();
    const std::int64_t nextSourceFrame = this->GetNextSourceFrame64();
    int framesRead = this->Read(pBuffer, iFrames);
    if (framesRead == RageSoundReader::STREAM_LOOPED) {
      ++streamLoopedReads;
      framesRead = 0;
    }
    if (framesRead != 0) {
      if (framesRead > 0) {
        if (fRate) {
          *fRate = std::isfinite(nextRate) && nextRate > 0.0f ? nextRate : 1.0f;
        }
        if (iSourceFrame) {
          *iSourceFrame = nextSourceFrame;
        }
        ClearBaseError();
        m_bRetriedReadStallReported = false;
      }
      return framesRead;
    }
    ++zeroProgressReads;
  }

  ClearBaseError();
  if (!m_bRetriedReadStallReported) {
    LogReviewSrcDiagnostics(
        "SRC_AUDIT_FIX SRC-2899 SRC-2900: sound reader temporarily made no "
        "progress after immediate retries source=%s zero_progress=%u "
        "stream_looped=%u",
        ReaderSourcePathOrUnknown(*this).c_str(), zeroProgressReads,
        streamLoopedReads);
    m_bRetriedReadStallReported = true;
  }

  return RageSoundReader::WOULD_BLOCK;
}

int RageSoundReader::RetriedRead(
    float* pBuffer, int iFrames, int* iSourceFrame, float* fRate) {
  std::int64_t iSourceFrame64 = 0;
  int iRet = RetriedRead(
      pBuffer, iFrames, iSourceFrame != nullptr ? &iSourceFrame64 : nullptr,
      fRate);
  if (iRet > 0 && iSourceFrame != nullptr) {
    *iSourceFrame = ClampSourceFrameToInt(iSourceFrame64);
  }
  return iRet;
}

/*
 * Copyright (c) 2006 Glenn Maynard
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
