#include "RageSoundDriver_OSS.h"

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <string>

#include "RageLog.h"
#include "RageSound.h"
#include "RageSoundConstants.h"
#include "RageSoundManager.h"
#include "global.h"

#include <algorithm>
#include <limits>

#if defined(HAVE_UNISTD_H)
#include <unistd.h>
#endif
#if defined(HAVE_FCNTL_H)
#include <fcntl.h>
#endif
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/soundcard.h>
#include <sys/stat.h>

REGISTER_SOUND_DRIVER_CLASS(OSS);

#if !defined(SNDCTL_DSP_SPEED)
#define SNDCTL_DSP_SPEED SOUND_PCM_WRITE_RATE
#endif

/* samples */
const int channels = 2;
const int bytes_per_frame = channels * 2; /* 16-bit */
const int chunk_order = 12;
const int num_chunks = 4;

int RageSoundDriver_OSS::MixerThread_start(void* p) {
  ((RageSoundDriver_OSS*)p)->MixerThread();
  return 0;
}

void RageSoundDriver_OSS::MixerThread() {
  /* We want to set a higher priority, but Unix only lets root renice
   * < 0, which is silly.  Give it a try, anyway. */
  int status = nice(-10);
  if (status != -1) {
    LOG->Trace("Set MixerThread nice value to %d", status);
  }

  while (!shutdown.load(std::memory_order_acquire)) {
    while (GetData());

    if (fd == -1) {
      break;
    }

    fd_set f;
    FD_ZERO(&f);
    FD_SET(fd, &f);

    usleep(10000);

    struct timeval tv = {0, 10000};
    select(fd + 1, nullptr, &f, nullptr, &tv);
  }
}

void RageSoundDriver_OSS::SetupDecodingThread() {
  int status = nice(-5);
  if (status != -1) {
    LOG->Trace("Set DecodingThread nice value to %d", status);
  }
}

bool RageSoundDriver_OSS::GetData() {
  /* Look for a free buffer. */
  audio_buf_info ab;
  if (ioctl(fd, SNDCTL_DSP_GETOSPACE, &ab) == -1) {
    LOG->Warn("ioctl(SNDCTL_DSP_GETOSPACE): %s", strerror(errno));
    return false;
  }

  if (ab.fragments <= 0 || ab.fragsize <= 0) {
    return false;
  }

  const int chunksize = ab.fragsize;
  if (chunksize % bytes_per_frame != 0) {
    LOG->Warn("OSS reported an invalid fragment size: %i", chunksize);
    return false;
  }

  const int samples = chunksize / sizeof(int16_t);
  if (samples <= 0 || samples > (std::numeric_limits<int>::max() / 2)) {
    LOG->Warn("OSS reported an invalid sample count: %i", samples);
    return false;
  }
  mix_buffer.resize(size_t(samples));

  const int64_t writePosition =
      last_cursor_pos.load(std::memory_order_acquire);
  this->Mix(
      mix_buffer.data(), chunksize / bytes_per_frame, writePosition,
      GetPosition());

  int wrote = write(fd, mix_buffer.data(), chunksize);
  if (wrote != chunksize) {
    LOG->Warn(
        "OSS write failed: wrote %i of %i bytes%s%s", wrote, chunksize,
        wrote == -1 ? ": " : "", wrote == -1 ? strerror(errno) : "");
    return false;
  }

  /* Increment last_cursor_pos. */
  last_cursor_pos.fetch_add(
      chunksize / bytes_per_frame, std::memory_order_release);

  return true;
}

int64_t RageSoundDriver_OSS::GetPosition() const {
  const int64_t writePosition =
      last_cursor_pos.load(std::memory_order_acquire);
  if (fd == -1) {
    return writePosition;
  }

  int delay;
  if (ioctl(fd, SNDCTL_DSP_GETODELAY, &delay) == -1) {
    LOG->Warn("RageSoundDriver_OSS: ioctl(SNDCTL_DSP_GETODELAY): %s", strerror(errno));
    return writePosition;
  }

  if (delay < 0) {
    LOG->Warn("RageSoundDriver_OSS: invalid output delay: %i", delay);
    return writePosition;
  }
  return writePosition - (delay / bytes_per_frame);
}

