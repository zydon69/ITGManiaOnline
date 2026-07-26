#include "DisplayLinkPacingPolicy.h"

#include <cstdint>
#include <limits>

namespace DisplayLinkPacing {
namespace {

uint64_t AbsDeltaUsec(uint64_t lhs, uint64_t rhs) {
  return lhs > rhs ? lhs - rhs : rhs - lhs;
}

int64_t SignedDeltaUsec(uint64_t lhs, uint64_t rhs) {
  const uint64_t magnitude = AbsDeltaUsec(lhs, rhs);
  const uint64_t maximum =
      static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
  if (magnitude > maximum) {
    return lhs >= rhs ? std::numeric_limits<int64_t>::max()
                      : std::numeric_limits<int64_t>::min();
  }
  const int64_t signedMagnitude = static_cast<int64_t>(magnitude);
  return lhs >= rhs ? signedMagnitude : -signedMagnitude;
}

bool CheckedProject(
    uint64_t originUsec, uint64_t periodUsec, uint64_t steps,
    uint64_t* projectedUsec) {
  if (projectedUsec == nullptr || periodUsec == 0) {
    return false;
  }
  if (steps > (std::numeric_limits<uint64_t>::max() - originUsec) /
                  periodUsec) {
    return false;
  }
  *projectedUsec = originUsec + steps * periodUsec;
  return true;
}

OutputSource SourceForProjection(int64_t projectionSteps) {
  switch (projectionSteps) {
    case -1:
      return OutputSource::Previous;
    case 0:
      return OutputSource::Current;
    case 1:
      return OutputSource::Next;
    default:
      return OutputSource::Projected;
  }
}

void ConsiderCandidate(
    uint64_t candidateUsec, int64_t projectionSteps,
    uint64_t targetPresentUsec, uint64_t phaseToleranceUsec,
    OutputPhase* best) {
  if (best == nullptr) {
    return;
  }

  const uint64_t candidateDelta =
      AbsDeltaUsec(candidateUsec, targetPresentUsec);
  const uint64_t bestDelta =
      best->valid ? AbsDeltaUsec(best->output_usec, targetPresentUsec)
                  : std::numeric_limits<uint64_t>::max();
  const bool candidateAtOrAfterTarget = candidateUsec >= targetPresentUsec;
  const bool bestAtOrAfterTarget =
      best->valid && best->output_usec >= targetPresentUsec;
  if (best->valid &&
      (candidateDelta > bestDelta ||
       (candidateDelta == bestDelta &&
        (!candidateAtOrAfterTarget || bestAtOrAfterTarget)))) {
    return;
  }

  best->output_usec = candidateUsec;
  best->output_to_target_usec =
      SignedDeltaUsec(candidateUsec, targetPresentUsec);
  best->projection_steps = projectionSteps;
  best->source = SourceForProjection(projectionSteps);
  best->valid = true;
  best->phase_accepted = candidateDelta <= phaseToleranceUsec;
}

}  // namespace

OutputPhase SelectFutureOutputForTarget(
    uint64_t lastOutputUsec, uint64_t targetPresentUsec,
    uint64_t periodUsec, uint64_t phaseToleranceUsec,
    uint64_t earliestOutputUsec) {
  OutputPhase best;
  if (lastOutputUsec == 0 || periodUsec == 0) {
    return best;
  }

  if (earliestOutputUsec == 0) {
    earliestOutputUsec = 1;
  }

  uint64_t firstEligibleUsec = lastOutputUsec;
  int64_t firstProjectionSteps = 0;
  if (earliestOutputUsec > lastOutputUsec) {
    const uint64_t deltaUsec = earliestOutputUsec - lastOutputUsec;
    const uint64_t steps =
        deltaUsec / periodUsec + (deltaUsec % periodUsec != 0 ? 1 : 0);
    if (steps >
            static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
        !CheckedProject(
            lastOutputUsec, periodUsec, steps, &firstEligibleUsec)) {
      return best;
    }
    firstProjectionSteps = static_cast<int64_t>(steps);
  } else {
    const uint64_t steps = (lastOutputUsec - earliestOutputUsec) / periodUsec;
    if (steps >
        static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
      return best;
    }
    firstEligibleUsec = lastOutputUsec - steps * periodUsec;
    firstProjectionSteps = -static_cast<int64_t>(steps);
  }

  uint64_t candidateUsec = firstEligibleUsec;
  int64_t candidateProjectionSteps = firstProjectionSteps;
  if (targetPresentUsec > firstEligibleUsec) {
    const uint64_t steps = (targetPresentUsec - firstEligibleUsec) / periodUsec;
    if (steps >
        static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
      return best;
    }
    const int64_t signedSteps = static_cast<int64_t>(steps);
    if (candidateProjectionSteps >
        std::numeric_limits<int64_t>::max() - signedSteps) {
      return best;
    }
    if (!CheckedProject(
            firstEligibleUsec, periodUsec, steps, &candidateUsec)) {
      return best;
    }
    candidateProjectionSteps += signedSteps;
  }

  ConsiderCandidate(
      candidateUsec, candidateProjectionSteps, targetPresentUsec,
      phaseToleranceUsec, &best);

  uint64_t nextCandidateUsec = 0;
  if (candidateProjectionSteps < std::numeric_limits<int64_t>::max() &&
      CheckedProject(candidateUsec, periodUsec, 1, &nextCandidateUsec)) {
    ConsiderCandidate(
        nextCandidateUsec, candidateProjectionSteps + 1, targetPresentUsec,
        phaseToleranceUsec, &best);
  }
  return best;
}

const char* OutputSourceName(OutputSource source) {
  switch (source) {
    case OutputSource::Previous:
      return "previous";
    case OutputSource::Current:
      return "current";
    case OutputSource::Next:
      return "next";
    case OutputSource::Projected:
      return "projected";
    default:
      return "none";
  }
}

}  // namespace DisplayLinkPacing
