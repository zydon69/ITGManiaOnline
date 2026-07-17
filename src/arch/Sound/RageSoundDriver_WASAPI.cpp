#include "RageSoundDriver_WASAPI.h"

// clang-format off
#include <windows.h>
#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
// clang-format on

#include "PrefsManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "archutils/Win32/DirectXHelpers.h"
#include "archutils/Win32/ErrorStrings.h"
#include "global.h"

#include <cmath>
#include <limits>

REGISTER_SOUND_DRIVER_CLASS2("WASAPI", WASAPI);

RageSoundDriver_WASAPI::RageSoundDriver_WASAPI()
    : m_iSampleRate(0),
      m_iBufferSizeFrames(0),
      m_iChannels(0),
      m_bFloat(true),
      m_pAudioClient(nullptr),
      m_pRenderClient(nullptr),
      m_pAudioClock(nullptr),
      m_iAudioClockFreq(0),
      m_hAudioEvent(INVALID_HANDLE_VALUE),
      m_bShutdownMixerThread(false),
      m_bOwnsComInit(false) {}

RageSoundDriver_WASAPI::~RageSoundDriver_WASAPI() {
  if (m_MixingThread.IsCreated()) {
    m_bShutdownMixerThread.store(true, std::memory_order_release);
    if (m_hAudioEvent != INVALID_HANDLE_VALUE) {
      SetEvent(m_hAudioEvent);  // Wake up thread
    }
    m_MixingThread.Wait();
  }

  FreeWASAPI();

  if (m_hAudioEvent != INVALID_HANDLE_VALUE) {
    CloseHandle(m_hAudioEvent);
  }
}

void RageSoundDriver_WASAPI::FreeWASAPI() {
  if (m_pAudioClient) {
    m_pAudioClient->Stop();
  }
  if (m_pAudioClock) {
    m_pAudioClock->Release();
    m_pAudioClock = nullptr;
  }
  if (m_pRenderClient) {
    m_pRenderClient->Release();
    m_pRenderClient = nullptr;
  }
  if (m_pAudioClient) {
    m_pAudioClient->Release();
    m_pAudioClient = nullptr;
  }
  if (m_bOwnsComInit) {
    CoUninitialize();
    m_bOwnsComInit = false;
  }
}

