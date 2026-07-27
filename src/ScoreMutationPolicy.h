#ifndef SCORE_MUTATION_POLICY_H
#define SCORE_MUTATION_POLICY_H

/**
 * Scoring becomes immutable at the first authoritative player failure.
 *
 * Gameplay may continue rendering and judging note data for other players, but
 * a failed player's result must never change afterward.  Keep this policy
 * independent from the scorekeeper implementation so every scoring mode uses
 * the same invariant.
 */
namespace ScoreMutationPolicy {
constexpr bool Allows(bool hasScoringState, bool failed) {
  return hasScoringState && !failed;
}
}  // namespace ScoreMutationPolicy

#endif
