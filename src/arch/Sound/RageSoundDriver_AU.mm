#include "RageSoundDriver_AU.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageSoundConstants.h"
#include "archutils/Darwin/DarwinThreadHelpers.h"
#include "global.h"

#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

#ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif

#include <AudioToolbox/AudioServices.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreServices/CoreServices.h>

REGISTER_SOUND_DRIVER_CLASS2("AudioUnit", AU);

static const UInt32 kFramesPerPacket = 1;
static const UInt32 kChannelsPerFrame = 2;
static const UInt32 kBitsPerChannel = 32;
static const UInt32 kBytesPerPacket = kChannelsPerFrame * kBitsPerChannel / 8;
static const UInt32 kBytesPerFrame = kBytesPerPacket;
static const UInt32 kFormatFlags =
    Enum::to_integral(kAudioFormatFlagsNativeEndian) | Enum::to_integral(kAudioFormatFlagIsFloat);

static const char* FormatOSError(OSStatus status) {
  NSError* error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
  return [error.localizedDescription UTF8String];
}

RageSoundDriver_AU::RageSoundDriver_AU()
    : m_OutputUnit(nullptr),
      m_iSampleRate(0),
      m_bDone(false),
      m_bStarted(false) {}

static void SetSampleRate(AudioUnit au, Float64 desiredRate) {
  AudioDeviceID OutputDevice;
  OSStatus error;
  UInt32 size = sizeof(AudioDeviceID);

  if ((error = AudioUnitGetProperty(
           au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &OutputDevice,
           &size))) {
    LOG->Warn("No output device: %s", FormatOSError(error));
    return;
  }

  AudioObjectPropertyAddress RateAddr = {
      kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  Float64 rate = 0.0;
  size = sizeof(Float64);
  if ((error = AudioObjectGetPropertyData(OutputDevice, &RateAddr, 0, NULL, &size, &rate))) {
    LOG->Warn("Couldn't get the device's sample rate: %s", FormatOSError(error));
    return;
  }
  if (rate == desiredRate) {
    return;
  }

  AudioObjectPropertyAddress AvailableRatesAddr = {
      kAudioDevicePropertyAvailableNominalSampleRates, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  if ((error =
           AudioObjectGetPropertyDataSize(OutputDevice, &AvailableRatesAddr, 0, nullptr, &size))) {
    LOG->Warn("Couldn't get available nominal sample rates info: %s", FormatOSError(error));
    return;
  }

  if (size == 0 || size % sizeof(AudioValueRange) != 0 ||
      size / sizeof(AudioValueRange) > 4096) {
    LOG->Warn("Invalid available nominal sample-rate range size: %u", size);
    return;
  }

  const int num = size / sizeof(AudioValueRange);
  std::vector<AudioValueRange> ranges(num);

  if ((error =
           AudioObjectGetPropertyData(OutputDevice, &AvailableRatesAddr, 0, NULL, &size, ranges.data()))) {
    LOG->Warn("Couldn't get available nominal sample rates: %s", FormatOSError(error));
    return;
  }

  Float64 bestRate = 0.0;
  for (int i = 0; i < num; ++i) {
    if (desiredRate >= ranges[i].mMinimum && desiredRate <= ranges[i].mMaximum) {
      bestRate = desiredRate;
      break;
    }
    /* XXX: If the desired rate is supported by the device, then change it, if not
     * then we should select the "best" rate. I don't really know what such a best
     * rate would be. The rate closest to the desired value? A multiple of 2?
     * For now give up if the desired sample rate isn't available. */
  }
  if (bestRate == 0.0) {
    return;
  }

  if ((error = AudioObjectSetPropertyData(
           OutputDevice, &RateAddr, 0, nullptr, sizeof(Float64), &bestRate))) {
    LOG->Warn("Couldn't set the device's sample rate: %s", FormatOSError(error));
  }
}

std::string RageSoundDriver_AU::Init() {
  AudioComponentDescription desc;

  desc.componentType = kAudioUnitType_Output;
  desc.componentSubType = kAudioUnitSubType_DefaultOutput;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;
  desc.componentFlags = 0;
  desc.componentFlagsMask = 0;

  AudioComponent comp = AudioComponentFindNext(NULL, &desc);
  // Component comp = FindNextComponent( NULL, &desc );

  if (comp == nullptr) {
    return "Failed to find the default output unit.";
  }

  OSStatus error = AudioComponentInstanceNew(comp, &m_OutputUnit);

  if (error != noErr || m_OutputUnit == nullptr) {
    return ssprintf("Could not open the default output unit: %s", FormatOSError(error));
  }

  // Set up a callback function to generate output to the output unit
  AURenderCallbackStruct input;
  input.inputProc = Render;
  input.inputProcRefCon = this;

  error = AudioUnitSetProperty(
      m_OutputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &input,
      sizeof(input));
  if (error != noErr) {
    return ssprintf("Failed to set render callback: %s", FormatOSError(error));
  }

  AudioStreamBasicDescription streamFormat;

  streamFormat.mSampleRate =
      PREFSMAN != nullptr ? PREFSMAN->m_iSoundPreferredSampleRate.Get()
                          : FALLBACK_SAMPLE_RATE;
  streamFormat.mFormatID = kAudioFormatLinearPCM;
  streamFormat.mFormatFlags = kFormatFlags;
  streamFormat.mBytesPerPacket = kBytesPerPacket;
  streamFormat.mFramesPerPacket = kFramesPerPacket;
  streamFormat.mBytesPerFrame = kBytesPerFrame;
  streamFormat.mChannelsPerFrame = kChannelsPerFrame;
  streamFormat.mBitsPerChannel = kBitsPerChannel;

  if (streamFormat.mSampleRate <= 0.0) {
    streamFormat.mSampleRate = FALLBACK_SAMPLE_RATE;
  }
  m_iSampleRate = int(streamFormat.mSampleRate);
  m_TimeScale = streamFormat.mSampleRate / AudioGetHostClockFrequency();

  // Try to set the hardware sample rate.
  SetSampleRate(m_OutputUnit, streamFormat.mSampleRate);

  error = AudioUnitSetProperty(
      m_OutputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat,
      sizeof(AudioStreamBasicDescription));
  if (error != noErr) {
    return ssprintf("Failed to set AU stream format: %s", FormatOSError(error));
  }
  UInt32 renderQuality = kRenderQuality_Max;

  error = AudioUnitSetProperty(
      m_OutputUnit, kAudioUnitProperty_RenderQuality, kAudioUnitScope_Global, 0, &renderQuality,
      sizeof(renderQuality));
  if (error != noErr) {
    LOG->Warn("Failed to set the maximum render quality: %s", FormatOSError(error));
  }

  // Initialize the AU.
  if ((error = AudioUnitInitialize(m_OutputUnit))) {
    return ssprintf("Could not initialize the AudioUnit: %s", FormatOSError(error));
  }

  // Keep a larger decode buffer on macOS to reduce intermittent underruns
  // observed during heavy screen transitions.
  int decodeBufferFrames = 32768;
  if (PREFSMAN != nullptr && PREFSMAN->m_iSoundWriteAhead > 0) {
    decodeBufferFrames = std::max(decodeBufferFrames, PREFSMAN->m_iSoundWriteAhead.Get());
  }
  SetDecodeBufferSize(decodeBufferFrames);

  StartDecodeThread();

  if ((error = AudioOutputUnitStart(m_OutputUnit))) {
    return ssprintf("Could not start the AudioUnit: %s", FormatOSError(error));
  }
  m_bStarted = true;
  return std::string();
}

RageSoundDriver_AU::~RageSoundDriver_AU() {
  if (!m_OutputUnit) {
    return;
  }
  if (m_bStarted) {
    m_bDone.store(true, std::memory_order_release);
    const OSStatus stopError = AudioOutputUnitStop(m_OutputUnit);
    if (stopError != noErr && LOG != nullptr) {
      LOG->Warn("Could not stop the AudioUnit: %s", FormatOSError(stopError));
    }
    m_bStarted = false;
  }
  AudioUnitUninitialize(m_OutputUnit);
  AudioComponentInstanceDispose(m_OutputUnit);
}

int64_t RageSoundDriver_AU::GetPosition() const {
  return int64_t(m_TimeScale * AudioGetCurrentHostTime());
}

void RageSoundDriver_AU::SetupDecodingThread() {
  /* Increase the scheduling precedence of the decoder thread. */
  const std::string sError = SetThreadPrecedence(0.95f);
  if (!sError.empty()) {
    LOG->Warn("Could not set precedence of the decoding thread: %s", sError.c_str());
  }
}

float RageSoundDriver_AU::GetPlayLatency() const {
  OSStatus error;
  UInt32 bufferSize = 0;
  AudioDeviceID OutputDevice;
  UInt32 size = sizeof(AudioDeviceID);
  Float64 sampleRate = 0.0;

  if ((error = AudioUnitGetProperty(
           m_OutputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
           &OutputDevice, &size))) {
    LOG->Warn("No output device: %s", FormatOSError(error));
    return 0.0f;
  }

  AudioObjectPropertyAddress RateAddr = {
      kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  size = sizeof(Float64);
  if ((error =
           AudioObjectGetPropertyData(OutputDevice, &RateAddr, 0, nullptr, &size, &sampleRate))) {
    LOG->Warn("Couldn't get the device sample rate: %s", FormatOSError(error));
    return 0.0f;
  }
  if (sampleRate <= 0.0) {
    LOG->Warn("Device reported an invalid sample rate: %.02f", sampleRate);
    return 0.0f;
  }

  AudioObjectPropertyAddress BufferAddr = {
      kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  size = sizeof(UInt32);
  if ((error =
           AudioObjectGetPropertyData(OutputDevice, &BufferAddr, 0, nullptr, &size, &bufferSize))) {
    LOG->Warn("Couldn't determine buffer size: %s", FormatOSError(error));
    bufferSize = 0;
  }

  UInt32 frames = 0;

  AudioObjectPropertyAddress LatencyAddr = {
      kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  size = sizeof(UInt32);
  if ((error =
           AudioObjectGetPropertyData(OutputDevice, &LatencyAddr, 0, nullptr, &size, &frames))) {
    static bool s_warnedDeviceLatencyUnavailable = false;
    if (!s_warnedDeviceLatencyUnavailable) {
      LOG->Warn("Couldn't get device latency: %s", FormatOSError(error));
      s_warnedDeviceLatencyUnavailable = true;
    }
    frames = 0;
  }

  AudioObjectPropertyAddress SafetyAddr = {
      kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput,
      kAudioObjectPropertyElementWildcard};

  uint64_t totalFrames = bufferSize;
  totalFrames += frames;
  size = sizeof(UInt32);
  if ((error = AudioObjectGetPropertyData(OutputDevice, &SafetyAddr, 0, nullptr, &size, &frames))) {
    LOG->Warn("Couldn't get device safety offset: %s", FormatOSError(error));
    frames = 0;
  }
  totalFrames += frames;
  size = sizeof(UInt32);

  do {
    AudioObjectPropertyAddress StreamsAddr = {
        kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementWildcard};

    if ((error = AudioObjectGetPropertyDataSize(OutputDevice, &StreamsAddr, 0, nullptr, &size))) {
      LOG->Warn("Device has no streams: %s", FormatOSError(error));
      break;
    }
    if (size == 0 || size % sizeof(AudioStreamID) != 0 ||
        size / sizeof(AudioStreamID) > 4096) {
      LOG->Warn("Invalid stream list size: %u", size);
      break;
    }
    int num = size / sizeof(AudioStreamID);
    if (num == 0) {
      LOG->Warn("Device has no streams.");
      break;
    }
    std::vector<AudioStreamID> streams(num);

    if ((error =
             AudioObjectGetPropertyData(OutputDevice, &StreamsAddr, 0, nullptr, &size, streams.data()))) {
      LOG->Warn("Cannot get device's streams: %s", FormatOSError(error));
      break;
    }

    AudioObjectPropertyAddress LatencyAddr = {
        kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementWildcard};

    if ((error =
             AudioObjectGetPropertyData(streams[0], &LatencyAddr, 0, nullptr, &size, &frames))) {
      LOG->Warn("Stream does not report latency: %s", FormatOSError(error));
      frames = 0;
    }
    totalFrames += frames;
  } while (false);

  return float(double(totalFrames) / sampleRate);
}

OSStatus RageSoundDriver_AU::Render(
    void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData) {
  RageSoundDriver_AU* This = (RageSoundDriver_AU*)inRefCon;
  if (This == nullptr || inTimeStamp == nullptr || ioData == nullptr ||
      ioData->mNumberBuffers == 0 || ioData->mBuffers[0].mData == nullptr) {
    return noErr;
  }

  AudioBuffer& buf = ioData->mBuffers[0];
  if (buf.mNumberChannels != kChannelsPerFrame ||
      inNumberFrames > std::numeric_limits<int>::max() ||
      static_cast<uint64_t>(inNumberFrames) * kBytesPerFrame >
          buf.mDataByteSize) {
    memset(buf.mData, 0, buf.mDataByteSize);
    return noErr;
  }
  int64_t now = int64_t(This->m_TimeScale * AudioGetCurrentHostTime());
  int64_t next = int64_t(This->m_TimeScale * inTimeStamp->mHostTime);

  This->Mix(
      static_cast<float*>(buf.mData), static_cast<int>(inNumberFrames), next,
      now);
  if (unlikely(This->m_bDone.load(std::memory_order_acquire))) {
    memset(buf.mData, 0, buf.mDataByteSize);
  }
  return noErr;
}

/*
 * (c) 2004-2007 Steve Checkoway
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