bool RageSoundDriver_WASAPI::InitWASAPI(std::string& sError) {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
    sError = hr_ssprintf(hr, "CoInitializeEx failed");
    return false;
  }
  m_bOwnsComInit = SUCCEEDED(hr);

  IMMDeviceEnumerator* pEnumerator = nullptr;
  hr = CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
      IID_PPV_ARGS(&pEnumerator));
  if (FAILED(hr)) {
    sError = hr_ssprintf(hr, "CoCreateInstance(MMDeviceEnumerator) failed");
    FreeWASAPI();
    return false;
  }

  IMMDevice* pDevice = nullptr;
  hr = pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &pDevice);
  pEnumerator->Release();
  if (FAILED(hr)) {
    sError = hr_ssprintf(hr, "GetDefaultAudioEndpoint failed");
    FreeWASAPI();
    return false;
  }

  hr = pDevice->Activate(
      __uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&m_pAudioClient);
  pDevice->Release();
  if (FAILED(hr)) {
    sError = hr_ssprintf(hr, "Activate(IAudioClient) failed");
    FreeWASAPI();
    return false;
  }

  WAVEFORMATEX* pwfx = nullptr;
  hr = m_pAudioClient->GetMixFormat(&pwfx);
  if (FAILED(hr)) {
    sError = hr_ssprintf(hr, "GetMixFormat failed");
    FreeWASAPI();
    return false;
  }

  m_iSampleRate = pwfx->nSamplesPerSec;
  m_iChannels = pwfx->nChannels;
  if (m_iSampleRate <= 0) {
    sError = ssprintf("Invalid WASAPI sample rate: %d", m_iSampleRate);
    CoTaskMemFree(pwfx);
    FreeWASAPI();
    return false;
  }
  if (m_iChannels != 2) {
    sError = ssprintf("Unsupported WASAPI channel count: %d", m_iChannels);
    CoTaskMemFree(pwfx);
    FreeWASAPI();
    return false;
  }

  if (pwfx->wFormatTag != WAVE_FORMAT_EXTENSIBLE ||
      pwfx->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    sError = ssprintf("Unsupported format tag: %d", pwfx->wFormatTag);
    CoTaskMemFree(pwfx);
    FreeWASAPI();
    return false;
  }

  WAVEFORMATEXTENSIBLE* pEx = (WAVEFORMATEXTENSIBLE*)pwfx;
  if (pEx->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) {
    m_bFloat = true;
  } else if (
      pEx->SubFormat == KSDATAFORMAT_SUBTYPE_PCM &&
      pEx->Format.wBitsPerSample == 16) {
    m_bFloat = false;
  } else {
    sError = "Unsupported format (expected float or 16-bit PCM)";
    CoTaskMemFree(pwfx);
    FreeWASAPI();
    return false;
  }

  REFERENCE_TIME hnsRequestedDuration = 0;
  if (PREFSMAN != nullptr && PREFSMAN->m_iSoundWriteAhead.Get() > 0) {
    // WriteAhead is in frames. Convert to 100-nanosecond units.
    hnsRequestedDuration = (REFERENCE_TIME)PREFSMAN->m_iSoundWriteAhead.Get() *
                           10000000ULL / m_iSampleRate;
  }

  hr = m_pAudioClient->Initialize(
      AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
      hnsRequestedDuration, 0, pwfx, nullptr);

  CoTaskMemFree(pwfx);

  if (FAILED(hr)) {
    sError = hr_ssprintf(hr, "Initialize(IAudioClient) failed");
    FreeWASAPI();
    return false;
  }

  m_hAudioEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  if (m_hAudioEvent == NULL) {
    m_hAudioEvent = INVALID_HANDLE_VALUE;
    sError = werr_ssprintf(GetLastError(), "CreateEvent failed");
    FreeWASAPI();
    return false;
  }

  hr = m_pAudioClient->SetEventHandle(m_hAudioEvent);
  if (FAILED(hr)) {
    sError = hr_ssprintf(hr, "SetEventHandle failed");
    FreeWASAPI();
    return false;
  }

  hr = m_pAudioClient->GetBufferSize(&m_iBufferSizeFrames);
  if (FAILED(hr)) {
    sError = hr_ssprintf(hr, "GetBufferSize failed");
    FreeWASAPI();
    return false;
  }
  if (m_iBufferSizeFrames == 0) {
    sError = "WASAPI reported a zero-sized audio buffer";
    FreeWASAPI();
    return false;
  }
  if (m_iBufferSizeFrames > static_cast<UINT32>(INT_MAX / 2)) {
    sError = "WASAPI reported an excessively large audio buffer";
    FreeWASAPI();
    return false;
  }

  hr = m_pAudioClient->GetService(IID_PPV_ARGS(&m_pRenderClient));
  if (FAILED(hr)) {
    sError = hr_ssprintf(hr, "GetService(IAudioRenderClient) failed");
    FreeWASAPI();
    return false;
  }

  hr = m_pAudioClient->GetService(IID_PPV_ARGS(&m_pAudioClock));
  if (FAILED(hr)) {
    sError = hr_ssprintf(hr, "GetService(IAudioClock) failed");
    FreeWASAPI();
    return false;
  }

  hr = m_pAudioClock->GetFrequency(&m_iAudioClockFreq);
  if (FAILED(hr)) {
    sError = hr_ssprintf(hr, "GetFrequency failed");
    FreeWASAPI();
    return false;
  }
  if (m_iAudioClockFreq == 0) {
    sError = "WASAPI audio clock reported a zero frequency";
    FreeWASAPI();
    return false;
  }

  LOG->Info(
      "WASAPI: Shared mode, %d channels, %d Hz, %s, buffer size %d frames",
      m_iChannels, m_iSampleRate, m_bFloat ? "Float" : "Int16",
      m_iBufferSizeFrames);

  return true;
}

std::string RageSoundDriver_WASAPI::Init() {
  m_bShutdownMixerThread.store(false, std::memory_order_release);
  std::string sError;
  if (!InitWASAPI(sError)) {
    return sError;
  }

  // Set decode buffer size.
  // We want it to be at least as big as the WASAPI buffer.
  SetDecodeBufferSize(static_cast<int>(m_iBufferSizeFrames * 3 / 2));
  StartDecodeThread();

  m_MixingThread.SetName("WASAPI Mixer Thread");
  m_MixingThread.Create(MixerThread_start, this);

  return "";
}

int RageSoundDriver_WASAPI::MixerThread_start(void* p) {
  ((RageSoundDriver_WASAPI*)p)->MixerThread();
  return 0;
}

