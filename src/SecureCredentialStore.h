#ifndef SECURE_CREDENTIAL_STORE_H
#define SECURE_CREDENTIAL_STORE_H

#include <cstddef>
#include <string>

namespace SecureCredentialStore {

inline constexpr std::size_t kMaxSecretLength = 4096;

const char* BackendName();
bool IsAvailable();
bool Store(
    const std::string& service,
    const std::string& account,
    const std::string& secret,
    std::string& error);
bool Load(
    const std::string& service,
    const std::string& account,
    std::string& secret,
    std::string& error);
bool Delete(
    const std::string& service,
    const std::string& account,
    std::string& error);

}  // namespace SecureCredentialStore

#endif
