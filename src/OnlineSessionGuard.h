#pragma once

#include <atomic>

// Lua remains the authority for the online room. This guard only remembers a
// successfully observed active session so screen-level safety gates fail closed
// while a Lua evaluation is temporarily unavailable.
namespace ITGOnlineSessionGuard {
inline std::atomic<bool>& ObservedActiveFlag() {
  static std::atomic<bool> observedActive{false};
  return observedActive;
}

inline void Observe(const bool active) {
  ObservedActiveFlag().store(active, std::memory_order_release);
}

inline bool IsObservedActive() {
  return ObservedActiveFlag().load(std::memory_order_acquire);
}
}  // namespace ITGOnlineSessionGuard
