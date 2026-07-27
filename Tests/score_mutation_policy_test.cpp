#include "ScoreMutationPolicy.h"

#include <cassert>

namespace {
struct ResultState {
  int score = 120000;
  int fantastic = 42;
  int miss = 6;
  int holdOk = 2;
  int combo = 17;
};

void ApplyJudgment(ResultState& result, bool hasScoringState, bool failed) {
  if (!ScoreMutationPolicy::Allows(hasScoringState, failed)) {
    return;
  }
  result.score += 1000;
  ++result.fantastic;
  ++result.miss;
  ++result.holdOk;
  ++result.combo;
}

bool SameResult(const ResultState& left, const ResultState& right) {
  return left.score == right.score && left.fantastic == right.fantastic &&
         left.miss == right.miss && left.holdOk == right.holdOk &&
         left.combo == right.combo;
}
}  // namespace

int main() {
  assert(ScoreMutationPolicy::Allows(true, false));
  assert(!ScoreMutationPolicy::Allows(true, true));
  assert(!ScoreMutationPolicy::Allows(false, false));
  assert(!ScoreMutationPolicy::Allows(false, true));

  ResultState active;
  const ResultState beforeActive = active;
  ApplyJudgment(active, true, false);
  assert(!SameResult(active, beforeActive));

  ResultState failed;
  const ResultState frozen = failed;
  ApplyJudgment(failed, true, true);
  ApplyJudgment(failed, true, true);
  assert(SameResult(failed, frozen));

  ResultState missing;
  const ResultState beforeMissing = missing;
  ApplyJudgment(missing, false, false);
  assert(SameResult(missing, beforeMissing));

  return 0;
}
