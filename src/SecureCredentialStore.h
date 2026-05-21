#ifndef SECURE_CREDENTIAL_STORE_H
#define SECURE_CREDENTIAL_STORE_H

#include <string>

namespace SecureCredentialStore {

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
