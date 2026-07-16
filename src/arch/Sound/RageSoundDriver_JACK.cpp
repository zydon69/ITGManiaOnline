#include "RageSoundDriver_JACK.h"

#include <cstdint>
#include <climits>
#include <limits>
#include <string>
#include <vector>

#include "PrefsManager.h"
#include "ProductInfo.h"
#include "RageLog.h"
#include "RageSoundConstants.h"
#include "RageUtil.h"
#include "global.h"

REGISTER_SOUND_DRIVER_CLASS(JACK);

RageSoundDriver_JACK::RageSoundDriver_JACK() : RageSoundDriver() {
  client = nullptr;
  port_l = nullptr;
  port_r = nullptr;
  sample_rate.store(FALLBACK_SAMPLE_RATE, std::memory_order_relaxed);
  last_frame.store(0, std::memory_order_relaxed);
}

RageSoundDriver_JACK::~RageSoundDriver_JACK() {
  jack_client_t* currentClient =
      client.exchange(nullptr, std::memory_order_acq_rel);
  if (currentClient == nullptr) {
    return;
  }

  jack_deactivate(currentClient);
  if (jack_port_t* right = port_r.exchange(nullptr, std::memory_order_acq_rel)) {
    jack_port_unregister(currentClient, right);
  }
  if (jack_port_t* left = port_l.exchange(nullptr, std::memory_order_acq_rel)) {
    jack_port_unregister(currentClient, left);
  }
  jack_client_close(currentClient);
}

std::string RageSoundDriver_JACK::Init() {
  jack_status_t status;
  std::string error;

  // Open JACK client and call it "StepMania" or whatever
  jack_client_t* currentClient =
      jack_client_open(PRODUCT_FAMILY, JackNoStartServer, &status);
  client.store(currentClient, std::memory_order_release);
  if (currentClient == nullptr) {
    return "Couldn't connect to JACK server";
  }

  sample_rate.store(
      jack_get_sample_rate(currentClient), std::memory_order_release);
  if (LOG != nullptr) {
    LOG->Trace("JACK connected at %u Hz",
               sample_rate.load(std::memory_order_acquire));
  }

  // Start this before callbacks
  StartDecodeThread();

  // Set callback for processing audio
  if (jack_set_process_callback(currentClient, ProcessTrampoline, this)) {
    error = "Couldn't set JACK process callback";
    goto out_close;
  }

  if (jack_set_sample_rate_callback(
          currentClient, SampleRateTrampoline, this)) {
    error = "Couldn't set JACK sample-rate callback";
    goto out_close;
  }

  jack_on_shutdown(currentClient, ShutdownTrampoline, this);

  // Create output ports
  port_l.store(
      jack_port_register(
          currentClient, "out_l", JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput,
          0),
      std::memory_order_release);
  if (port_l.load(std::memory_order_acquire) == nullptr) {
    error = "Couldn't create JACK port out_l";
    goto out_close;
  }

  port_r.store(
      jack_port_register(
          currentClient, "out_r", JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput,
          0),
      std::memory_order_release);
  if (port_r.load(std::memory_order_acquire) == nullptr) {
    error = "Couldn't create JACK port out_r";
    goto out_unreg_l;
  }

  // Go!
  if (jack_activate(currentClient)) {
    error = "Couldn't activate JACK client";
    goto out_unreg_r;
  }

  error = ConnectPorts();
  if (!error.empty()) {
    // Eh. Not fatal. JACK *is* running and we successfully created
    // our source ports, so it's unlkely any other driver will
    // function.
    if (LOG != nullptr) {
      LOG->Warn(
          "RageSoundDriver_JACK: Couldn't connect ports: %s", error.c_str());
    }
  }

  // Success!
  if (LOG != nullptr) {
    LOG->Trace("JACK sound driver started successfully");
  }
  return std::string();

  // Not success!
out_unreg_r:
  jack_port_unregister(
      currentClient, port_r.exchange(nullptr, std::memory_order_acq_rel));
out_unreg_l:
  jack_port_unregister(
      currentClient, port_l.exchange(nullptr, std::memory_order_acq_rel));
out_close:
  jack_client_close(currentClient);
  client.store(nullptr, std::memory_order_release);
  return error;
}

