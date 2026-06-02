#ifndef MACOS_FRAME_PACING_H
#define MACOS_FRAME_PACING_H

#include <cstdint>

struct MacOSFramePacingDisplayLinkStats {
  bool available = false;
  bool enabled = false;
  bool started = false;
  bool waited = false;
  bool timed_out = false;
  uint64_t tick_count = 0;
  uint64_t ticks_during_wait = 0;
  uint64_t period_usec = 0;
  uint64_t wait_requested_usec = 0;
  uint64_t wait_actual_usec = 0;
  uint64_t final_wait_usec = 0;
  uint64_t final_wait_sleep_usec = 0;
  uint64_t final_wait_yield_usec = 0;
  uint64_t final_wait_spin_usec = 0;
  uint64_t final_wait_overshoot_usec = 0;
  int final_wait_sleep_chunks = 0;
  int final_wait_yields = 0;
  uint64_t present_lead_usec = 0;
  uint64_t late_tolerance_usec = 0;
  uint64_t phase_tolerance_usec = 0;
  uint64_t target_present_usec = 0;
  uint64_t desired_present_usec = 0;
  uint64_t latest_present_usec = 0;
  uint64_t last_output_usec = 0;
  uint64_t selected_output_usec = 0;
  int64_t output_to_target_usec = 0;
  int64_t selected_output_to_target_usec = 0;
  int64_t output_late_usec = 0;
  bool final_wait_capped = false;
  bool output_phase_accepted = false;
  bool output_aligned_present = false;
  const char* selected_output_source = "none";
  const char* status = "unavailable";
};

bool MacOSFramePacingDisplayLinkEnabled();
bool MacOSFramePacingWaitForDisplayLink(
    uint64_t targetPresentUsec, uint64_t intervalUsec, bool appHasFocus,
    uint64_t presentLeadOverrideUsec,
    MacOSFramePacingDisplayLinkStats* stats);
void MacOSFramePacingResetDisplayLink(const char* reason);

#endif