void RageSoundDriver_WASAPI::MixerThread() {
  if (m_pAudioClient == nullptr || m_pRenderClient == nullptr ||
      m_iSampleRate <= 0 || m_iAudioClockFreq == 0 || m_iChannels != 2) {
    return;
  }

  if (!SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL)) {
    if (!SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL)) {
      LOG->Warn(
          werr_ssprintf(
              GetLastError(), "Failed to set WASAPI sound thread priority")
              .c_str());
    }
  }

  HRESULT hr = m_pAudioClient->Start();
  if (FAILED(hr)) {
    LOG->Warn("%s", hr_ssprintf(hr, "Failed to start IAudioClient").c_str());
    return;
  }

  int64_t iHardwareFrame = 0;  // Total frames played/mixed so far

  while (!m_bShutdownMixerThread.load(std::memory_order_acquire)) {
    DWORD waitResult =
        WaitForSingleObject(m_hAudioEvent, 2000);  // 2 second timeout safety
    if (waitResult == WAIT_TIMEOUT) {
      LOG->Warn("WASAPI: Timeout waiting for audio event");
      hr = m_pAudioClient->Stop();
      if (FAILED(hr)) {
        LOG->Warn("%s", hr_ssprintf(hr, "Failed to stop IAudioClient after timeout").c_str());
        break;
      }
      hr = m_pAudioClient->Start();
      if (FAILED(hr)) {
        LOG->Warn("%s", hr_ssprintf(hr, "Failed to restart IAudioClient after timeout").c_str());
        break;
      }
      continue;
    }
    if (waitResult != WAIT_OBJECT_0) {
      LOG->Warn("%s", werr_ssprintf(GetLastError(), "WASAPI event wait failed").c_str());
      break;
    }

    if (m_bShutdownMixerThread.load(std::memory_order_acquire)) {
      break;
    }

    UINT32 padding = 0;
    hr = m_pAudioClient->GetCurrentPadding(&padding);
    if (FAILED(hr)) {
      LOG->Warn("%s", hr_ssprintf(hr, "GetCurrentPadding failed").c_str());
      continue;
    }

    if (padding > m_iBufferSizeFrames) {
      if (LOG != nullptr) {
        LOG->Warn(
            "WASAPI reported invalid padding: %u > %u", padding,
            m_iBufferSizeFrames);
      }
      break;
    }
    UINT32 framesAvailable = m_iBufferSizeFrames - padding;
    if (framesAvailable == 0) {
      continue;
    }

    BYTE* pData = nullptr;
    hr = m_pRenderClient->GetBuffer(framesAvailable, &pData);
    if (FAILED(hr)) {
      LOG->Warn("%s", hr_ssprintf(hr, "GetBuffer failed").c_str());
      continue;
    }
    if (pData == nullptr) {
      LOG->Warn("WASAPI returned a null render buffer");
      m_pRenderClient->ReleaseBuffer(framesAvailable, AUDCLNT_BUFFERFLAGS_SILENT);
      continue;
    }

    int64_t iCurrentFrame = GetPosition();

    if (m_bFloat) {
      this->Mix(
          reinterpret_cast<float*>(pData), static_cast<int>(framesAvailable),
          iHardwareFrame, iCurrentFrame);
    } else {
      this->Mix(
          reinterpret_cast<int16_t*>(pData),
          static_cast<int>(framesAvailable), iHardwareFrame, iCurrentFrame);
    }

    hr = m_pRenderClient->ReleaseBuffer(framesAvailable, 0);
    if (FAILED(hr)) {
      LOG->Warn("%s", hr_ssprintf(hr, "ReleaseBuffer failed").c_str());
    }

    iHardwareFrame += framesAvailable;
  }

  if (m_pAudioClient != nullptr) {
    m_pAudioClient->Stop();
  }
}

int64_t RageSoundDriver_WASAPI::GetPosition() const {
  if (m_pAudioClock == nullptr || m_iSampleRate <= 0 || m_iAudioClockFreq == 0) {
    return 0;
  }
  UINT64 position = 0;
  if (FAILED(m_pAudioClock->GetPosition(&position, nullptr))) {
    return 0;
  }
  const long double frames =
      static_cast<long double>(position) * m_iSampleRate / m_iAudioClockFreq;
  if (!std::isfinite(frames) ||
      frames >= static_cast<long double>(std::numeric_limits<int64_t>::max())) {
    return std::numeric_limits<int64_t>::max();
  }
  return static_cast<int64_t>(frames);
}

float RageSoundDriver_WASAPI::GetPlayLatency() const {
  if (m_pAudioClient == nullptr) {
    return 0.0f;
  }
  REFERENCE_TIME latency = 0;
  if (FAILED(m_pAudioClient->GetStreamLatency(&latency))) {
    return 0.0f;
  }
  return (float)latency / 10000000.0f;
}

int RageSoundDriver_WASAPI::GetSampleRate() const { return m_iSampleRate; }

void RageSoundDriver_WASAPI::SetupDecodingThread() {
  if (!SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL)) {
    LOG->Warn(
        werr_ssprintf(
            GetLastError(), "Failed to set WASAPI decoding thread priority")
            .c_str());
  }
}