std::string RageSoundDriver_JACK::ConnectPorts() {
  std::vector<std::string> portNames;
  if (PREFSMAN != nullptr) {
    split(PREFSMAN->m_iSoundDevice.Get(), ",", portNames, true);
  }

  jack_client_t* currentClient = client.load(std::memory_order_acquire);
  jack_port_t* leftPort = port_l.load(std::memory_order_acquire);
  jack_port_t* rightPort = port_r.load(std::memory_order_acquire);
  if (currentClient == nullptr || leftPort == nullptr || rightPort == nullptr) {
    return "JACK client or output ports are unavailable";
  }

  const char *port_out_l = nullptr, *port_out_r = nullptr;
  const char** ports = nullptr;
  if (portNames.size() == 0) {
    // The user has NOT specified any ports to connect to. Search
    // for all physical sinks and use the first two.
    ports = jack_get_ports(
        currentClient, nullptr, nullptr, JackPortIsInput | JackPortIsPhysical);
    if (ports == nullptr) {
      return "Couldn't get JACK ports";
    }
    if (ports[0] == nullptr) {
      jack_free(ports);
      return "No physical sinks!";
    }
    port_out_l = ports[0];

    if (ports[1] == nullptr) {
      // Only one physical sink. We're going mono!
      port_out_r = ports[0];
    } else {
      port_out_r = ports[1];
    }
  } else {
    // The user has specified ports to connect to. Loop through
    // them to find two that are valid, then use them. If we find
    // only one that is valid, connect both channels to it.
    // Use jack_port_by_name to ensure ports exist, then
    // jack_port_name to use their canonical name.  (I'm not sure
    // if that second step is necessary, I've seen something about
    // "aliases" in the docs.)
    for (const std::string& portName : portNames) {
      jack_port_t* out = jack_port_by_name(currentClient, portName.c_str());
      if (out == nullptr) {
        continue;
      }
      // Make sure the port is a sink.
      if (!(jack_port_flags(out) & JackPortIsInput)) {
        continue;
      }

      if (port_out_l == nullptr) {
        port_out_l = jack_port_name(out);
      } else {
        port_out_r = jack_port_name(out);
        break;
      }
    }
    if (port_out_l == nullptr) {
      return "All specified sinks are invalid.";
    }

    if (port_out_r == nullptr) {
      // Only found one valid sink. Going mono!
      port_out_r = port_out_l;
    }
  }

  std::string ret = std::string();

  if (jack_connect(currentClient, jack_port_name(leftPort), port_out_l) != 0) {
    ret = "Couldn't connect left JACK port";
  } else if (
      jack_connect(currentClient, jack_port_name(rightPort), port_out_r) != 0) {
    ret = "Couldn't connect right JACK port";
  }

  if (ports != nullptr) {
    jack_free(ports);
  }

  return ret;
}

int64_t RageSoundDriver_JACK::GetPosition() const {
  jack_client_t* currentClient = client.load(std::memory_order_acquire);
  if (currentClient == nullptr) {
    return last_frame.load(std::memory_order_acquire);
  }
  const int64_t frame = jack_frame_time(currentClient);
  last_frame.store(frame, std::memory_order_release);
  return frame;
}

int RageSoundDriver_JACK::GetSampleRate() const {
  return sample_rate.load(std::memory_order_acquire);
}

int RageSoundDriver_JACK::ProcessCallback(jack_nframes_t nframes) {
  jack_client_t* currentClient = client.load(std::memory_order_acquire);
  jack_port_t* leftPort = port_l.load(std::memory_order_acquire);
  jack_port_t* rightPort = port_r.load(std::memory_order_acquire);
  if (currentClient == nullptr || leftPort == nullptr || rightPort == nullptr ||
      nframes > static_cast<jack_nframes_t>(std::numeric_limits<int>::max())) {
    return 0;
  }
  jack_default_audio_sample_t* bufs[2];

  bufs[0] = static_cast<jack_default_audio_sample_t*>(
      jack_port_get_buffer(leftPort, nframes));
  bufs[1] = static_cast<jack_default_audio_sample_t*>(
      jack_port_get_buffer(rightPort, nframes));
  if (bufs[0] == nullptr || bufs[1] == nullptr) {
    return 0;
  }

  jack_time_t now = jack_last_frame_time(currentClient);
  last_frame.store(now, std::memory_order_release);

  MixDeinterlaced(
      bufs, 2, static_cast<int>(nframes), now, now + nframes);

  return 0;
}

int RageSoundDriver_JACK::SampleRateCallback(jack_nframes_t nframes) {
  const int newRate =
      nframes > 0 && nframes <= static_cast<jack_nframes_t>(INT_MAX)
          ? static_cast<int>(nframes)
          : FALLBACK_SAMPLE_RATE;
  sample_rate.store(newRate, std::memory_order_release);
  return 0;
}

// Static callback trampoline
int RageSoundDriver_JACK::ProcessTrampoline(jack_nframes_t nframes, void* arg) {
  return ((RageSoundDriver_JACK*)arg)->ProcessCallback(nframes);
}

int RageSoundDriver_JACK::SampleRateTrampoline(
    jack_nframes_t nframes, void* arg) {
  return ((RageSoundDriver_JACK*)arg)->SampleRateCallback(nframes);
}

void RageSoundDriver_JACK::ShutdownCallback() {
  client.store(nullptr, std::memory_order_release);
  port_l.store(nullptr, std::memory_order_release);
  port_r.store(nullptr, std::memory_order_release);
}

void RageSoundDriver_JACK::ShutdownTrampoline(void* arg) {
  ((RageSoundDriver_JACK*)arg)->ShutdownCallback();
}

/*
 * (c) 2013 Devin J. Pohly
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
