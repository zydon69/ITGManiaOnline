#ifndef DISPLAY_LINK_PACING_POLICY_H
#define DISPLAY_LINK_PACING_POLICY_H

#include <cstdint>

namespace DisplayLinkPacing {

enum class OutputSource {
  None,
  Previous,
  Current,
  Next,
  Projected,
};

struct OutputPhase {
  uint64_t output_usec = 0;
  int64_t output_to_target_usec = 0;
  int64_t projection_steps = 0;
  OutputSource source = OutputSource::None;
  bool valid = false;
  bool phase_accepted = false;
};

/*
 * Select the display-link phase nearest to targetPresentUsec while requiring
 * the chosen output deadline to be at or after earliestOutputUsec.
 *
 * lastOutputUsec is the latest phase observed by the display-link callback.
 * periodUsec projects that phase forwards (or, when still safe, backwards)
 * onto the physical refresh lattice.  The future-deadline requirement keeps a
 * stale callback timestamp from turning frame pacing into a zero-length wait.
 */
OutputPhase SelectFutureOutputForTarget(
    uint64_t lastOutputUsec, uint64_t targetPresentUsec,
    uint64_t periodUsec, uint64_t phaseToleranceUsec,
    uint64_t earliestOutputUsec);

const char* OutputSourceName(OutputSource source);

}  // namespace DisplayLinkPacing

#endif
