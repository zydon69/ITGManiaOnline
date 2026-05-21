#include "SecureCredentialStore.h"

#include <string>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#elif defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <wincred.h>
#elif defined(__linux__) && defined(HAVE_LIBSECRET)
#include <libsecret/secret.h>
#endif

namespace {

bool ValidateInputs(
    const std::string& service, const std::string& account, std::string& error) {
  if (service.empty()) {
    error = "service is required";
    return false;
  }
  if (account.empty()) {
    error = "account is required";
    return false;
  }

  return true;
}

#if defined(__APPLE__)
CFStringRef CopyCFString(const std::string& value) {
  return CFStringCreateWithBytes(
      kCFAllocatorDefault, reinterpret_cast<const UInt8*>(value.data()),
      value.size(), kCFStringEncodingUTF8, false);
}

CFDataRef CopyCFData(const std::string& value) {
  return CFDataCreate(
      kCFAllocatorDefault, reinterpret_cast<const UInt8*>(value.data()),
      value.size());
}

std::string StatusMessage(OSStatus status) {
  if (CFStringRef message = SecCopyErrorMessageString(status, nullptr)) {
    char buffer[512] = {};
    if (CFStringGetCString(
            message, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
      CFRelease(message);
      return buffer;
    }
    CFRelease(message);
  }

  return "Keychain error " + std::to_string(static_cast<long long>(status));
}

CFMutableDictionaryRef CopyBaseQuery(
    const std::string& service, const std::string& account) {
  CFMutableDictionaryRef query = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);

  CFStringRef serviceRef = CopyCFString(service);
  CFStringRef accountRef = CopyCFString(account);

  CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(query, kSecAttrService, serviceRef);
  CFDictionarySetValue(query, kSecAttrAccount, accountRef);

  CFRelease(serviceRef);
  CFRelease(accountRef);

  return query;
}
#elif defined(_WIN32)
std::string TargetName(const std::string& service, const std::string& account) {
  return service + ":" + account;
}

std::string LastWindowsErrorMessage(const char* fallback) {
  DWORD code = GetLastError();
  if (code == ERROR_NOT_FOUND) {
    return "credential not found";
  }

  LPSTR message = nullptr;
  DWORD size = FormatMessageA(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPSTR>(&message), 0, nullptr);

  if (size == 0 || message == nullptr) {
    return fallback;
  }

  std::string result(message, size);
  LocalFree(message);
  while (!result.empty() &&
         (result.back() == '\r' || result.back() == '\n' ||
          result.back() == ' ')) {
    result.pop_back();
  }
  return result;
}
#elif defined(__linux__) && defined(HAVE_LIBSECRET)
const SecretSchema* CredentialSchema() {
  static const SecretSchema schema = {
      "fr.itgonline.ITGmania.Password",
      SECRET_SCHEMA_NONE,
      {
          {"service", SECRET_SCHEMA_ATTRIBUTE_STRING},
          {"account", SECRET_SCHEMA_ATTRIBUTE_STRING},
          {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING},
      },
  };

  return &schema;
}

std::string GlibErrorMessage(GError* glibError, const char* fallback) {
  if (glibError == nullptr) {
    return fallback;
  }

  std::string message = glibError->message != nullptr ? glibError->message : fallback;
  g_error_free(glibError);
  return message;
}
#endif

}  // namespace

namespace SecureCredentialStore {

const char* BackendName() {
#if defined(__APPLE__)
  return "macOS Keychain";
#elif defined(_WIN32)
  return "Windows Credential Manager";
#elif defined(__linux__) && defined(HAVE_LIBSECRET)
  return "libsecret";
#else
  return "unavailable";
#endif
}

bool IsAvailable() {
#if defined(__APPLE__) || defined(_WIN32) || \
    (defined(__linux__) && defined(HAVE_LIBSECRET))
  return true;
#else
  return false;
#endif
}

bool Store(
    const std::string& service,
    const std::string& account,
    const std::string& secret,
    std::string& error) {
  if (!ValidateInputs(service, account, error)) {
    return false;
  }
  if (secret.empty()) {
    error = "secret is required";
    return false;
  }

#if defined(__APPLE__)
  CFMutableDictionaryRef query = CopyBaseQuery(service, account);
  CFDataRef secretRef = CopyCFData(secret);
  CFDictionarySetValue(query, kSecValueData, secretRef);
  CFDictionarySetValue(
      query, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);

  OSStatus status = SecItemAdd(query, nullptr);
  if (status == errSecDuplicateItem) {
    CFMutableDictionaryRef updateQuery = CopyBaseQuery(service, account);
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attributes, kSecValueData, secretRef);
    CFDictionarySetValue(
        attributes, kSecAttrAccessible,
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);

    status = SecItemUpdate(updateQuery, attributes);

    CFRelease(attributes);
    CFRelease(updateQuery);
  }