std::string RageSoundDriver_OSS::CheckOSSVersion(int fd) {
  int version = 0;

#if defined(HAVE_OSS_GETVERSION)
  if (ioctl(fd, OSS_GETVERSION, &version) != 0) {
    LOG->Warn("OSS_GETVERSION failed: %s", strerror(errno));
    version = 0;
  }
#endif

  /*
   * Find out if /dev/dsp is really ALSA emulating it.  ALSA's OSS emulation has
   * been buggy.  If we got here, we probably failed to init ALSA.  The only
   * case I've seen of this so far was not having access to /dev/snd devices.
   */
  /* Reliable but only too recently available:
  if (ioctl(fd, OSS_ALSAEMULVER, &ver) == 0 && ver ) */

  /*
   * Ack.  We can't just check for /proc/asound, since a few systems have ALSA
   * loaded but actually use OSS.  ALSA returns a specific version; check that,
   * too.  It looks like that version is potentially a valid OSS version, so
   * check both.
  */
#ifndef FORCE_OSS
#define ALSA_SNDRV_OSS_VERSION ((3 << 16) | (8 << 8) | (1 << 4) | (0))
  struct stat st;
  if (version == ALSA_SNDRV_OSS_VERSION && stat("/proc/asound", &st) == 0 &&
      (st.st_mode & S_IFMT) == S_IFDIR) {
    return "RageSoundDriver_OSS: ALSA detected.  ALSA OSS emulation is buggy; "
           "use ALSA natively.";
  }
#endif
  if (version) {
    int major, minor, rev;
    if (version < 361) {
      major = (version / 100) % 10;
      minor = (version / 10) % 10;
      rev = (version / 1) % 10;
    } else {
      major = (version / 0x10000) % 0x100;
      minor = (version / 0x00100) % 0x100;
      rev = (version / 0x00001) % 0x100;
    }

    LOG->Info("OSS: %i.%i.%i", major, minor, rev);
  }

  return "";
}

RageSoundDriver_OSS::RageSoundDriver_OSS() {
  fd = -1;
  shutdown.store(false, std::memory_order_relaxed);
  last_cursor_pos.store(0, std::memory_order_relaxed);
  samplerate = FALLBACK_SAMPLE_RATE;
}

std::string RageSoundDriver_OSS::Init() {
  fd = open("/dev/dsp", O_WRONLY | O_NONBLOCK);
  if (fd == -1) {
    return ssprintf(
        "RageSoundDriver_OSS: Couldn't open /dev/dsp: %s", strerror(errno));
  }

  std::string sError = CheckOSSVersion(fd);
  if (sError != "") {
    return sError;
  }

  int fmt_val = AFMT_S16_LE;
  if (ioctl(fd, SNDCTL_DSP_SETFMT, &fmt_val) == -1) {
    return ssprintf(
        "RageSoundDriver_OSS: ioctl(SNDCTL_DSP_SETFMT, %i): %s", fmt_val,
        strerror(errno));
  }
  if (fmt_val != AFMT_S16_LE) {
    return ssprintf(
        "RageSoundDriver_OSS: Wanted format %i, got %i instead", AFMT_S16_LE,
        fmt_val);
  }

  int channels_val = channels;
  if (ioctl(fd, SNDCTL_DSP_CHANNELS, &channels_val) == -1) {
    return ssprintf(
        "RageSoundDriver_OSS: ioctl(SNDCTL_DSP_CHANNELS, %i): %s", channels_val,
        strerror(errno));
  }
  if (channels_val != channels) {
    return ssprintf(
        "RageSoundDriver_OSS: Wanted %i channels, got %i instead", channels,
        channels_val);
  }

  // Determine the target sample rate based on preference
  int targetSampleRate = PREFSMAN != nullptr ? PREFSMAN->m_iSoundPreferredSampleRate.Get() : 0;
  if (targetSampleRate <= 0) {
    targetSampleRate = FALLBACK_SAMPLE_RATE;
  }

  samplerate = targetSampleRate;  // Attempt to set this rate
  if (ioctl(fd, SNDCTL_DSP_SPEED, &samplerate) ==
      -1) {  // Pass 'samplerate' (member var) by address
    return ssprintf(
        "RageSoundDriver_OSS: ioctl(SNDCTL_DSP_SPEED, %i): %s",
        targetSampleRate, strerror(errno));
  }
  // samplerate now holds the actual rate set by the driver
  LOG->Trace(
      "RageSoundDriver_OSS: Requested sample rate %i, got %i", targetSampleRate,
      samplerate);

  int frag_val = (num_chunks << 16) + chunk_order;
  if (ioctl(fd, SNDCTL_DSP_SETFRAGMENT, &frag_val) == -1) {
    return ssprintf(
        "RageSoundDriver_OSS: ioctl(SNDCTL_DSP_SETFRAGMENT, %i): %s", frag_val,
        strerror(errno));
  }
  StartDecodeThread();

  MixingThread.SetName("RageSoundDriver_OSS");
  MixingThread.Create(MixerThread_start, this);

  return "";
}

RageSoundDriver_OSS::~RageSoundDriver_OSS() {
  if (MixingThread.IsCreated()) {
    /* Signal the mixing thread to quit. */
    shutdown.store(true, std::memory_order_release);
    if (LOG != nullptr) {
      LOG->Trace("Shutting down mixer thread ...");
    }
    MixingThread.Wait();
    if (LOG != nullptr) {
      LOG->Trace("Mixer thread shut down.");
    }
  }

  if (fd != -1) {
    close(fd);
  }
}

float RageSoundDriver_OSS::GetPlayLatency() const {
  return 0;  // (1.0f / samplerate) * (buffersize_frames - chunksize_frames);
}

/*
 * (c) 2002-2004 Glenn Maynard
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
