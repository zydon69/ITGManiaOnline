#include "arch/LowLevelWindow/DisplayLinkPacingPolicy.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>

namespace {

void Require(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "display-link pacing policy: " << message << std::endl;
    std::exit(1);
  }
}

uint64_t Distance(uint64_t lhs, uint64_t rhs) {
  return lhs > rhs ? lhs - rhs : rhs - lhs;
}

}  // namespace

int main() {
  using DisplayLinkPacing::OutputSource;
  using DisplayLinkPacing::SelectFutureOutputForTarget;

  auto phase = SelectFutureOutputForTarget(0, 100, 10, 5, 90);
  Require(!phase.valid, "a missing observed phase must be rejected");

  phase = SelectFutureOutputForTarget(100, 102, 0, 5, 90);
  Require(!phase.valid, "a zero refresh period must be rejected");

  phase = SelectFutureOutputForTarget(100, 102, 10, 5, 90);
  Require(phase.valid, "a current eligible phase must be selected");
  Require(phase.output_usec == 100, "the nearest eligible phase must win");
  Require(
      phase.source == OutputSource::Current,
      "the observed phase must retain its source");
  Require(phase.phase_accepted, "an in-tolerance phase must be accepted");

  phase = SelectFutureOutputForTarget(100, 102, 10, 5, 103);
  Require(phase.valid, "a stale phase must be projected");
  Require(
      phase.output_usec == 110,
      "a stale observed phase must never produce a past deadline");
  Require(
      phase.source == OutputSource::Next && phase.projection_steps == 1,
      "the next physical refresh must be identified explicitly");

  phase = SelectFutureOutputForTarget(100, 131, 10, 5, 123);
  Require(
      phase.output_usec == 130 && phase.projection_steps == 3,
      "the policy must project across multiple missed refresh periods");
  Require(
      phase.source == OutputSource::Projected,
      "multi-period projection must be visible in diagnostics");

  phase = SelectFutureOutputForTarget(110, 101, 10, 5, 90);
  Require(
      phase.output_usec == 100 && phase.projection_steps == -1,
      "an eligible prior lattice point may be selected");
  Require(
      phase.source == OutputSource::Previous,
      "a prior lattice point must retain its source");

  phase = SelectFutureOutputForTarget(100, 105, 10, 5, 100);
  Require(
      phase.output_usec == 110,
      "an equal-distance tie must prefer the phase at or after the target");

  phase = SelectFutureOutputForTarget(100, 106, 10, 3, 100);
  Require(
      phase.output_usec == 110 && !phase.phase_accepted,
      "the nearest physical phase must still report a tolerance miss");

  phase = SelectFutureOutputForTarget(
      std::numeric_limits<uint64_t>::max() - 2,
      std::numeric_limits<uint64_t>::max(), 10, 5,
      std::numeric_limits<uint64_t>::max());
  Require(!phase.valid, "projection overflow must be rejected");

  // Exhaustively compare small inputs with a direct lattice search.  This
  // protects the scheduling invariant independently of the production caller:
  // a selected deadline is eligible, on the physical refresh phase, nearest to
  // the target, and resolves exact ties in favor of the future output.
  for (uint64_t observed = 20; observed <= 80; observed += 5) {
    for (uint64_t period = 1; period <= 12; ++period) {
      for (uint64_t target = 1; target <= 120; ++target) {
        for (uint64_t earliest = 1; earliest <= 120; ++earliest) {
          bool expectedValid = false;
          uint64_t expectedOutput = 0;
          uint64_t expectedDistance = 0;
          for (int projection = -100; projection <= 100; ++projection) {
            const int64_t candidate =
                static_cast<int64_t>(observed) +
                static_cast<int64_t>(projection) *
                    static_cast<int64_t>(period);
            if (candidate <= 0 ||
                static_cast<uint64_t>(candidate) < earliest) {
              continue;
            }
            const uint64_t output = static_cast<uint64_t>(candidate);
            const uint64_t distance = Distance(output, target);
            if (!expectedValid || distance < expectedDistance ||
                (distance == expectedDistance && output >= target &&
                 expectedOutput < target)) {
              expectedValid = true;
              expectedOutput = output;
              expectedDistance = distance;
            }
          }

          phase = SelectFutureOutputForTarget(
              observed, target, period, 4, earliest);
          Require(
              phase.valid == expectedValid,
              "policy validity must match the physical lattice");
          Require(
              !phase.valid || phase.output_usec == expectedOutput,
              "policy output must be the nearest eligible physical phase");
          Require(
              !phase.valid || phase.output_usec >= earliest,
              "policy must never return an expired deadline");
        }
      }
    }
  }

  std::cout << "display-link pacing policy: ok" << std::endl;
  return 0;
}