  CFRelease(secretRef);
  CFRelease(query);

  if (status != errSecSuccess) {
    error = StatusMessage(status);
    return false;
  }

  error.clear();
  return true;
#elif defined(_WIN32)
  std::string target = TargetName(service, account);
  CREDENTIALA credential = {};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = const_cast<LPSTR>(target.c_str());
  credential.CredentialBlob =
      reinterpret_cast<LPBYTE>(const_cast<char*>(secret.data()));
  credential.CredentialBlobSize = static_cast<DWORD>(secret.size());
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;

  if (!CredWriteA(&credential, 0)) {
    error = LastWindowsErrorMessage("Credential Manager write failed");
    return false;
  }

  error.clear();
  return true;
#elif defined(__linux__) && defined(HAVE_LIBSECRET)
  GError* glibError = nullptr;
  const std::string label = service + " (" + account + ")";
  const gboolean ok = secret_password_store_sync(
      CredentialSchema(), SECRET_COLLECTION_DEFAULT, label.c_str(),
      secret.c_str(), nullptr, &glibError, "service", service.c_str(),
      "account", account.c_str(), nullptr);

  if (!ok) {
    error = GlibErrorMessage(glibError, "libsecret write failed");
    return false;
  }

  error.clear();
  return true;
#else
  error = "secure credential storage is not available on this platform";
  return false;
#endif
}

bool Load(
    const std::string& service,
    const std::string& account,
    std::string& secret,
    std::string& error) {
  if (!ValidateInputs(service, account, error)) {
    return false;
  }

#if defined(__APPLE__)
  CFMutableDictionaryRef query = CopyBaseQuery(service, account);
  CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
  CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);

  CFTypeRef result = nullptr;
  OSStatus status = SecItemCopyMatching(query, &result);
  CFRelease(query);

  if (status == errSecItemNotFound) {
    error = "credential not found";
    return false;
  }
  if (status != errSecSuccess || result == nullptr) {
    error = StatusMessage(status);
    return false;
  }
  if (CFGetTypeID(result) != CFDataGetTypeID()) {
    CFRelease(result);
    error = "credential data has an unexpected type";
    return false;
  }

  CFDataRef data = static_cast<CFDataRef>(result);
  secret.assign(
      reinterpret_cast<const char*>(CFDataGetBytePtr(data)),
      static_cast<size_t>(CFDataGetLength(data)));
  CFRelease(result);

  error.clear();
  return true;
#elif defined(_WIN32)
  std::string target = TargetName(service, account);
  PCREDENTIALA credential = nullptr;
  if (!CredReadA(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
    error = LastWindowsErrorMessage("Credential Manager read failed");
    return false;
  }

  secret.assign(
      reinterpret_cast<const char*>(credential->CredentialBlob),
      credential->CredentialBlobSize);
  CredFree(credential);

  error.clear();
  return true;
#elif defined(__linux__) && defined(HAVE_LIBSECRET)
  GError* glibError = nullptr;
  char* password = secret_password_lookup_sync(
      CredentialSchema(), nullptr, &glibError, "service", service.c_str(),
      "account", account.c_str(), nullptr);

  if (password == nullptr) {
    error = glibError != nullptr ? GlibErrorMessage(glibError, "libsecret read failed")
                                : "credential not found";
    return false;
  }

  secret = password;
  secret_password_free(password);

  error.clear();
  return true;
#else
  error = "secure credential storage is not available on this platform";
  return false;
#endif
}

bool Delete(
    const std::string& service,
    const std::string& account,
    std::string& error) {
  if (!ValidateInputs(service, account, error)) {
    return false;
  }

#if defined(__APPLE__)
  CFMutableDictionaryRef query = CopyBaseQuery(service, account);
  OSStatus status = SecItemDelete(query);
  CFRelease(query);

  if (status != errSecSuccess && status != errSecItemNotFound) {
    error = StatusMessage(status);
    return false;
  }

  error.clear();
  return true;
#elif defined(_WIN32)
  std::string target = TargetName(service, account);
  if (!CredDeleteA(target.c_str(), CRED_TYPE_GENERIC, 0)) {
    DWORD code = GetLastError();
    if (code != ERROR_NOT_FOUND) {
      error = LastWindowsErrorMessage("Credential Manager delete failed");
      return false;
    }
  }

  error.clear();
  return true;
#elif defined(__linux__) && defined(HAVE_LIBSECRET)
  GError* glibError = nullptr;
  const gboolean ok = secret_password_clear_sync(
      CredentialSchema(), nullptr, &glibError, "service", service.c_str(),
      "account", account.c_str(), nullptr);

  if (!ok && glibError != nullptr) {
    error = GlibErrorMessage(glibError, "libsecret delete failed");
    return false;
  }

  error.clear();
  return true;
#else
  error = "secure credential storage is not available on this platform";
  return false;
#endif
}

}  // namespace SecureCredentialStore
