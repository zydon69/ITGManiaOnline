#include "NetworkManager.h"

#include <ixwebsocket/IXHttpClient.h>
#include <ixwebsocket/IXNetSystem.h>
#include <ixwebsocket/IXUrlParser.h>
#include <ixwebsocket/IXUserAgent.h>
#include <ixwebsocket/IXWebSocket.h>

#include <algorithm>
#include <cctype>
#include <climits>
#include <cmath>
#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <ctime>
#include <limits>
#include <memory>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include "CryptManager.h"
#include "EnumHelper.h"
#include "IniFile.h"
#include "LuaManager.h"
#include "Preference.h"
#include "PrefsManager.h"
#include "ProductInfo.h"
#include "RageFile.h"
#include "RageFileDriverDeflate.h"
#include "RageFileManager.h"
#include "RageLog.h"
#include "RageTimer.h"
#include "RageUtil.h"
#include "SecureCredentialStore.h"
#include "SpecialFiles.h"
#include "StdString.h"
#include "ixwebsocket/IXHttp.h"
#include "ixwebsocket/IXWebSocketHttpHeaders.h"
#include "ixwebsocket/IXWebSocketMessage.h"
#include "ixwebsocket/IXWebSocketMessageType.h"
#include "ver.h"

NetworkManager* NETWORK =
    nullptr;  // global and accessible from anywhere in our program

namespace {
#ifndef ITGMANIA_HTTP_ALLOW_HOSTS_DEFAULT
#define ITGMANIA_HTTP_ALLOW_HOSTS_DEFAULT                         \
  "*.groovestats.com,*.itgmania.com,itgonline.fr,*.itgonline.fr," \
  "stepmaniaonline.net,www.stepmaniaonline.net,*.arrowcloud.dance"
#endif

#ifndef ITGMANIA_HTTP_PUBLIC_KEY_PINS_DEFAULT
#define ITGMANIA_HTTP_PUBLIC_KEY_PINS_DEFAULT                           \
  "itgonline.fr="                                                       \
  "660801b6fa3faba577853c89d1b6d908d75a00a4396259184b1a65dc1bcd1f60,*." \
  "itgonline.fr="                                                       \
  "660801b6fa3faba577853c89d1b6d908d75a00a4396259184b1a65dc1bcd1f60"
#endif

#ifndef ITGMANIA_HTTP_PUBLIC_KEY_PINS_BACKUP_DEFAULT
#define ITGMANIA_HTTP_PUBLIC_KEY_PINS_BACKUP_DEFAULT                    \
  "itgonline.fr="                                                       \
  "3349ce463a6f443f110a1764102bc52401b6f4f42a9971a9747b02214a9ef60a,*." \
  "itgonline.fr="                                                       \
  "3349ce463a6f443f110a1764102bc52401b6f4f42a9971a9747b02214a9ef60a"
#endif

// Keep the active post-renewal key alongside the long-lived primary and the
// offline standby key.  This overlap lets already-built clients survive a
// controlled certificate transition without weakening normal CA validation.
#ifndef ITGMANIA_HTTP_PUBLIC_KEY_PINS_ROTATION_DEFAULT
#define ITGMANIA_HTTP_PUBLIC_KEY_PINS_ROTATION_DEFAULT                    \
  "itgonline.fr="                                                         \
  "35833860b4386ecf9297b08d9d0f7398cda72253224bd88b7f7f894f5d46f50d,*." \
  "itgonline.fr="                                                         \
  "35833860b4386ecf9297b08d9d0f7398cda72253224bd88b7f7f894f5d46f50d"
#endif

constexpr const char* BUILT_IN_HTTP_ALLOW_HOSTS =
    ITGMANIA_HTTP_ALLOW_HOSTS_DEFAULT;
constexpr const char* REQUIRED_BUNDLED_ONLINE_ALLOW_HOSTS =
    "*.groovestats.com,*.itgmania.com,itgonline.fr,*.itgonline.fr,"
    "stepmaniaonline.net,www.stepmaniaonline.net,*.arrowcloud.dance";
constexpr const char* LEGACY_GROOVESTATS_QR_LOGIN_HOST =
    "qrlogin.groovestats.com";
constexpr int LEGACY_GROOVESTATS_QR_LOGIN_PORT = 3000;
constexpr const char* SIGNED_HTTP_SECURITY_OVERRIDE_PATH =
    "Save/ITGOnlineNetworkSecurity.ini";

constexpr std::size_t kMaxHostPatternLength = 253;
constexpr std::size_t kMaxHttpHeaderCount = 64;
constexpr std::size_t kMaxHttpHeaderNameLength = 128;
constexpr std::size_t kMaxHttpHeaderValueLength = 8192;
constexpr std::size_t kMaxQueryParameterCount = 128;
constexpr std::size_t kMaxQueryKeyLength = 256;
constexpr std::size_t kMaxQueryValueLength = 8192;
constexpr std::size_t kMaxCredentialPartLength = 256;
constexpr std::size_t kMaxMainThreadTaskQueue = 4096;
constexpr std::size_t kMaxTerminalMainThreadTaskQueue = 8192;
constexpr std::size_t kMaxHttpWorkerQueue = 256;
constexpr std::size_t kMaxDownloadWorkerQueue = 8;
constexpr std::size_t kMaxWebSocketWorkerQueue = 64;
constexpr int64_t kDefaultMaxHttpResponseBytes = 8LL * 1024LL * 1024LL;
constexpr int64_t kDefaultMaxDownloadBytes = 512LL * 1024LL * 1024LL;
constexpr int64_t kMaxDownloadBytes = 5LL * 1024LL * 1024LL * 1024LL;
constexpr std::size_t kMaxHttpRequestBodyBytes = 1024ULL * 1024ULL;
constexpr int64_t kDefaultMaxWebSocketMessageBytes = 1024LL * 1024LL;
constexpr int kDefaultDownloadTransferTimeoutSeconds = 30 * 60;
constexpr int kMinTimeoutSeconds = 1;
constexpr int kMaxTimeoutSeconds = 60 * 60;

std::atomic<bool> g_OnlineVerboseLogsEnabled{false};

void RefreshOnlineVerboseLogsPreference() {
  static time_t lastRead = 0;

  const time_t now = time(nullptr);
  if (now == lastRead) {
    return;
  }

  lastRead = now;
  g_OnlineVerboseLogsEnabled = false;

  if (PREFSMAN == nullptr) {
    return;
  }

  IniFile ini;
  if (!ini.ReadFile("Save/ThemePrefs.ini")) {
    return;
  }

  bool enabled = false;
  if (!ini.GetValue(PREFSMAN->m_sTheme, "ITGOnlineNetworkLogs", enabled)) {
    return;
  }

  g_OnlineVerboseLogsEnabled = enabled;
}

bool OnlineVerboseLogsEnabledFromThemePrefs() {
  return g_OnlineVerboseLogsEnabled.load();
}

void NetworkTrace(const char* fmt, ...) {
  if (LOG == nullptr || !OnlineVerboseLogsEnabledFromThemePrefs()) {
    return;
  }

  va_list args;
  va_start(args, fmt);
  char buffer[2048];
  vsnprintf(buffer, sizeof(buffer), fmt, args);
  va_end(args);
  LOG->Trace("%s", buffer);
}

void NetworkWarn(const char* fmt, ...) {
  if (LOG == nullptr) {
    return;
  }

  va_list args;
  va_start(args, fmt);
  char buffer[2048];
  vsnprintf(buffer, sizeof(buffer), fmt, args);
  va_end(args);
  LOG->Warn("%s", buffer);
}

std::string RedactUrlForLog(const std::string& url) {
  std::string protocol;
  std::string host;
  std::string path;
  std::string query;
  int port = 0;

  if (!ix::UrlParser::parse(url, protocol, host, path, query, port)) {
    return "<invalid-url>";
  }

  std::stringstream ss;
  ss << protocol << "://" << host;
  if (port > 0) {
    ss << ":" << port;
  }
  ss << path;
  if (!query.empty()) {
    ss << "?<redacted>";
  }
  return ss.str();
}

std::string RedactTextForLog(const std::string& value) {
  std::string text = value;
  for (char& c : text) {
    if (std::iscntrl(static_cast<unsigned char>(c))) {
      c = ' ';
    }
  }

  std::string lower = text;
  std::transform(
      lower.begin(), lower.end(), lower.begin(),
      [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  if (lower.find("bearer ") != std::string::npos ||
      lower.find("access_token") != std::string::npos ||
      lower.find("access-token") != std::string::npos ||
      lower.find("accesstoken") != std::string::npos ||
      lower.find("token=") != std::string::npos ||
      lower.find("token:") != std::string::npos ||
      lower.find("\"token\"") != std::string::npos ||
      lower.find("'token'") != std::string::npos ||
      lower.find("password=") != std::string::npos ||
      lower.find("password:") != std::string::npos ||
      lower.find("\"password\"") != std::string::npos ||
      lower.find("'password'") != std::string::npos ||
      lower.find("authorization:") != std::string::npos) {
    return "[redacted]";
  }

  constexpr size_t kMaxNetworkLogTextLength = 512;
  if (text.size() > kMaxNetworkLogTextLength) {
    text.resize(kMaxNetworkLogTextLength);
    text += "...[truncated]";
  }
  return text;
}

template <typename Fn>
bool WithLua(Fn fn) {
  if (LUA == nullptr) {
    return false;
  }

  Lua* L = LUA->Get();
  if (L == nullptr) {
    return false;
  }

  fn(L);
  LUA->Release(L);
  return true;
}

bool IsAsciiAlphaNum(char ch) {
  return std::isalnum(static_cast<unsigned char>(ch)) != 0;
}

bool IsSafeHostPattern(std::string pattern) {
  Trim(pattern);
  MakeLower(pattern);
  if (pattern.empty() || pattern.size() > kMaxHostPatternLength ||
      pattern.find("..") != std::string::npos ||
      pattern.find(':') != std::string::npos ||
      pattern.find('/') != std::string::npos ||
      pattern.find('\\') != std::string::npos ||
      pattern.find('*') !=
          (pattern.compare(0, 2, "*.") == 0 ? 0 : std::string::npos)) {
    return false;
  }

  if (pattern.compare(0, 2, "*.") == 0) {
    pattern.erase(0, 2);
  }

  if (pattern.empty() || pattern.front() == '.' || pattern.back() == '.') {
    return false;
  }

  std::vector<std::string> labels;
  split(pattern, ".", labels);
  for (const auto& label : labels) {
    if (label.empty() || label.front() == '-' || label.back() == '-') {
      return false;
    }
    for (const char ch : label) {
      if (!IsAsciiAlphaNum(ch) && ch != '-') {
        return false;
      }
    }
  }
  return true;
}

std::string NormalizeHostList(
    const std::string& rawValue, bool includeRequiredHosts) {
  std::vector<std::string> entries;
  split(rawValue, ",", entries);

  std::set<std::string> normalizedHosts;
  for (auto entry : entries) {
    Trim(entry);
    MakeLower(entry);
    if (entry.empty()) {
      continue;
    }
    if (!IsSafeHostPattern(entry)) {
      NetworkWarn(
          "Ignoring invalid HttpAllowHosts pattern '%s'", entry.c_str());
      continue;
    }
    normalizedHosts.insert(entry);
  }

  if (includeRequiredHosts) {
    std::vector<std::string> required;
    split(REQUIRED_BUNDLED_ONLINE_ALLOW_HOSTS, ",", required);
    for (auto entry : required) {
      Trim(entry);
      MakeLower(entry);
      if (IsSafeHostPattern(entry)) {
        normalizedHosts.insert(entry);
      }
    }
  }

  std::string result;
  for (const auto& host : normalizedHosts) {
    if (!result.empty()) {
      result += ",";
    }
    result += host;
  }
  return result;
}

bool IsHexSha256(const std::string& value) {
  if (value.size() != 64) {
    return false;
  }
  for (const char ch : value) {
    if (!std::isxdigit(static_cast<unsigned char>(ch))) {
      return false;
    }
  }
  return true;
}

std::string NormalizePublicKeyPins(const std::string& rawValue) {
  std::vector<std::string> entries;
  split(rawValue, ",", entries);

  std::vector<std::string> normalizedPins;
  for (auto entry : entries) {
    Trim(entry);
    if (entry.empty()) {
      continue;
    }

    const auto separator = entry.find('=');
    if (separator == std::string::npos) {
      NetworkWarn("Ignoring invalid HttpPublicKeyPins entry without host");
      continue;
    }

    std::string host = entry.substr(0, separator);
    std::string pin = entry.substr(separator + 1);
    Trim(host);
    Trim(pin);
    MakeLower(host);
    MakeLower(pin);

    if (!IsSafeHostPattern(host) || !IsHexSha256(pin)) {
      NetworkWarn(
          "Ignoring invalid HttpPublicKeyPins entry for host '%s'",
          host.c_str());
      continue;
    }

    normalizedPins.push_back(host + "=" + pin);
  }

  return join(",", normalizedPins);
}

bool IsSafeHttpHeaderName(const std::string& name) {
  if (name.empty() || name.size() > kMaxHttpHeaderNameLength) {
    return false;
  }
  for (const char ch : name) {
    const unsigned char uch = static_cast<unsigned char>(ch);
    if (uch <= 32 || uch >= 127 ||
        std::string("()<>@,;:\\\"/[]?={}").find(ch) != std::string::npos) {
      return false;
    }
  }
  return true;
}

bool IsSafeHeaderValue(const std::string& value) {
  if (value.size() > kMaxHttpHeaderValueLength) {
    return false;
  }
  for (const char ch : value) {
    if (ch == '\r' || ch == '\n' || ch == '\0') {
      return false;
    }
  }
  return true;
}

bool IsBoundedPlainValue(
    const std::string& value, std::size_t maxLength, bool allowEmpty) {
  if ((!allowEmpty && value.empty()) || value.size() > maxLength) {
    return false;
  }
  for (const char ch : value) {
    if (static_cast<unsigned char>(ch) < 32 || ch == 127) {
      return false;
    }
  }
  return true;
}

int ClampTimeoutSeconds(lua_State* L, int stackIndex, const char* fieldName) {
  if (!lua_isnumber(L, stackIndex)) {
    luaL_error(L, "%s must be an integer", fieldName);
  }
  const lua_Number rawValue = lua_tonumber(L, stackIndex);
  if (!std::isfinite(static_cast<double>(rawValue))) {
    luaL_error(L, "%s must be finite", fieldName);
  }
  if (rawValue < 0) {
    return -1;
  }
  if (rawValue < kMinTimeoutSeconds) {
    return kMinTimeoutSeconds;
  }
  if (rawValue > kMaxTimeoutSeconds) {
    return kMaxTimeoutSeconds;
  }
  return static_cast<int>(rawValue);
}

int64_t ClampNonNegativeInt64(
    lua_State* L, int stackIndex, const char* fieldName, int64_t maxValue) {
  if (!lua_isnumber(L, stackIndex)) {
    luaL_error(L, "%s must be an integer", fieldName);
  }
  const lua_Number rawValue = lua_tonumber(L, stackIndex);
  if (!std::isfinite(static_cast<double>(rawValue)) || rawValue < 0) {
    luaL_error(L, "%s must be a finite non-negative integer", fieldName);
  }
  if (rawValue > static_cast<lua_Number>(maxValue)) {
    return maxValue;
  }
  return static_cast<int64_t>(rawValue);
}

ix::HttpResponsePtr MakeBlockedHttpResponse(const std::string& url) {
  return std::make_shared<ix::HttpResponse>(
      0, std::string(), ix::HttpErrorCode::Invalid, ix::WebSocketHttpHeaders(),
      std::string(), "access to " + RedactUrlForLog(url) + " is not allowed", 0,
      0);
}

ix::HttpResponsePtr MakeCancelledHttpResponse(const std::string& message) {
  return std::make_shared<ix::HttpResponse>(
      0, std::string(), ix::HttpErrorCode::Cancelled,
      ix::WebSocketHttpHeaders(), std::string(), message, 0, 0);
}

bool NormalizeHttpResponseBody(
    const ix::HttpResponsePtr& response, int64_t maxResponseBytes) {
  if (!response) {
    return false;
  }

  const int64_t maxBytes =
      maxResponseBytes >= 0 ? maxResponseBytes : kDefaultMaxHttpResponseBytes;
  if (maxBytes >= 0 &&
      response->body.size() > static_cast<std::size_t>(maxBytes)) {
    response->errorCode = ix::HttpErrorCode::CannotReadBody;
    response->errorMsg = "HTTP response body exceeded maximum allowed size";
    response->body.clear();
    return false;
  }

  if (response->body.size() >= 2 &&
      static_cast<unsigned char>(response->body[0]) == 0x1f &&
      static_cast<unsigned char>(response->body[1]) == 0x8b) {
    std::string decodedBody;
    std::string gunzipError;
    if (GunzipStringBounded(
            response->body, decodedBody, gunzipError,
            static_cast<std::size_t>(maxBytes))) {
      response->body = decodedBody;
    } else {
      NetworkWarn(
          "Failed to gunzip HTTP response body: %s", gunzipError.c_str());
      response->errorCode = ix::HttpErrorCode::Gzip;
      response->errorMsg = "Could not decode bounded HTTP gzip response";
      response->body.clear();
      return false;
    }
  }
  return true;
}

std::string BuildDefaultPublicKeyPins() {
  std::string primary = ITGMANIA_HTTP_PUBLIC_KEY_PINS_DEFAULT;
  std::string backup = ITGMANIA_HTTP_PUBLIC_KEY_PINS_BACKUP_DEFAULT;
  std::string rotation = ITGMANIA_HTTP_PUBLIC_KEY_PINS_ROTATION_DEFAULT;
  Trim(primary);
  Trim(backup);
  Trim(rotation);

  std::vector<std::string> pinSets;
  if (!primary.empty()) {
    pinSets.push_back(primary);
  }
  if (!rotation.empty()) {
    pinSets.push_back(rotation);
  }
  if (!backup.empty()) {
    pinSets.push_back(backup);
  }
  return join(",", pinSets);
}

const std::string BUILT_IN_HTTP_PUBLIC_KEY_PINS = BuildDefaultPublicKeyPins();

bool ParseSignedOverrideFile(
    const std::string& contents, std::string& pinsOut,
    std::string& allowHostsOut) {
  std::vector<std::string> lines;
  split(contents, "\n", lines);

  for (const auto& rawLine : lines) {
    std::string line = rawLine;
    Trim(line);

    if (line.empty() || line[0] == '#' || line[0] == ';') {
      continue;
    }

    const auto separator = line.find('=');
    if (separator == std::string::npos) {
      continue;
    }

    std::string key = line.substr(0, separator);
    std::string value = line.substr(separator + 1);
    Trim(key);
    Trim(value);
    MakeLower(key);

    if (value.empty()) {
      continue;
    }

    if (key == "http_public_key_pins") {
      pinsOut = value;
      continue;
    }

    if (key == "http_allow_hosts") {
      allowHostsOut = value;
      continue;
    }
  }

  return !pinsOut.empty() || !allowHostsOut.empty();
}

bool LoadSignedNetworkSecurityOverride(
    std::string& pinsOut, std::string& allowHostsOut) {
  const std::string overridePath = SIGNED_HTTP_SECURITY_OVERRIDE_PATH;
  const std::string signaturePath = overridePath + SIGNATURE_APPEND;

  if (FILEMAN == nullptr) {
    NetworkWarn(
        "Signed network security override ignored: FILEMAN is unavailable");
    return false;
  }

  if (!FILEMAN->DoesFileExist(overridePath) &&
      !FILEMAN->DoesFileExist(signaturePath)) {
    return false;
  }

  if (!FILEMAN->DoesFileExist(overridePath) ||
      !FILEMAN->DoesFileExist(signaturePath)) {
    NetworkWarn(
        "Signed network security override ignored: both %s and %s must exist",
        overridePath.c_str(), signaturePath.c_str());
    return false;
  }

  if (!CryptManager::VerifyFileWithFile(overridePath, signaturePath)) {
    NetworkWarn(
        "Signed network security override verification failed for %s",
        overridePath.c_str());
    return false;
  }

  std::string contents;
  if (!GetFileContents(overridePath, contents)) {
    NetworkWarn(
        "Signed network security override could not be read from %s",
        overridePath.c_str());
    return false;
  }

  if (!ParseSignedOverrideFile(contents, pinsOut, allowHostsOut)) {
    NetworkWarn(
        "Signed network security override file %s does not define any "
        "http_public_key_pins/http_allow_hosts value",
        overridePath.c_str());
    return false;
  }

  return true;
}

bool IsSafeDownloadFileName(const std::string& value) {
  if (value.empty() || value.size() > 128 || value == "." || value == ".." ||
      value.back() == '.' || value.back() == ' ') {
    return false;
  }

  std::string base = value;
  const auto dot = base.find('.');
  if (dot != std::string::npos) {
    base.erase(dot);
  }
  MakeLower(base);
  static const std::set<std::string> kReservedWindowsNames{
      "con",  "prn",  "aux",  "nul",  "com1", "com2", "com3", "com4",
      "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3",
      "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"};
  if (kReservedWindowsNames.count(base) != 0) {
    return false;
  }

  for (const char ch : value) {
    if (ch == '/' || ch == '\\' || ch == ':' ||
        static_cast<unsigned char>(ch) < 32 ||
        static_cast<unsigned char>(ch) == 127) {
      return false;
    }
  }

  return value.find("..") == std::string::npos;
}

bool NormalizeOnlineArchivePaths(
    std::string& archivePath, std::string& targetPath) {
  FixSlashesInPlace(archivePath);
  FixSlashesInPlace(targetPath);
  CollapsePath(archivePath, true);
  CollapsePath(targetPath, true);

  static const std::string downloadsRoot = "/Downloads/";
  static const std::string quarantineRoot = "/Songs/__OnlineDownload_";
  if (archivePath.size() <= downloadsRoot.size() ||
      CompareNoCase(
          archivePath.substr(0, downloadsRoot.size()), downloadsRoot) != 0) {
    return false;
  }
  const std::string archiveName = archivePath.substr(downloadsRoot.size());
  if (!IsSafeDownloadFileName(archiveName) ||
      archiveName.compare(0, 11, "itg-online-") != 0 ||
      archiveName.size() < 4 ||
      CompareNoCase(archiveName.substr(archiveName.size() - 4), ".zip") != 0) {
    return false;
  }

  if (!targetPath.empty() && targetPath.back() == '/') {
    targetPath.pop_back();
  }
  if (targetPath.size() <= quarantineRoot.size() ||
      CompareNoCase(
          targetPath.substr(0, quarantineRoot.size()), quarantineRoot) != 0) {
    return false;
  }
  const std::string quarantineName =
      targetPath.substr(std::string("/Songs/").size());
  if (!IsSafeZipEntryPath(quarantineName)) {
    return false;
  }
  targetPath.push_back('/');

  return true;
}

bool IsLowerHexSha256(const std::string& value) {
  return value.empty() ||
         (value.size() == 64 &&
          std::all_of(value.begin(), value.end(), [](unsigned char ch) {
            return std::isdigit(ch) != 0 || (ch >= 'a' && ch <= 'f');
          }));
}

bool IsProductionItgOnlineHost(const std::string& host) {
  return host == "itgonline.fr" || EndsWith(host, ".itgonline.fr");
}

bool TlsBackendLikelySupportsPinning() {
#if defined(__APPLE__)
  // IXSocketAppleSSL rejects a pinned connection when it cannot enforce the
  // configured public key hash. Treat that backend as fail-closed.
  return true;
#else
  const std::string userAgent = ix::userAgent();
  return userAgent.find("ssl/OpenSSL") != std::string::npos ||
         userAgent.find("ssl/mbedtls") != std::string::npos;
#endif
}
}  // namespace

Preference<bool> NetworkManager::httpEnabled(
    "HttpEnabled", true, nullptr, PreferenceType::Immutable);
Preference<std::string> NetworkManager::httpAllowHosts(
    "HttpAllowHosts", BUILT_IN_HTTP_ALLOW_HOSTS, nullptr,
    PreferenceType::Immutable);
Preference<std::string> NetworkManager::httpDenyHosts("HttpDenyHosts", "");
Preference<std::string> NetworkManager::httpPublicKeyPins(
    "HttpPublicKeyPins", BUILT_IN_HTTP_PUBLIC_KEY_PINS, nullptr,
    PreferenceType::Immutable);

static const char* HttpErrorCodeNames[] = {
    "Blocked",
    "UnknownError",
    "FileError",
    "CannotConnect",
    "Timeout",
    "Gzip",
    "UrlMalformed",
    "CannotCreateSocket",
    "SendError",
    "ReadError",
    "CannotReadStatusLine",
    "MissingStatus",
    "HeaderParsingError",
    "MissingLocation",
    "TooManyRedirects",
    "ChunkReadError",
    "CannotReadBody",
    "Cancelled",
};
XToString(HttpErrorCode);
StringToX(HttpErrorCode);
LuaXType(HttpErrorCode);

static const char* WebSocketMessageTypeNames[] = {
    "Message",
    "Open",
    "Close",
    "Error",
};

static constexpr int kBaseMainThreadTasksPerUpdate = 256;
static constexpr float kBaseMainThreadTaskSecondsPerUpdate = 0.004f;
static constexpr int kBacklogMainThreadTasksPerUpdate = 512;
static constexpr float kBacklogMainThreadTaskSecondsPerUpdate = 0.008f;
static constexpr std::size_t kBacklogAdaptiveThreshold = 8;
static std::atomic<std::uint64_t> g_LuaHttpCallbackStateIds{0};
static std::atomic<std::uint64_t> g_LuaWebSocketCallbackStateIds{0};
static std::atomic<std::uint64_t> g_WebSocketHandleIds{0};
static std::atomic<std::uint64_t> g_DownloadTempFileIds{0};

void SecureWipe(std::string& value) {
  volatile char* bytes = value.empty() ? nullptr : value.data();
  for (std::size_t i = 0; bytes != nullptr && i < value.size(); ++i) {
    bytes[i] = 0;
  }
  value.clear();
  value.shrink_to_fit();
}

struct LuaHttpCallbackState {
  std::uint64_t id{0};
  std::string url;
  std::atomic<bool> active{true};
  std::atomic<bool> canceled{false};
  std::atomic<bool> progressCancelRequested{false};
  std::atomic<bool> progressQueued{false};
  std::atomic<int64_t> latestProgressCurrent{0};
  std::atomic<int64_t> latestProgressTotal{0};
  int progressRef = LUA_NOREF;
  int responseRef = LUA_NOREF;
  std::atomic<bool> refsReleased{false};
  std::atomic<bool> releaseDeferred{false};
};

struct LuaWebSocketCallbackState {
  std::uint64_t id{0};
  std::string url;
  std::atomic<bool> active{true};
  int messageRef = LUA_NOREF;
  std::atomic<bool> refReleased{false};
  std::atomic<bool> releaseDeferred{false};
};

std::mutex g_LuaCallbackStateMutex;
std::unordered_map<std::uint64_t, std::shared_ptr<LuaHttpCallbackState>>
    g_LuaHttpCallbackStates;
std::unordered_map<std::uint64_t, std::shared_ptr<LuaWebSocketCallbackState>>
    g_LuaWebSocketCallbackStates;
std::mutex g_DeferredLuaCallbackReleaseMutex;
std::vector<std::shared_ptr<LuaHttpCallbackState>>
    g_DeferredLuaHttpCallbackReleases;
std::vector<std::shared_ptr<LuaWebSocketCallbackState>>
    g_DeferredLuaWebSocketCallbackReleases;

void RegisterLuaHttpCallbackState(
    const std::shared_ptr<LuaHttpCallbackState>& state) {
  std::lock_guard<std::mutex> lock(g_LuaCallbackStateMutex);
  g_LuaHttpCallbackStates[state->id] = state;
}

void RegisterLuaWebSocketCallbackState(
    const std::shared_ptr<LuaWebSocketCallbackState>& state) {
  std::lock_guard<std::mutex> lock(g_LuaCallbackStateMutex);
  g_LuaWebSocketCallbackStates[state->id] = state;
}

void ReleaseLuaHttpCallbackRefs(
    lua_State* L, const std::shared_ptr<LuaHttpCallbackState>& state) {
  if (!state || state->refsReleased.load()) {
    return;
  }

  state->active = false;
  if (L == nullptr) {
    NetworkTrace(
        "ITG Online NetworkTrace: http_refs_release_deferred id=%llu url=%s",
        static_cast<unsigned long long>(state->id),
        RedactUrlForLog(state->url).c_str());
    return;
  }
  if (state->refsReleased.exchange(true)) {
    return;
  }

  if (state->progressRef != LUA_NOREF) {
    luaL_unref(L, LUA_REGISTRYINDEX, state->progressRef);
  }
  state->progressRef = LUA_NOREF;
  if (state->responseRef != LUA_NOREF) {
    luaL_unref(L, LUA_REGISTRYINDEX, state->responseRef);
  }
  state->responseRef = LUA_NOREF;
  std::lock_guard<std::mutex> lock(g_LuaCallbackStateMutex);
  g_LuaHttpCallbackStates.erase(state->id);
}

void ReleaseLuaWebSocketCallbackRef(
    lua_State* L, const std::shared_ptr<LuaWebSocketCallbackState>& state) {
  if (!state || state->refReleased.load()) {
    return;
  }

  state->active = false;
  if (L == nullptr) {
    NetworkTrace(
        "ITG Online NetworkTrace: websocket_ref_release_deferred id=%llu "
        "url=%s",
        static_cast<unsigned long long>(state->id),
        RedactUrlForLog(state->url).c_str());
    return;
  }
  if (state->refReleased.exchange(true)) {
    return;
  }

  if (state->messageRef != LUA_NOREF) {
    luaL_unref(L, LUA_REGISTRYINDEX, state->messageRef);
  }
  state->messageRef = LUA_NOREF;
  std::lock_guard<std::mutex> lock(g_LuaCallbackStateMutex);
  g_LuaWebSocketCallbackStates.erase(state->id);
}

void ReleaseAllLuaCallbackRefs(lua_State* L) {
  std::vector<std::shared_ptr<LuaHttpCallbackState>> httpStates;
  std::vector<std::shared_ptr<LuaWebSocketCallbackState>> webSocketStates;
  {
    std::lock_guard<std::mutex> lock(g_LuaCallbackStateMutex);
    for (const auto& entry : g_LuaHttpCallbackStates) {
      httpStates.push_back(entry.second);
    }
    for (const auto& entry : g_LuaWebSocketCallbackStates) {
      webSocketStates.push_back(entry.second);
    }
  }
  for (const auto& state : httpStates) {
    ReleaseLuaHttpCallbackRefs(L, state);
  }
  for (const auto& state : webSocketStates) {
    ReleaseLuaWebSocketCallbackRef(L, state);
  }
}

void ForgetAllLuaCallbackStates() {
  {
    std::lock_guard<std::mutex> lock(g_LuaCallbackStateMutex);
    g_LuaHttpCallbackStates.clear();
    g_LuaWebSocketCallbackStates.clear();
  }
  std::lock_guard<std::mutex> deferredLock(g_DeferredLuaCallbackReleaseMutex);
  g_DeferredLuaHttpCallbackReleases.clear();
  g_DeferredLuaWebSocketCallbackReleases.clear();
}

void DeferLuaHttpCallbackRefRelease(
    const std::shared_ptr<LuaHttpCallbackState>& state) {
  if (!state || state->refsReleased.load() ||
      state->releaseDeferred.exchange(true)) {
    return;
  }
  state->active = false;
  std::lock_guard<std::mutex> lock(g_DeferredLuaCallbackReleaseMutex);
  g_DeferredLuaHttpCallbackReleases.push_back(state);
}

void DeferLuaWebSocketCallbackRefRelease(
    const std::shared_ptr<LuaWebSocketCallbackState>& state) {
  if (!state || state->refReleased.load() ||
      state->releaseDeferred.exchange(true)) {
    return;
  }
  state->active = false;
  std::lock_guard<std::mutex> lock(g_DeferredLuaCallbackReleaseMutex);
  g_DeferredLuaWebSocketCallbackReleases.push_back(state);
}

void DrainDeferredLuaCallbackRefReleases() {
  std::vector<std::shared_ptr<LuaHttpCallbackState>> httpStates;
  std::vector<std::shared_ptr<LuaWebSocketCallbackState>> webSocketStates;
  {
    std::lock_guard<std::mutex> lock(g_DeferredLuaCallbackReleaseMutex);
    httpStates.swap(g_DeferredLuaHttpCallbackReleases);
    webSocketStates.swap(g_DeferredLuaWebSocketCallbackReleases);
  }
  if (httpStates.empty() && webSocketStates.empty()) {
    return;
  }

  const bool released = WithLua([&httpStates, &webSocketStates](Lua* L) {
    for (const auto& state : httpStates) {
      state->releaseDeferred = false;
      ReleaseLuaHttpCallbackRefs(L, state);
    }
    for (const auto& state : webSocketStates) {
      state->releaseDeferred = false;
      ReleaseLuaWebSocketCallbackRef(L, state);
    }
  });
  if (released) {
    NetworkTrace(
        "ITG Online NetworkTrace: deferred_lua_callback_refs_released http=%zu "
        "websocket=%zu",
        httpStates.size(), webSocketStates.size());
    return;
  }

  std::lock_guard<std::mutex> lock(g_DeferredLuaCallbackReleaseMutex);
  g_DeferredLuaHttpCallbackReleases.insert(
      g_DeferredLuaHttpCallbackReleases.end(), httpStates.begin(),
      httpStates.end());
  g_DeferredLuaWebSocketCallbackReleases.insert(
      g_DeferredLuaWebSocketCallbackReleases.end(), webSocketStates.begin(),
      webSocketStates.end());
}

static bool HostMatchesPattern(
    const std::string& host, const std::string& pattern) {
  if (pattern.empty()) {
    return false;
  }

  if (pattern.substr(0, 2) == "*." && host.length() >= pattern.length()) {
    size_t pos = host.length() - pattern.length() + 1;
    return host.substr(pos) == pattern.substr(1);
  }

  return host == pattern;
}

static bool PublicKeyPinsCoverHost(
    const std::string& configuredPins, const std::string& host) {
  std::vector<std::string> entries;
  split(configuredPins, ",", entries);

  for (auto entry : entries) {
    Trim(entry);
    const auto separator = entry.find('=');
    if (separator == std::string::npos) {
      continue;
    }

    std::string pinnedHost = entry.substr(0, separator);
    Trim(pinnedHost);
    MakeLower(pinnedHost);
    if (HostMatchesPattern(host, pinnedHost)) {
      return true;
    }
  }

  return false;
}

static const std::vector<std::string>& CachedHostList(
    const std::string& rawValue, std::string& cachedRawValue,
    std::vector<std::string>& cachedHosts) {
  std::string normalized = rawValue;
  MakeLower(normalized);

  if (normalized != cachedRawValue) {
    cachedRawValue = normalized;
    cachedHosts.clear();
    split(cachedRawValue, ",", cachedHosts);
    for (auto it = cachedHosts.begin(); it != cachedHosts.end();) {
      auto& host = *it;
      Trim(host);
      if (host.empty() || !IsSafeHostPattern(host)) {
        it = cachedHosts.erase(it);
      } else {
        ++it;
      }
    }
  }

  return cachedHosts;
}

XToString(WebSocketMessageType);
StringToX(WebSocketMessageType);
LuaXType(WebSocketMessageType);

static const char* IxWebSocketMessageTypeName(ix::WebSocketMessageType type) {
  switch (type) {
    case ix::WebSocketMessageType::Message:
      return "Message";
    case ix::WebSocketMessageType::Open:
      return "Open";
    case ix::WebSocketMessageType::Close:
      return "Close";
    case ix::WebSocketMessageType::Error:
      return "Error";
    case ix::WebSocketMessageType::Ping:
      return "Ping";
    case ix::WebSocketMessageType::Pong:
      return "Pong";
    case ix::WebSocketMessageType::Fragment:
      return "Fragment";
  }
  return "Unknown";
}

static bool IsExpectedInactiveWebSocketTerminalMessage(
    ix::WebSocketMessageType type) {
  return type == ix::WebSocketMessageType::Close ||
         type == ix::WebSocketMessageType::Error;
}

NetworkManager::NetworkManager() : httpClient(true), downloadClient(true) {
  NetworkTrace("ITG Online NetworkTrace: network_manager_ctor_begin");
  ix::initNetSystem();

  // Register with Lua.
  WithLua([this](Lua* L) {
    this->PushSelf(L);
    lua_setglobal(L, "NETWORK");
  });

  RageFile f;
  if (f.Open(SpecialFiles::CA_BUNDLE_PATH)) {
    std::string data;
    f.Read(data);
    f.Close();

    this->tlsOptions.caFile = data;
  } else {
    NetworkWarn(
        "Reading '%s' failed: %s", SpecialFiles::CA_BUNDLE_PATH.c_str(),
        f.GetError().c_str());
  }

  // Public-key pins are a trust root.  Never let a stale or locally edited
  // Preferences.ini replace the compiled set; emergency rotations must use
  // the signed override file below.
  std::string configuredPins = BUILT_IN_HTTP_PUBLIC_KEY_PINS;
  std::string signedPins;
  std::string signedAllowHosts;

  if (LoadSignedNetworkSecurityOverride(signedPins, signedAllowHosts)) {
    if (!signedPins.empty()) {
      const std::string normalizedSignedPins =
          NormalizePublicKeyPins(signedPins);
      if (!normalizedSignedPins.empty()) {
        configuredPins = normalizedSignedPins;
        NetworkWarn("Loaded signed HttpPublicKeyPins override from Save/");
      } else {
        NetworkWarn("Signed HttpPublicKeyPins override ignored: no valid pins");
      }
    }

    if (!signedAllowHosts.empty()) {
      const std::string normalizedSignedAllowHosts =
          NormalizeHostList(signedAllowHosts, true);
      if (!normalizedSignedAllowHosts.empty()) {
        this->httpAllowHosts.Set(normalizedSignedAllowHosts);
        NetworkWarn("Loaded signed HttpAllowHosts override from Save/");
      } else {
        NetworkWarn(
            "Signed HttpAllowHosts override ignored: no valid host patterns");
      }
    }
  }

  Trim(configuredPins);
  if (configuredPins.empty()) {
    configuredPins = BUILT_IN_HTTP_PUBLIC_KEY_PINS;
  }

  if (configuredPins != BUILT_IN_HTTP_PUBLIC_KEY_PINS) {
    NetworkWarn(
        "HttpPublicKeyPins override active. Ensure emergency pin rotation "
        "value "
        "is trusted and distributed securely.");
  }

  this->tlsOptions.publicKeySha256Pins = configuredPins;
  this->tlsBackendEnforcesPublicKeyPins = TlsBackendLikelySupportsPinning();
  if (!configuredPins.empty()) {
    if (!this->tlsBackendEnforcesPublicKeyPins) {
      NetworkWarn(
          "HttpPublicKeyPins are configured, but this IXWebSocket TLS backend "
          "appears not to enforce public key pinning. Rebuild with a "
          "pinning-capable backend for strict trust guarantees.");
    } else {
      NetworkTrace(
          "HttpPublicKeyPins are configured and TLS backend reports pinning "
          "support via user agent: %s",
          ix::userAgent().c_str());
    }
  }
  this->httpClient.setTLSOptions(this->tlsOptions);
  this->downloadClient.setTLSOptions(this->tlsOptions);

  this->ClearDownloads();

  this->httpWorker = std::thread(&NetworkManager::RunHttpWorker, this);
  this->downloadWorker = std::thread(&NetworkManager::RunDownloadWorker, this);
  this->webSocketWorker =
      std::thread(&NetworkManager::RunWebSocketWorker, this);
  NetworkTrace("ITG Online NetworkTrace: network_manager_ctor_end");
}

NetworkManager::~NetworkManager() {
  NetworkTrace("ITG Online NetworkTrace: network_manager_dtor_begin");
  this->CloseAllWebSockets();
  this->StopWorkers();
  this->DrainMainThreadTasks();
  if (!WithLua([](Lua* L) { ReleaseAllLuaCallbackRefs(L); })) {
    // The Lua registry has already been destroyed, so its references no
    // longer own any objects.
    NetworkTrace(
        "ITG Online NetworkTrace: lua_registry_unavailable_during_shutdown");
  }
  ForgetAllLuaCallbackStates();
  this->ClearMainThreadTasks();

  // Unregister with Lua after all network callbacks have been cancelled.
  if (LUA != nullptr) {
    LUA->UnsetGlobal("NETWORK");
  }

  // Set the status to uninitialized.
  ix::uninitNetSystem();
  NetworkTrace("ITG Online NetworkTrace: network_manager_dtor_end");
}

void NetworkManager::CloseAllWebSockets() { CloseAllWebSocketsInternal(false); }

void NetworkManager::CloseAllWebSocketsFromLua() {
  CloseAllWebSocketsInternal(true);
}

void NetworkManager::CloseAllWebSocketsInternal(bool calledFromLua) {
  NetworkTrace(
      "ITG Online NetworkTrace: close_all_websockets_begin calledFromLua=%d",
      calledFromLua ? 1 : 0);
  // Drop queued websocket starts so no new connections come up after cleanup.
  {
    std::lock_guard<std::mutex> lock(this->webSocketWorkerMutex);
    this->webSocketWorkerQueue = {};
  }

  // Stop all active websocket connections without aggressively clearing.
  std::vector<WebSocketHandlePtr> webSocketHandlesCopy;
  {
    std::lock_guard<std::mutex> lock(this->webSocketHandlesMutex);
    for (auto it = this->webSocketHandles.begin();
         it != this->webSocketHandles.end();) {
      if (auto handle = it->lock()) {
        webSocketHandlesCopy.push_back(handle);
        ++it;
      } else {
        it = this->webSocketHandles.erase(it);
      }
    }
  }

  for (auto& handle : webSocketHandlesCopy) {
    handle->CloseSocket(calledFromLua);
  }
  NetworkTrace(
      "ITG Online NetworkTrace: close_all_websockets_end calledFromLua=%d "
      "handles=%zu",
      calledFromLua ? 1 : 0, webSocketHandlesCopy.size());
}

void NetworkManager::RunHttpWorker() {
  while (true) {
    std::function<void()> task;

    {
      std::unique_lock<std::mutex> lock(this->httpWorkerMutex);
      this->httpWorkerCv.wait(lock, [this] {
        return this->shutdownWorkers.load() || !this->httpWorkerQueue.empty();
      });

      if (this->shutdownWorkers.load() && this->httpWorkerQueue.empty()) {
        return;
      }

      if (this->shutdownWorkers.load()) {
        std::queue<std::function<void()>> emptyQueue;
        this->httpWorkerQueue.swap(emptyQueue);
        return;
      }

      task = std::move(this->httpWorkerQueue.front());
      this->httpWorkerQueue.pop();
    }

    task();
  }
}

void NetworkManager::RunDownloadWorker() {
  while (true) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(this->downloadWorkerMutex);
      this->downloadWorkerCv.wait(lock, [this] {
        return this->shutdownWorkers.load() ||
               !this->downloadWorkerQueue.empty();
      });
      if (this->shutdownWorkers.load() && this->downloadWorkerQueue.empty()) {
        return;
      }
      if (this->shutdownWorkers.load()) {
        std::queue<std::function<void()>> emptyQueue;
        this->downloadWorkerQueue.swap(emptyQueue);
        return;
      }
      task = std::move(this->downloadWorkerQueue.front());
      this->downloadWorkerQueue.pop();
    }
    task();
  }
}

void NetworkManager::RunWebSocketWorker() {
  while (true) {
    std::function<void()> task;

    {
      std::unique_lock<std::mutex> lock(this->webSocketWorkerMutex);
      this->webSocketWorkerCv.wait(lock, [this] {
        return this->shutdownWorkers.load() ||
               !this->webSocketWorkerQueue.empty();
      });

      if (this->shutdownWorkers.load() && this->webSocketWorkerQueue.empty()) {
        return;
      }

      if (this->shutdownWorkers.load()) {
        std::queue<std::function<void()>> emptyQueue;
        this->webSocketWorkerQueue.swap(emptyQueue);
        return;
      }

      task = std::move(this->webSocketWorkerQueue.front());
      this->webSocketWorkerQueue.pop();
    }

    task();
  }
}

void NetworkManager::StopWorkers() {
  this->shutdownWorkers = true;
  this->CancelActiveHttpRequests();

  {
    std::lock_guard<std::mutex> lock(this->httpWorkerMutex);
    std::queue<std::function<void()>> emptyQueue;
    this->httpWorkerQueue.swap(emptyQueue);
  }
  {
    std::lock_guard<std::mutex> lock(this->downloadWorkerMutex);
    std::queue<std::function<void()>> emptyQueue;
    this->downloadWorkerQueue.swap(emptyQueue);
  }
  {
    std::lock_guard<std::mutex> lock(this->webSocketWorkerMutex);
    std::queue<std::function<void()>> emptyQueue;
    this->webSocketWorkerQueue.swap(emptyQueue);
  }

  this->httpWorkerCv.notify_one();
  this->downloadWorkerCv.notify_one();
  this->webSocketWorkerCv.notify_one();

  if (this->httpWorker.joinable()) {
    this->httpWorker.join();
  }
  if (this->downloadWorker.joinable()) {
    this->downloadWorker.join();
  }

  if (this->webSocketWorker.joinable()) {
    this->webSocketWorker.join();
  }
}

void NetworkManager::CancelActiveHttpRequests() {
  std::lock_guard<std::mutex> lock(this->activeHttpRequestsMutex);
  for (auto it = this->activeHttpRequests.begin();
       it != this->activeHttpRequests.end();) {
    if (auto request = it->lock()) {
      request->cancel = true;
      ++it;
    } else {
      it = this->activeHttpRequests.erase(it);
    }
  }
}

void NetworkManager::ClearMainThreadTasks() {
  std::size_t droppedTasks = 0;
  {
    std::lock_guard<std::mutex> lock(this->mainThreadTaskMutex);
    droppedTasks = this->mainThreadTaskQueue.size();
    std::queue<std::function<void()>> emptyQueue;
    this->mainThreadTaskQueue.swap(emptyQueue);
  }

  if (droppedTasks > 0) {
    NetworkWarn(
        "Network shutdown dropped %zu queued main-thread task(s)",
        droppedTasks);
  }
}

void NetworkManager::DrainMainThreadTasks() {
  std::size_t drainedTasks = 0;
  while (true) {
    std::function<void()> task;
    {
      std::lock_guard<std::mutex> lock(this->mainThreadTaskMutex);
      if (this->mainThreadTaskQueue.empty()) {
        break;
      }

      task = std::move(this->mainThreadTaskQueue.front());
      this->mainThreadTaskQueue.pop();
    }

    task();
    ++drainedTasks;
  }
  if (drainedTasks > 0) {
    NetworkTrace(
        "ITG Online NetworkTrace: drain_main_thread_tasks count=%zu",
        drainedTasks);
  }
}

bool NetworkManager::EnqueueMainThreadTask(
    std::function<void()> task, bool terminal) {
  if (this->shutdownWorkers.load()) {
    NetworkTrace(
        "ITG Online NetworkTrace: enqueue_main_thread_task_skipped "
        "reason=shutdown");
    return false;
  }

  std::lock_guard<std::mutex> lock(this->mainThreadTaskMutex);
  const std::size_t limit =
      terminal ? kMaxTerminalMainThreadTaskQueue : kMaxMainThreadTaskQueue;
  if (this->mainThreadTaskQueue.size() >= limit) {
    NetworkWarn(
        "Network main-thread task queue overflow: dropping %s task at %zu "
        "queued task(s)",
        terminal ? "terminal" : "non-terminal",
        this->mainThreadTaskQueue.size());
    return false;
  }
  this->mainThreadTaskQueue.push(std::move(task));
  return true;
}

bool NetworkManager::EnqueueDownloadTask(std::function<void()> task) {
  if (this->shutdownWorkers.load()) {
    return false;
  }

  {
    std::lock_guard<std::mutex> lock(this->downloadWorkerMutex);
    if (this->shutdownWorkers.load() ||
        this->downloadWorkerQueue.size() >= kMaxDownloadWorkerQueue) {
      return false;
    }
    this->downloadWorkerQueue.push(std::move(task));
  }

  this->downloadWorkerCv.notify_one();
  return true;
}

void NetworkManager::Update() {
  RefreshOnlineVerboseLogsPreference();
  DrainDeferredLuaCallbackRefReleases();
  RageTimer timer;
  static RageTimer lastBacklogWarning;
  int tasksProcessed = 0;
  std::size_t queuedAtStart = 0;
  {
    std::lock_guard<std::mutex> lock(this->mainThreadTaskMutex);
    queuedAtStart = this->mainThreadTaskQueue.size();
  }

  const bool backlogMode = queuedAtStart >= kBacklogAdaptiveThreshold;
  const int maxTasksThisFrame = backlogMode ? kBacklogMainThreadTasksPerUpdate
                                            : kBaseMainThreadTasksPerUpdate;
  const float maxSecondsThisFrame = backlogMode
                                        ? kBacklogMainThreadTaskSecondsPerUpdate
                                        : kBaseMainThreadTaskSecondsPerUpdate;

  while (tasksProcessed < maxTasksThisFrame) {
    std::function<void()> task;
    {
      std::lock_guard<std::mutex> lock(this->mainThreadTaskMutex);
      if (this->mainThreadTaskQueue.empty()) {
        break;
      }

      task = std::move(this->mainThreadTaskQueue.front());
      this->mainThreadTaskQueue.pop();
    }

    task();
    ++tasksProcessed;

    if (timer.Ago() >= maxSecondsThisFrame) {
      break;
    }
  }

  if (tasksProcessed >= maxTasksThisFrame ||
      timer.Ago() >= maxSecondsThisFrame) {
    std::lock_guard<std::mutex> lock(this->mainThreadTaskMutex);
    const auto queuedTasks = this->mainThreadTaskQueue.size();
    static int consecutiveBacklogWarnings = 0;

    if (queuedTasks == 0) {
      consecutiveBacklogWarnings = 0;
      return;
    }

    ++consecutiveBacklogWarnings;
    if ((queuedTasks > kBacklogAdaptiveThreshold * 4 ||
         (queuedTasks >= kBacklogAdaptiveThreshold &&
          consecutiveBacklogWarnings >= 3)) &&
        lastBacklogWarning.Ago() >= 1.0f) {
      NetworkWarn(
          "Network main-thread task backlog still has %zu queued task(s)",
          queuedTasks);
      lastBacklogWarning.Touch();
    }
  }
}

bool NetworkManager::IsUrlAllowed(const std::string& url) {
  static std::mutex hostCacheMutex;

  if (!this->httpEnabled.Get()) {
    return false;
  }

  std::string protocol;
  std::string host;
  std::string path;
  std::string query;
  int port;

  bool valid = ix::UrlParser::parse(url, protocol, host, path, query, port);

  if (!valid) {
    return false;
  }

  MakeLower(host);
  const bool isLegacyGrooveStatsQrLogin =
      protocol == "ws" && host == LEGACY_GROOVESTATS_QR_LOGIN_HOST &&
      port == LEGACY_GROOVESTATS_QR_LOGIN_PORT;

  if (!isLegacyGrooveStatsQrLogin &&
      (protocol != "https" && protocol != "wss")) {
    return false;
  }

  if (!isLegacyGrooveStatsQrLogin && port != 443) {
    return false;
  }

  const bool productionHostRequiresPinning = IsProductionItgOnlineHost(host);
  const bool effectivePinsCoverHost =
      PublicKeyPinsCoverHost(this->tlsOptions.publicKeySha256Pins, host);
  if (productionHostRequiresPinning &&
      (!this->tlsBackendEnforcesPublicKeyPins || !effectivePinsCoverHost)) {
    if (!this->warnedPinningUnsupportedForProductionHost.exchange(true)) {
      NetworkWarn(
          "Refusing %s because this build cannot enforce a configured public "
          "key pin for the production host.",
          RedactUrlForLog(url).c_str());
    }
    return false;
  }

  std::lock_guard<std::mutex> hostCacheLock(hostCacheMutex);

  static std::string cachedDeniedRaw;
  static std::vector<std::string> cachedDeniedHosts;
  const auto& deniedHosts = CachedHostList(
      this->httpDenyHosts.Get(), cachedDeniedRaw, cachedDeniedHosts);

  for (const auto& deniedHost : deniedHosts) {
    if (HostMatchesPattern(host, deniedHost)) {
      return false;
    }
  }

  // GrooveStats' upstream QR-login service intentionally still exposes its
  // authenticated handshake only over this exact legacy WebSocket endpoint.
  // Keep the exception narrow: no other cleartext scheme, host, or port is
  // admitted, and HttpDenyHosts remains authoritative above.
  if (isLegacyGrooveStatsQrLogin) {
    return true;
  }

  static std::string cachedAllowedRaw;
  static std::vector<std::string> cachedAllowedHosts;
  const auto& allowedHosts = CachedHostList(
      this->httpAllowHosts.Get(), cachedAllowedRaw, cachedAllowedHosts);

  for (const auto& allowedHost : allowedHosts) {
    if (HostMatchesPattern(host, allowedHost)) {
      return true;
    }
  }

  // Older installs can already have Save/Preferences.ini with a stale
  // HttpAllowHosts value, which would otherwise override the safer compiled
  // default and block bundled online services. Keep HttpDenyHosts authoritative
  // above, but never let stale local preferences brick production endpoints.
  static std::string cachedRequiredRaw;
  static std::vector<std::string> cachedRequiredHosts;
  const auto& requiredHosts = CachedHostList(
      REQUIRED_BUNDLED_ONLINE_ALLOW_HOSTS, cachedRequiredRaw,
      cachedRequiredHosts);

  for (const auto& requiredHost : requiredHosts) {
    if (HostMatchesPattern(host, requiredHost)) {
      return true;
    }
  }

  return false;
}

bool NetworkManager::IsHttpEnabled() const { return this->httpEnabled.Get(); }

std::string NetworkManager::HttpPublicKeyPins() const {
  return this->tlsOptions.publicKeySha256Pins;
}

HttpRequestFuturePtr NetworkManager::HttpRequest(const HttpRequestArgs& args) {
  if (this->shutdownWorkers.load() || !this->IsUrlAllowed(args.url)) {
    ix::HttpRequestArgsPtr blockedRequest =
        std::make_shared<ix::HttpRequestArgs>();
    blockedRequest->cancel = true;
    if (args.onResponse) {
      const ix::HttpResponsePtr response =
          this->shutdownWorkers.load()
              ? MakeCancelledHttpResponse("network manager is shutting down")
              : MakeBlockedHttpResponse(args.url);
      args.onResponse(response);
    }
    return std::make_shared<HttpRequestFuture>(blockedRequest, args.onCancel);
  }

  bool useDownloadClient = !args.downloadFile.empty();
  auto& client = useDownloadClient ? this->downloadClient : this->httpClient;
  auto downloadFile = std::make_shared<RageFile>();
  auto downloadError = std::make_shared<std::string>();
  auto downloadedBytes = std::make_shared<int64_t>(0);
  std::string downloadFilename;
  std::string tempDownloadFilename;
  const int64_t effectiveMaxDownloadBytes =
      args.maxDownloadBytes >= 0
          ? std::min(args.maxDownloadBytes, kMaxDownloadBytes)
          : kDefaultMaxDownloadBytes;

  ix::HttpRequestArgsPtr req = client.createRequest(args.url, args.method);
  req->body = args.body;
  req->multipartBoundary = args.multipartBoundary;
  req->followRedirects = false;
  req->maxRedirects = 0;
  req->allowCompressedResponse = false;
  // Downloads stream their payload to a temporary file. Applying the regular
  // JSON/API response cap here rejects valid song-pack archives before the
  // chunk callback can persist them. Keep the small cap for in-memory HTTP
  // responses, but use the independently bounded download limit for files.
  req->maxResponseBodyBytes = static_cast<uint64_t>(
      useDownloadClient
          ? effectiveMaxDownloadBytes
          : (args.maxResponseBytes >= 0 ? args.maxResponseBytes
                                        : kDefaultMaxHttpResponseBytes));
  // Avoid gzip-compressed HTTP responses: Lua JSON consumers expect plain text.
  // Some upstream endpoints return gzip payloads that are not decoded in this
  // path.
  req->compress = false;

  req->extraHeaders["User-Agent"] = this->GetUserAgent();
  for (const auto& entry : args.headers) {
    req->extraHeaders[entry.first] = entry.second;
  }

  if (!args.downloadFile.empty()) {
    downloadFilename = std::string("/Downloads/") + args.downloadFile;
    tempDownloadFilename = ssprintf(
        "/Downloads/.itgmania-%llu-%s.tmp",
        static_cast<unsigned long long>(++g_DownloadTempFileIds),
        args.downloadFile.c_str());
    if (!downloadFile->Open(
            tempDownloadFilename, RageFile::WRITE | RageFile::STREAMED)) {
      *downloadError = downloadFile->GetError();
      req->cancel = true;
    }

    req->onChunkCallback = [downloadFile, downloadError, downloadedBytes,
                            effectiveMaxDownloadBytes,
                            req](const std::string& data) {
      *downloadedBytes += static_cast<int64_t>(data.size());
      if (*downloadedBytes > effectiveMaxDownloadBytes) {
        *downloadError = "download exceeded maximum allowed size";
        req->cancel = true;
        return;
      }
      std::size_t writtenBytes = 0;
      while (writtenBytes < data.size()) {
        const int result = downloadFile->Write(
            data.data() + writtenBytes, data.size() - writtenBytes);
        if (result <= 0) {
          *downloadError = result < 0 ? downloadFile->GetError()
                                      : "download write made no progress";
          req->cancel = true;
          return;
        }
        writtenBytes += static_cast<std::size_t>(result);
      }
    };

    req->transferTimeout = kDefaultDownloadTransferTimeoutSeconds;
  }

  if (args.connectTimeout > 0) {
    req->connectTimeout = args.connectTimeout;
  }

  if (args.transferTimeout > 0) {
    req->transferTimeout = args.transferTimeout;
  }

  if (args.onProgress) {
    req->onProgressCallback = args.onProgress;
  }

  {
    std::mutex& workerMutex =
        useDownloadClient ? this->downloadWorkerMutex : this->httpWorkerMutex;
    std::queue<std::function<void()>>& workerQueue =
        useDownloadClient ? this->downloadWorkerQueue : this->httpWorkerQueue;
    const std::size_t workerQueueLimit =
        useDownloadClient ? kMaxDownloadWorkerQueue : kMaxHttpWorkerQueue;
    std::lock_guard<std::mutex> lock(workerMutex);
    if (this->shutdownWorkers.load()) {
      req->cancel = true;
      return std::make_shared<HttpRequestFuture>(req, args.onCancel);
    }
    if (workerQueue.size() >= workerQueueLimit) {
      req->cancel = true;
      if (args.onResponse) {
        args.onResponse(MakeCancelledHttpResponse(
            useDownloadClient ? "download worker queue is full"
                              : "HTTP worker queue is full"));
      }
      return std::make_shared<HttpRequestFuture>(req, args.onCancel);
    }
    {
      std::lock_guard<std::mutex> activeLock(this->activeHttpRequestsMutex);
      this->activeHttpRequests.erase(
          std::remove_if(
              this->activeHttpRequests.begin(), this->activeHttpRequests.end(),
              [](const std::weak_ptr<ix::HttpRequestArgs>& request) {
                return request.expired();
              }),
          this->activeHttpRequests.end());
      this->activeHttpRequests.push_back(req);
    }
    workerQueue.push([this, useDownloadClient, req, args, downloadFile,
                      downloadError, downloadFilename, tempDownloadFilename]() {
      if (this->shutdownWorkers.load()) {
        return;
      }

      auto& workerClient =
          useDownloadClient ? this->downloadClient : this->httpClient;

      workerClient.performRequest(
          req, [this, args, downloadFile, downloadError, downloadFilename,
                tempDownloadFilename](const ix::HttpResponsePtr& response) {
            if (!args.downloadFile.empty()) {
              std::string error = !downloadError->empty()
                                      ? *downloadError
                                      : downloadFile->GetError();
              downloadFile->Close();

              if (!error.empty()) {
                std::string errorMessage = "could not write to " +
                                           downloadFile->GetPath() + ": " +
                                           error;
                if (args.onFileError) {
                  args.onFileError(errorMessage);
                }

                if (FILEMAN != nullptr) {
                  FILEMAN->Remove(tempDownloadFilename);
                }
                return;
              }

              if (response == nullptr ||
                  response->errorCode != ix::HttpErrorCode::Ok ||
                  response->statusCode < 200 || response->statusCode >= 300) {
                if (args.onFileError) {
                  args.onFileError(
                      response == nullptr || response->errorMsg.empty()
                          ? "download request failed"
                          : response->errorMsg);
                }
                if (FILEMAN != nullptr) {
                  FILEMAN->Remove(tempDownloadFilename);
                }
                return;
              }

              if (FILEMAN == nullptr) {
                if (args.onFileError) {
                  args.onFileError("file manager unavailable");
                }
                downloadFile->Close();
                return;
              }

              const std::string backupFilename = downloadFilename + ".previous";
              FILEMAN->Remove(backupFilename);
              const bool hadExistingDownload =
                  FILEMAN->DoesFileExist(downloadFilename);
              if (hadExistingDownload &&
                  !FILEMAN->Move(downloadFilename, backupFilename)) {
                if (args.onFileError) {
                  args.onFileError(
                      "could not preserve existing completed download");
                }
                FILEMAN->Remove(tempDownloadFilename);
                return;
              }
              if (!FILEMAN->Move(tempDownloadFilename, downloadFilename)) {
                if (hadExistingDownload) {
                  FILEMAN->Move(backupFilename, downloadFilename);
                }
                if (args.onFileError) {
                  args.onFileError(
                      "could not move completed download into place");
                }
                FILEMAN->Remove(tempDownloadFilename);
                return;
              }
              if (hadExistingDownload) {
                FILEMAN->Remove(backupFilename);
              }
            }

            if (args.downloadFile.empty()) {
              NormalizeHttpResponseBody(response, args.maxResponseBytes);
            }

            if (args.onResponse) {
              args.onResponse(response);
            }

            // Lua response callbacks are queued on the main thread. Queue the
            // requested cleanup behind them so the archive remains available
            // throughout extraction but does not leak afterwards.
            if (!args.downloadFile.empty() &&
                args.deleteDownloadAfterResponse) {
              if (!this->EnqueueMainThreadTask(
                      [downloadFilename]() {
                        if (FILEMAN != nullptr) {
                          FILEMAN->Remove(downloadFilename);
                        }
                      },
                      true)) {
                NetworkWarn(
                    "Could not schedule cleanup for completed download '%s'",
                    args.downloadFile.c_str());
              }
            }
          });
    });
  }

  if (useDownloadClient) {
    this->downloadWorkerCv.notify_one();
  } else {
    this->httpWorkerCv.notify_one();
  }

  return std::make_shared<HttpRequestFuture>(req, args.onCancel);
}

WebSocketHandlePtr NetworkManager::WebSocket(const WebSocketArgs& args) {
  auto handle = std::make_shared<WebSocketHandle>();
  handle->debugId = ++g_WebSocketHandleIds;
  handle->debugUrl = args.url;
  handle->onClose = args.onClose;
  if (this->shutdownWorkers.load() || !this->IsUrlAllowed(args.url)) {
    handle->closed = true;
    NetworkWarn(
        "blocked websocket access to %s", RedactUrlForLog(args.url).c_str());
    if (args.onMessage) {
      static const std::string kEmptyMessage;
      ix::WebSocketErrorInfo errorInfo;
      errorInfo.reason = this->shutdownWorkers.load()
                             ? "network manager is shutting down"
                             : "websocket URL is not allowed";
      const ix::WebSocketMessage message(
          ix::WebSocketMessageType::Error, kEmptyMessage, 0, errorInfo,
          ix::WebSocketOpenInfo(), ix::WebSocketCloseInfo());
      args.onMessage(message);
    }
    // CloseSocket() is intentionally a no-op once `closed` is set. Invoke the
    // callback invalidation explicitly so an immediate construction failure
    // cannot retain the Lua callback reference indefinitely.
    handle->InvalidateCallbacks();
    return handle;
  }

  NetworkTrace(
      "ITG Online NetworkTrace: websocket_create handle=%llu url=%s",
      static_cast<unsigned long long>(handle->debugId),
      RedactUrlForLog(handle->debugUrl).c_str());

  handle->webSocket.setUrl(args.url);
  handle->webSocket.setTLSOptions(this->tlsOptions);
  handle->webSocket.disablePerMessageDeflate();
  const int64_t maxMessageBytes = args.maxMessageBytes >= 0
                                      ? args.maxMessageBytes
                                      : kDefaultMaxWebSocketMessageBytes;
  handle->webSocket.setOnMessageCallback(
      [onMessage = args.onMessage,
       maxMessageBytes](const ix::WebSocketMessagePtr& msg) {
        if (onMessage && msg) {
          if (msg->str.size() > static_cast<std::size_t>(maxMessageBytes)) {
            NetworkWarn(
                "Dropping oversized WebSocket message: %zu bytes",
                msg->str.size());
            return;
          }
          onMessage(*msg);
        }
      });

  ix::WebSocketHttpHeaders headers;
  headers["User-Agent"] = this->GetUserAgent();
  for (const auto& entry : args.headers) {
    headers[entry.first] = entry.second;
  }
  handle->webSocket.setExtraHeaders(headers);

  if (args.handshakeTimeout > -1) {
    handle->webSocket.setHandshakeTimeout(args.handshakeTimeout);
  }

  if (args.pingInterval > -1) {
    handle->webSocket.setPingInterval(args.pingInterval);
  }

  if (args.automaticReconnect) {
    handle->webSocket.enableAutomaticReconnection();
  } else {
    handle->webSocket.disableAutomaticReconnection();
  }

  {
    std::lock_guard<std::mutex> lock(this->webSocketWorkerMutex);
    if (this->shutdownWorkers.load()) {
      handle->closed = true;
      return handle;
    }
    if (this->webSocketWorkerQueue.size() >= kMaxWebSocketWorkerQueue) {
      handle->closed = true;
      NetworkWarn(
          "WebSocket worker queue is full for %s",
          RedactUrlForLog(args.url).c_str());
      if (args.onMessage) {
        static const std::string kEmptyMessage;
        ix::WebSocketErrorInfo errorInfo;
        errorInfo.reason = "websocket worker queue is full";
        const ix::WebSocketMessage message(
            ix::WebSocketMessageType::Error, kEmptyMessage, 0, errorInfo,
            ix::WebSocketOpenInfo(), ix::WebSocketCloseInfo());
        args.onMessage(message);
      }
      // This handle never reaches the worker, so no later close event will
      // release its Lua callback state.
      handle->InvalidateCallbacks();
      return handle;
    }
    this->webSocketWorkerQueue.push([this, handle]() {
      if (this->shutdownWorkers.load() || handle->closed.load()) {
        NetworkTrace(
            "ITG Online NetworkTrace: websocket_start_skipped handle=%llu "
            "shutdown=%d closed=%d url=%s",
            static_cast<unsigned long long>(handle->debugId),
            this->shutdownWorkers.load() ? 1 : 0, handle->closed.load() ? 1 : 0,
            RedactUrlForLog(handle->debugUrl).c_str());
        return;
      }

      NetworkTrace(
          "ITG Online NetworkTrace: websocket_start_begin handle=%llu url=%s",
          static_cast<unsigned long long>(handle->debugId),
          RedactUrlForLog(handle->debugUrl).c_str());
      handle->webSocket.start();
      NetworkTrace(
          "ITG Online NetworkTrace: websocket_start_end handle=%llu url=%s",
          static_cast<unsigned long long>(handle->debugId),
          RedactUrlForLog(handle->debugUrl).c_str());
    });
  }

  this->webSocketWorkerCv.notify_one();
  NetworkTrace(
      "ITG Online NetworkTrace: websocket_start_queued handle=%llu url=%s",
      static_cast<unsigned long long>(handle->debugId),
      RedactUrlForLog(handle->debugUrl).c_str());

  {
    std::lock_guard<std::mutex> lock(this->webSocketHandlesMutex);
    webSocketHandles.push_back(handle);
  }

  return handle;
}

std::string NetworkManager::UrlEncode(const std::string& value) {
  return this->httpClient.urlEncode(value);
}

std::string NetworkManager::EncodeQueryParameters(
    const std::unordered_map<std::string, std::string>& query) {
  return this->httpClient.serializeHttpParameters(query);
}

std::string NetworkManager::GetUserAgent() {
  std::stringstream ss;
  ss << PRODUCT_FAMILY << "/" << product_version;
  return ss.str();
}

void NetworkManager::ClearDownloads() {
  if (FILEMAN == nullptr) {
    NetworkWarn("Network downloads cleanup skipped: FILEMAN is unavailable");
    return;
  }

  std::vector<std::string> files;
  FILEMAN->GetDirListing("/Downloads/*", files, false, true);

  for (const auto& file : files) {
    const auto slash = file.find_last_of('/');
    const std::string filename =
        slash == std::string::npos ? file : file.substr(slash + 1);
    const bool managedTemp = filename.compare(0, 10, ".itgmania-") == 0 &&
                             filename.size() >= 4 &&
                             filename.substr(filename.size() - 4) == ".tmp";
    const bool managedOnlineArchive =
        filename.compare(0, 11, "itg-online-") == 0 && filename.size() >= 4 &&
        filename.substr(filename.size() - 4) == ".zip";
    if (!managedTemp && !managedOnlineArchive) {
      continue;
    }

    if (!FILEMAN->IsADirectory(file)) {
      FILEMAN->Remove(file);
    }
  }
}

int HttpRequestFuture::Collect(lua_State* L) {
  void* udata = luaL_checkudata(L, 1, "HttpRequestFuture");
  auto futptr = static_cast<HttpRequestFuturePtr*>(udata);
  // Futures are handles, not ownership of the request. Fire-and-forget Lua
  // callers are valid and must not have their request silently cancelled by
  // a collection cycle. Explicit Cancel() remains the only cancellation API.
  futptr->~shared_ptr();
  return 0;
}

int HttpRequestFuture::Cancel(lua_State* L) {
  void* udata = luaL_checkudata(L, 1, "HttpRequestFuture");
  auto fut = *static_cast<HttpRequestFuturePtr*>(udata);
  if (!fut) {
    return 0;
  }
  if (fut->canceled.exchange(true)) {
    NetworkTrace(
        "ITG Online NetworkTrace: http_future_cancel_skipped "
        "reason=already_canceled");
    return 0;
  }
  NetworkTrace("ITG Online NetworkTrace: http_future_cancel_begin");
  fut->args->cancel = true;
  if (fut->onCancel) {
    fut->onCancel();
  }
  NetworkTrace("ITG Online NetworkTrace: http_future_cancel_end");
  return 0;
}

void WebSocketHandle::InvalidateCallbacks() {
  if (auto closeCallback = std::move(onClose)) {
    NetworkTrace(
        "ITG Online NetworkTrace: websocket_invalidate_callbacks_begin "
        "handle=%llu url=%s",
        static_cast<unsigned long long>(debugId),
        RedactUrlForLog(debugUrl).c_str());
    onClose = nullptr;
    closeCallback();
    NetworkTrace(
        "ITG Online NetworkTrace: websocket_invalidate_callbacks_end "
        "handle=%llu url=%s",
        static_cast<unsigned long long>(debugId),
        RedactUrlForLog(debugUrl).c_str());
  }
}

void WebSocketHandle::CloseSocket(bool calledFromLua) {
  if (closed.exchange(true)) {
    return;
  }

  NetworkTrace(
      "ITG Online NetworkTrace: websocket_close_begin handle=%llu "
      "calledFromLua=%d url=%s",
      static_cast<unsigned long long>(debugId), calledFromLua ? 1 : 0,
      RedactUrlForLog(debugUrl).c_str());
  InvalidateCallbacks();
  webSocket.disableAutomaticReconnection();
  const bool canYieldLua = calledFromLua && LUA != nullptr;
  if (canYieldLua) {
    LUA->YieldLua();
  }
  webSocket.stop();
  if (canYieldLua) {
    LUA->UnyieldLua();
  }
  NetworkTrace(
      "ITG Online NetworkTrace: websocket_close_end handle=%llu "
      "calledFromLua=%d url=%s",
      static_cast<unsigned long long>(debugId), calledFromLua ? 1 : 0,
      RedactUrlForLog(debugUrl).c_str());
}

WebSocketHandle::~WebSocketHandle() { CloseSocket(false); }

int WebSocketHandle::Collect(lua_State* L) {
  void* udata = luaL_checkudata(L, 1, "WebSocketHandle");
  auto handleptr = static_cast<WebSocketHandlePtr*>(udata);
  if (*handleptr) {
    (*handleptr)->CloseSocket(true);
  }
  handleptr->~shared_ptr();
  return 0;
}

int WebSocketHandle::Close(lua_State* L) {
  void* udata = luaL_checkudata(L, 1, "WebSocketHandle");
  auto handle = *static_cast<WebSocketHandlePtr*>(udata);

  if (!handle) {
    return 0;
  }
  handle->CloseSocket(true);

  return 0;
}

int WebSocketHandle::Send(lua_State* L) {
  void* udata = luaL_checkudata(L, 1, "WebSocketHandle");
  auto handle = *static_cast<WebSocketHandlePtr*>(udata);
  if (!handle) {
    lua_pushboolean(L, false);
    return 1;
  }

  size_t len;
  const char* s = luaL_checklstring(L, 2, &len);
  if (len > static_cast<std::size_t>(kDefaultMaxWebSocketMessageBytes)) {
    lua_pushboolean(L, false);
    return 1;
  }
  std::string data(s, len);

  bool binary = lua_toboolean(L, 3);

  if (handle->closed.load() ||
      handle->webSocket.getReadyState() != ix::ReadyState::Open) {
    lua_pushboolean(L, false);
    return 1;
  }

  auto info = handle->webSocket.send(data, binary);

  lua_pushboolean(L, info.success);
  return 1;
}

// lua start
#include "LuaBinding.h"

static void registerHttpRequestMetatable(lua_State* L) {
  const luaL_Reg HttpRequest_meta[] = {
      {"__gc", HttpRequestFuture::Collect},
      {"Cancel", HttpRequestFuture::Cancel},
      {NULL, NULL},
  };

  luaL_newmetatable(L, "HttpRequestFuture");
  luaL_register(L, NULL, HttpRequest_meta);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
}

REGISTER_WITH_LUA_FUNCTION(registerHttpRequestMetatable)

static void registerWebSocketMetatable(lua_State* L) {
  const luaL_Reg WebSocket_meta[] = {
      {"__gc", WebSocketHandle::Collect},
      {"Close", WebSocketHandle::Close},
      {"Send", WebSocketHandle::Send},
      {NULL, NULL},
  };

  luaL_newmetatable(L, "WebSocketHandle");
  luaL_register(L, NULL, WebSocket_meta);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
}

REGISTER_WITH_LUA_FUNCTION(registerWebSocketMetatable)

/** @brief Allow Lua to have access to the NetworkManager. */
class LunaNetworkManager : public Luna<NetworkManager> {
 public:
  static int IsUrlAllowed(T* p, lua_State* L) {
    std::string url = SArg(1);

    lua_pushboolean(L, p->IsUrlAllowed(url));
    return 1;
  }

  static int HttpEnabled(T* p, lua_State* L) {
    lua_pushboolean(L, p->IsHttpEnabled());
    return 1;
  }

  static int HttpPublicKeyPins(T* p, lua_State* L) {
    lua_pushstring(L, p->HttpPublicKeyPins().c_str());
    return 1;
  }

  static int HttpRequest(T* p, lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    HttpRequestArgs args;
    auto callbackState = std::make_shared<LuaHttpCallbackState>();
    callbackState->id = ++g_LuaHttpCallbackStateIds;

    lua_getfield(L, 1, "url");
    if (lua_isnil(L, -1)) {
      luaL_error(L, "url is required");
    } else if (lua_isstring(L, -1)) {
      args.url = lua_tostring(L, -1);
    } else {
      luaL_error(L, "url must be a string");
    }
    lua_pop(L, 1);
    callbackState->url = args.url;
    NetworkTrace(
        "ITG Online NetworkTrace: lua_http_request_begin id=%llu url=%s",
        static_cast<unsigned long long>(callbackState->id),
        RedactUrlForLog(callbackState->url).c_str());

    lua_getfield(L, 1, "method");
    if (!lua_isnil(L, -1)) {
      if (lua_isstring(L, -1)) {
        std::string method = lua_tostring(L, -1);
        MakeUpper(method);

        std::vector<std::string> supported_methods{"GET",   "POST",   "PUT",
                                                   "PATCH", "DELETE", "HEAD"};
        if (std::find(
                supported_methods.begin(), supported_methods.end(), method) ==
            supported_methods.end()) {
          luaL_error(L, "unknown method: '%s'", method.c_str());
        }

        args.method = method;
      } else {
        luaL_error(L, "method must be a string");
      }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "body");
    if (!lua_isnil(L, -1)) {
      if (lua_isstring(L, -1)) {
        size_t len;
        const char* s = lua_tolstring(L, -1, &len);
        if (len > kMaxHttpRequestBodyBytes) {
          luaL_error(L, "body exceeds maximum allowed size");
        }
        args.body = std::string(s, len);
      } else {
        luaL_error(L, "body must be a string");
      }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "multipartBoundary");
    if (!lua_isnil(L, -1)) {
      if (lua_isstring(L, -1)) {
        size_t len;
        const char* s = lua_tolstring(L, -1, &len);
        if (len > kMaxHttpHeaderValueLength) {
          luaL_error(L, "multipartBoundary exceeds maximum allowed size");
        }
        args.multipartBoundary = std::string(s, len);
      } else {
        luaL_error(L, "multipartBoundary must be a string");
      }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "headers");
    if (!lua_isnil(L, -1)) {
      if (lua_istable(L, -1)) {
        std::size_t headerCount = 0;
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
          if (!lua_isstring(L, -2)) {
            luaL_error(L, "header keys must be strings");
          }

          if (!lua_isstring(L, -1)) {
            luaL_error(L, "header values must be strings");
          }

          std::string key = lua_tostring(L, -2);
          std::string value = lua_tostring(L, -1);
          if (++headerCount > kMaxHttpHeaderCount) {
            luaL_error(L, "too many headers");
          }
          if (!IsSafeHttpHeaderName(key) || !IsSafeHeaderValue(value)) {
            luaL_error(L, "invalid header");
          }

          args.headers[key] = value;

          lua_pop(L, 1);
        }
      } else {
        luaL_error(L, "headers must be a table");
      }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "connectTimeout");
    if (!lua_isnil(L, -1)) {
      args.connectTimeout = ClampTimeoutSeconds(L, -1, "connectTimeout");
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "transferTimeout");
    if (!lua_isnil(L, -1)) {
      args.transferTimeout = ClampTimeoutSeconds(L, -1, "transferTimeout");
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "maxResponseBytes");
    if (!lua_isnil(L, -1)) {
      args.maxResponseBytes = ClampNonNegativeInt64(
          L, -1, "maxResponseBytes", kDefaultMaxHttpResponseBytes);
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "maxDownloadBytes");
    if (!lua_isnil(L, -1)) {
      args.maxDownloadBytes =
          ClampNonNegativeInt64(L, -1, "maxDownloadBytes", kMaxDownloadBytes);
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "downloadFile");
    if (!lua_isnil(L, -1)) {
      if (lua_isstring(L, -1)) {
        args.downloadFile = lua_tostring(L, -1);
        if (!IsSafeDownloadFileName(args.downloadFile)) {
          luaL_error(L, "downloadFile must be a safe file name");
        }
      } else {
        luaL_error(L, "downloadFile must be a string");
      }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "deleteDownloadAfterResponse");
    if (!lua_isnil(L, -1)) {
      if (lua_isboolean(L, -1)) {
        args.deleteDownloadAfterResponse = lua_toboolean(L, -1);
      } else {
        luaL_error(L, "deleteDownloadAfterResponse must be a boolean");
      }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "onProgress");
    if (!lua_isnil(L, -1)) {
      if (lua_isfunction(L, -1)) {
        lua_pushvalue(L, -1);
        callbackState->progressRef = luaL_ref(L, LUA_REGISTRYINDEX);

        args.onProgress = [p, callbackState](int64_t current, int64_t total) {
          if (!callbackState->active.load() ||
              callbackState->progressCancelRequested.load()) {
            return false;
          }

          callbackState->latestProgressCurrent = current;
          callbackState->latestProgressTotal = total;

          if (callbackState->progressQueued.exchange(true)) {
            return callbackState->active.load();
          }

          if (!p->EnqueueMainThreadTask([callbackState]() {
                callbackState->progressQueued = false;
                if (!callbackState->active.load() ||
                    callbackState->refsReleased ||
                    callbackState->progressRef == LUA_NOREF) {
                  return;
                }

                const int64_t current =
                    callbackState->latestProgressCurrent.load();
                const int64_t total = callbackState->latestProgressTotal.load();
                WithLua([callbackState, current, total](Lua* L) {
                  if (!handleProgress(
                          L, current, total, callbackState->progressRef)) {
                    callbackState->progressCancelRequested = true;
                  }
                });
              })) {
            callbackState->progressQueued = false;
            return false;
          }

          return callbackState->active.load();
        };
      } else {
        luaL_error(L, "onProgress must be a function");
      }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "onResponse");
    if (!lua_isnil(L, -1)) {
      if (lua_isfunction(L, -1)) {
        lua_pushvalue(L, -1);
        callbackState->responseRef = luaL_ref(L, LUA_REGISTRYINDEX);
      } else {
        ReleaseLuaHttpCallbackRefs(L, callbackState);
        luaL_error(L, "onResponse must be a function");
      }
    }
    lua_pop(L, 1);

    RegisterLuaHttpCallbackState(callbackState);
    args.onCancel = [p, callbackState]() {
      NetworkTrace(
          "ITG Online NetworkTrace: lua_http_cancel id=%llu url=%s",
          static_cast<unsigned long long>(callbackState->id),
          RedactUrlForLog(callbackState->url).c_str());
      callbackState->canceled = true;
      callbackState->active = false;
      if (!p->EnqueueMainThreadTask(
              [callbackState]() {
                if (!WithLua([callbackState](Lua* L) {
                      ReleaseLuaHttpCallbackRefs(L, callbackState);
                    })) {
                  DeferLuaHttpCallbackRefRelease(callbackState);
                }
              },
              true)) {
        DeferLuaHttpCallbackRefRelease(callbackState);
      }
    };

    args.onFileError = [p, callbackState](const std::string& errorMessage) {
      NetworkTrace(
          "ITG Online NetworkTrace: lua_http_file_error id=%llu url=%s "
          "error=%s",
          static_cast<unsigned long long>(callbackState->id),
          RedactUrlForLog(callbackState->url).c_str(),
          RedactTextForLog(errorMessage).c_str());
      callbackState->active = false;
      if (!p->EnqueueMainThreadTask(
              [errorMessage, callbackState]() {
                if (!WithLua([errorMessage, callbackState](Lua* L) {
                      if (!callbackState->canceled.load() &&
                          !callbackState->refsReleased &&
                          callbackState->responseRef != LUA_NOREF) {
                        handleFileError(
                            L, errorMessage, callbackState->responseRef);
                      }
                      ReleaseLuaHttpCallbackRefs(L, callbackState);
                    })) {
                  DeferLuaHttpCallbackRefRelease(callbackState);
                }
              },
              true)) {
        DeferLuaHttpCallbackRefRelease(callbackState);
      }
    };

    args.onResponse = [p, callbackState](const ix::HttpResponsePtr& response) {
      callbackState->active = false;
      if (!p->EnqueueMainThreadTask(
              [response, callbackState]() {
                if (!WithLua([response, callbackState](Lua* L) {
                      if (!callbackState->canceled.load() &&
                          !callbackState->refsReleased &&
                          callbackState->responseRef != LUA_NOREF) {
                        handleHttpResponse(
                            L, response, callbackState->responseRef);
                        NetworkTrace(
                            "ITG Online NetworkTrace: "
                            "lua_http_response_delivered "
                            "id=%llu url=%s status=%d",
                            static_cast<unsigned long long>(callbackState->id),
                            RedactUrlForLog(callbackState->url).c_str(),
                            response ? response->statusCode : -1);
                      } else {
                        NetworkTrace(
                            "ITG Online NetworkTrace: lua_http_response_drop "
                            "id=%llu "
                            "url=%s canceled=%d refsReleased=%d responseRef=%d",
                            static_cast<unsigned long long>(callbackState->id),
                            RedactUrlForLog(callbackState->url).c_str(),
                            callbackState->canceled.load() ? 1 : 0,
                            callbackState->refsReleased ? 1 : 0,
                            callbackState->responseRef);
                      }
                      ReleaseLuaHttpCallbackRefs(L, callbackState);
                    })) {
                  DeferLuaHttpCallbackRefRelease(callbackState);
                }
              },
              true)) {
        NetworkTrace(
            "ITG Online NetworkTrace: lua_http_response_enqueue_failed "
            "id=%llu url=%s",
            static_cast<unsigned long long>(callbackState->id),
            RedactUrlForLog(callbackState->url).c_str());
        DeferLuaHttpCallbackRefRelease(callbackState);
      }
    };

    NetworkTrace(
        "ITG Online NetworkTrace: lua_http_request_submit id=%llu url=%s",
        static_cast<unsigned long long>(callbackState->id),
        RedactUrlForLog(callbackState->url).c_str());
    auto fut = p->HttpRequest(args);

    void* vp = lua_newuserdata(L, sizeof(std::shared_ptr<HttpRequestFuture>));
    new (vp) std::shared_ptr<::HttpRequestFuture>(fut);
    luaL_getmetatable(L, "HttpRequestFuture");
    lua_setmetatable(L, -2);
    return 1;
  }

  static int ProcessPackArchive(T* p, lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    auto readString = [L](const char* field, bool required) {
      lua_getfield(L, 1, field);
      std::string value;
      if (lua_isstring(L, -1)) {
        value = lua_tostring(L, -1);
      } else if (required || !lua_isnil(L, -1)) {
        luaL_error(L, "%s must be a string", field);
      }
      lua_pop(L, 1);
      return value;
    };

    std::string archivePath = readString("archivePath", true);
    std::string targetPath = readString("targetPath", true);
    std::string expectedSha256 = readString("expectedSha256", false);
    MakeLower(expectedSha256);
    if (!NormalizeOnlineArchivePaths(archivePath, targetPath)) {
      luaL_error(
          L,
          "archivePath or targetPath is outside the online pack staging roots");
    }
    if (!IsLowerHexSha256(expectedSha256)) {
      luaL_error(
          L, "expectedSha256 must be empty or a lowercase SHA-256 digest");
    }

    auto callbackState = std::make_shared<LuaHttpCallbackState>();
    callbackState->id = ++g_LuaHttpCallbackStateIds;
    callbackState->url = "online-pack-archive";
    lua_getfield(L, 1, "onComplete");
    if (!lua_isfunction(L, -1)) {
      lua_pop(L, 1);
      luaL_error(L, "onComplete must be a function");
    }
    callbackState->responseRef = luaL_ref(L, LUA_REGISTRYINDEX);
    RegisterLuaHttpCallbackState(callbackState);

    auto requestArgs = std::make_shared<ix::HttpRequestArgs>();
    // Cancellation only flips requestArgs->cancel. The terminal callback still
    // runs so Lua can remove a partially extracted quarantine directory without
    // applying the stale generation to room state.
    auto future = std::make_shared<HttpRequestFuture>(requestArgs);

    const bool queued = p->EnqueueDownloadTask([p, archivePath, targetPath,
                                                expectedSha256, requestArgs,
                                                callbackState]() {
      bool ok = false;
      std::string errorCode;
      std::string archiveHash;

      if (requestArgs->cancel.load()) {
        errorCode = "cancelled";
      } else if (FILEMAN == nullptr || CRYPTMAN == nullptr) {
        errorCode = "engine_unavailable";
      } else {
        const auto shouldCancel = [requestArgs]() {
          return requestArgs->cancel.load();
        };
        const std::string digest =
            CryptManager::GetSHA256ForFile(archivePath, shouldCancel);
        if (!digest.empty()) {
          archiveHash = BinaryToHex(digest);
          MakeLower(archiveHash);
        }

        if (!expectedSha256.empty() && archiveHash.empty()) {
          errorCode = "hash_unavailable";
        } else if (!expectedSha256.empty() && archiveHash != expectedSha256) {
          errorCode = "hash_mismatch";
        } else if (requestArgs->cancel.load()) {
          errorCode = "cancelled";
        } else if (!FILEMAN->Unzip(archivePath, targetPath, 0, shouldCancel)) {
          errorCode =
              requestArgs->cancel.load() ? "cancelled" : "invalid_archive";
        } else {
          ok = true;
        }
      }

      if (!ok && FILEMAN != nullptr) {
        FILEMAN->DeleteRecursive(targetPath);
      }

      callbackState->active = false;
      if (!p->EnqueueMainThreadTask(
              [ok, errorCode, archiveHash, callbackState]() {
                if (!WithLua([ok, errorCode, archiveHash,
                              callbackState](Lua* state) {
                      if (!callbackState->canceled.load() &&
                          !callbackState->refsReleased &&
                          callbackState->responseRef != LUA_NOREF) {
                        handlePackArchiveResult(
                            state, ok, errorCode, archiveHash,
                            callbackState->responseRef);
                      }
                      ReleaseLuaHttpCallbackRefs(state, callbackState);
                    })) {
                  DeferLuaHttpCallbackRefRelease(callbackState);
                }
              },
              true)) {
        DeferLuaHttpCallbackRefRelease(callbackState);
      }
    });

    if (!queued) {
      ReleaseLuaHttpCallbackRefs(L, callbackState);
      luaL_error(L, "online pack archive worker queue is unavailable");
    }

    void* userdata =
        lua_newuserdata(L, sizeof(std::shared_ptr<HttpRequestFuture>));
    new (userdata) std::shared_ptr<HttpRequestFuture>(future);
    luaL_getmetatable(L, "HttpRequestFuture");
    lua_setmetatable(L, -2);
    return 1;
  }

  static int WebSocket(T* p, lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    WebSocketArgs args;
    auto callbackState = std::make_shared<LuaWebSocketCallbackState>();
    callbackState->id = ++g_LuaWebSocketCallbackStateIds;

    lua_getfield(L, 1, "url");
    if (lua_isnil(L, -1)) {
      luaL_error(L, "url is required");
    } else if (lua_isstring(L, -1)) {
      args.url = lua_tostring(L, -1);
    } else {
      luaL_error(L, "url must be a string");
    }
    lua_pop(L, 1);
    callbackState->url = args.url;
    NetworkTrace(
        "ITG Online NetworkTrace: lua_websocket_begin id=%llu url=%s",
        static_cast<unsigned long long>(callbackState->id),
        RedactUrlForLog(callbackState->url).c_str());

    lua_getfield(L, 1, "headers");
    if (!lua_isnil(L, -1)) {
      if (lua_istable(L, -1)) {
        std::size_t headerCount = 0;
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
          if (!lua_isstring(L, -2)) {
            luaL_error(L, "header keys must be strings");
          }

          if (!lua_isstring(L, -1)) {
            luaL_error(L, "header values must be strings");
          }

          std::string key = lua_tostring(L, -2);
          std::string value = lua_tostring(L, -1);
          if (++headerCount > kMaxHttpHeaderCount) {
            luaL_error(L, "too many headers");
          }
          if (!IsSafeHttpHeaderName(key) || !IsSafeHeaderValue(value)) {
            luaL_error(L, "invalid header");
          }

          args.headers[key] = value;

          lua_pop(L, 1);
        }
      } else {
        luaL_error(L, "headers must be a table");
      }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "handshakeTimeout");
    if (!lua_isnil(L, -1)) {
      args.handshakeTimeout = ClampTimeoutSeconds(L, -1, "handshakeTimeout");
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "pingInterval");
    if (!lua_isnil(L, -1)) {
      args.pingInterval = ClampTimeoutSeconds(L, -1, "pingInterval");
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "maxMessageBytes");
    if (!lua_isnil(L, -1)) {
      args.maxMessageBytes = ClampNonNegativeInt64(
          L, -1, "maxMessageBytes", kDefaultMaxWebSocketMessageBytes);
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "automaticReconnect");
    if (!lua_isnil(L, -1)) {
      if (lua_isboolean(L, -1)) {
        args.automaticReconnect = lua_toboolean(L, -1);
      } else {
        luaL_error(L, "automaticReconnect must be a boolean");
      }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "onMessage");
    if (!lua_isnil(L, -1)) {
      if (lua_isfunction(L, -1)) {
        lua_pushvalue(L, -1);
        callbackState->messageRef = luaL_ref(L, LUA_REGISTRYINDEX);
      } else {
        luaL_error(L, "onMessage must be a function");
      }
    }
    lua_pop(L, 1);

    const int64_t luaMaxMessageBytes = args.maxMessageBytes >= 0
                                           ? args.maxMessageBytes
                                           : kDefaultMaxWebSocketMessageBytes;

    RegisterLuaWebSocketCallbackState(callbackState);
    args.onMessage = [p, callbackState,
                      luaMaxMessageBytes](const ix::WebSocketMessage& msg) {
      if (!callbackState->active.load()) {
        if (IsExpectedInactiveWebSocketTerminalMessage(msg.type)) {
          NetworkTrace(
              "ITG Online NetworkTrace: lua_websocket_inactive_terminal_drop "
              "id=%llu url=%s",
              static_cast<unsigned long long>(callbackState->id),
              RedactUrlForLog(callbackState->url).c_str());
          return;
        }

        NetworkTrace(
            "ITG Online NetworkTrace: lua_websocket_message_drop id=%llu "
            "url=%s reason=inactive type=%s",
            static_cast<unsigned long long>(callbackState->id),
            RedactUrlForLog(callbackState->url).c_str(),
            IxWebSocketMessageTypeName(msg.type));
        return;
      }

      ix::WebSocketMessageType type = msg.type;
      std::string data = msg.str;
      if (data.size() > static_cast<std::size_t>(luaMaxMessageBytes)) {
        NetworkWarn(
            "Dropping oversized WebSocket message from %s: %zu bytes",
            RedactUrlForLog(callbackState->url).c_str(), data.size());
        return;
      }
      ix::WebSocketErrorInfo errorInfo = msg.errorInfo;
      ix::WebSocketOpenInfo openInfo = msg.openInfo;
      ix::WebSocketCloseInfo closeInfo = msg.closeInfo;
      bool binary = msg.binary;
      const bool terminalMessage = type == ix::WebSocketMessageType::Close ||
                                   type == ix::WebSocketMessageType::Error;
      if (!p->EnqueueMainThreadTask(
              [type, data, errorInfo, openInfo, closeInfo, binary,
               terminalMessage, callbackState]() {
                if ((!callbackState->active.load() && !terminalMessage) ||
                    callbackState->refReleased ||
                    callbackState->messageRef == LUA_NOREF) {
                  NetworkTrace(
                      "ITG Online NetworkTrace: lua_websocket_message_drop "
                      "id=%llu "
                      "url=%s reason=callback_released active=%d "
                      "refReleased=%d "
                      "messageRef=%d type=%s",
                      static_cast<unsigned long long>(callbackState->id),
                      RedactUrlForLog(callbackState->url).c_str(),
                      callbackState->active.load() ? 1 : 0,
                      callbackState->refReleased ? 1 : 0,
                      callbackState->messageRef,
                      IxWebSocketMessageTypeName(type));
                  return;
                }

                WithLua([type, data, errorInfo, openInfo, closeInfo, binary,
                         callbackState](Lua* L) {
                  handleMessage(
                      L, type, data, errorInfo, openInfo, closeInfo, binary,
                      callbackState->messageRef);
                  NetworkTrace(
                      "ITG Online NetworkTrace: "
                      "lua_websocket_message_delivered "
                      "id=%llu url=%s type=%s bytes=%zu",
                      static_cast<unsigned long long>(callbackState->id),
                      RedactUrlForLog(callbackState->url).c_str(),
                      IxWebSocketMessageTypeName(type), data.size());
                });
              },
              terminalMessage)) {
        NetworkTrace(
            "ITG Online NetworkTrace: lua_websocket_message_enqueue_failed "
            "id=%llu url=%s type=%s bytes=%zu",
            static_cast<unsigned long long>(callbackState->id),
            RedactUrlForLog(callbackState->url).c_str(),
            IxWebSocketMessageTypeName(type), data.size());
        DeferLuaWebSocketCallbackRefRelease(callbackState);
      }
    };

    args.onClose = [p, callbackState]() {
      NetworkTrace(
          "ITG Online NetworkTrace: lua_websocket_on_close id=%llu url=%s",
          static_cast<unsigned long long>(callbackState->id),
          RedactUrlForLog(callbackState->url).c_str());
      callbackState->active = false;
      if (!p->EnqueueMainThreadTask(
              [callbackState]() {
                if (!WithLua([callbackState](Lua* L) {
                      ReleaseLuaWebSocketCallbackRef(L, callbackState);
                    })) {
                  DeferLuaWebSocketCallbackRefRelease(callbackState);
                }
              },
              true)) {
        DeferLuaWebSocketCallbackRefRelease(callbackState);
      }
    };

    NetworkTrace(
        "ITG Online NetworkTrace: lua_websocket_submit id=%llu url=%s",
        static_cast<unsigned long long>(callbackState->id),
        RedactUrlForLog(callbackState->url).c_str());
    auto handle = p->WebSocket(args);

    void* vp = lua_newuserdata(L, sizeof(std::shared_ptr<WebSocketHandle>));
    new (vp) std::shared_ptr<::WebSocketHandle>(handle);
    luaL_getmetatable(L, "WebSocketHandle");
    lua_setmetatable(L, -2);
    return 1;
  }

  static int UrlEncode(T* p, lua_State* L) {
    std::string url = SArg(1);

    std::string encoded = p->UrlEncode(url);

    lua_pushstring(L, encoded.c_str());
    return 1;
  }

  static int EncodeQueryParameters(T* p, lua_State* L) {
    std::unordered_map<std::string, std::string> query;

    if (lua_istable(L, 1)) {
      std::size_t parameterCount = 0;
      lua_pushnil(L);
      while (lua_next(L, -2) != 0) {
        if (!lua_isstring(L, -2)) {
          luaL_error(L, "parameter keys must be strings");
        }

        if (!lua_isstring(L, -1)) {
          luaL_error(L, "parameter values must be strings");
        }

        std::string key = lua_tostring(L, -2);
        std::string value = lua_tostring(L, -1);
        if (++parameterCount > kMaxQueryParameterCount) {
          luaL_error(L, "too many query parameters");
        }
        if (key.size() > kMaxQueryKeyLength ||
            value.size() > kMaxQueryValueLength ||
            key.find('\0') != std::string::npos ||
            value.find('\0') != std::string::npos) {
          luaL_error(L, "invalid query parameter");
        }

        query[key] = value;

        lua_pop(L, 1);
      }
    } else {
      luaL_error(L, "query must be a table");
    }

    std::string encoded = p->EncodeQueryParameters(query);

    lua_pushstring(L, encoded.c_str());
    return 1;
  }

  static int CloseAllWebSockets(T* p, lua_State* /* L */) {
    p->CloseAllWebSocketsFromLua();
    return 0;
  }

  static int SecureCredentialBackend(T* /* p */, lua_State* L) {
    lua_pushstring(L, SecureCredentialStore::BackendName());
    return 1;
  }

  static int SecureCredentialIsAvailable(T* /* p */, lua_State* L) {
    lua_pushboolean(L, SecureCredentialStore::IsAvailable());
    return 1;
  }

  static int SecureCredentialGet(T* /* p */, lua_State* L) {
    std::string service = SArg(1);
    std::string account = SArg(2);
    std::string secret;
    std::string error;
    if (!IsBoundedPlainValue(service, kMaxCredentialPartLength, false) ||
        !IsBoundedPlainValue(account, kMaxCredentialPartLength, false)) {
      lua_newtable(L);
      lua_pushboolean(L, false);
      lua_setfield(L, -2, "ok");
      lua_pushstring(L, "invalid credential service or account");
      lua_setfield(L, -2, "error");
      return 1;
    }

    bool ok = SecureCredentialStore::Load(service, account, secret, error);

    lua_newtable(L);
    lua_pushboolean(L, ok);
    lua_setfield(L, -2, "ok");
    if (ok) {
      lua_pushlstring(L, secret.data(), secret.size());
      lua_setfield(L, -2, "secret");
    } else {
      lua_pushstring(L, error.c_str());
      lua_setfield(L, -2, "error");
    }
    SecureWipe(secret);

    return 1;
  }

  static int SecureCredentialSet(T* /* p */, lua_State* L) {
    std::string service = SArg(1);
    std::string account = SArg(2);

    size_t secretLength = 0;
    const char* secretBytes = luaL_checklstring(L, 3, &secretLength);
    std::string secret(secretBytes, secretLength);
    if (!IsBoundedPlainValue(service, kMaxCredentialPartLength, false) ||
        !IsBoundedPlainValue(account, kMaxCredentialPartLength, false) ||
        secretLength == 0 ||
        secretLength > SecureCredentialStore::kMaxSecretLength ||
        secret.find('\0') != std::string::npos) {
      SecureWipe(secret);
      lua_newtable(L);
      lua_pushboolean(L, false);
      lua_setfield(L, -2, "ok");
      lua_pushstring(L, "invalid credential service, account, or secret");
      lua_setfield(L, -2, "error");
      return 1;
    }

    std::string error;
    bool ok = SecureCredentialStore::Store(service, account, secret, error);
    SecureWipe(secret);

    lua_newtable(L);
    lua_pushboolean(L, ok);
    lua_setfield(L, -2, "ok");
    if (!ok) {
      lua_pushstring(L, error.c_str());
      lua_setfield(L, -2, "error");
    }

    return 1;
  }

  static int SecureCredentialDelete(T* /* p */, lua_State* L) {
    std::string service = SArg(1);
    std::string account = SArg(2);
    std::string error;
    if (!IsBoundedPlainValue(service, kMaxCredentialPartLength, false) ||
        !IsBoundedPlainValue(account, kMaxCredentialPartLength, false)) {
      lua_newtable(L);
      lua_pushboolean(L, false);
      lua_setfield(L, -2, "ok");
      lua_pushstring(L, "invalid credential service or account");
      lua_setfield(L, -2, "error");
      return 1;
    }

    bool ok = SecureCredentialStore::Delete(service, account, error);

    lua_newtable(L);
    lua_pushboolean(L, ok);
    lua_setfield(L, -2, "ok");
    if (!ok) {
      lua_pushstring(L, error.c_str());
      lua_setfield(L, -2, "error");
    }

    return 1;
  }

  LunaNetworkManager() {
    ADD_METHOD(IsUrlAllowed);
    ADD_METHOD(HttpEnabled);
    ADD_METHOD(HttpPublicKeyPins);
    ADD_METHOD(HttpRequest);
    ADD_METHOD(ProcessPackArchive);
    ADD_METHOD(WebSocket);
    ADD_METHOD(UrlEncode);
    ADD_METHOD(EncodeQueryParameters);
    ADD_METHOD(CloseAllWebSockets);
    ADD_METHOD(SecureCredentialBackend);
    ADD_METHOD(SecureCredentialIsAvailable);
    ADD_METHOD(SecureCredentialGet);
    ADD_METHOD(SecureCredentialSet);
    ADD_METHOD(SecureCredentialDelete);
  }

 private:
  static void handlePackArchiveResult(
      Lua* L, bool ok, const std::string& errorCode,
      const std::string& archiveHash, int callbackRef) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, callbackRef);
    lua_newtable(L);
    lua_pushboolean(L, ok);
    lua_setfield(L, -2, "ok");
    if (!errorCode.empty()) {
      lua_pushstring(L, errorCode.c_str());
      lua_setfield(L, -2, "errorCode");
    }
    if (!archiveHash.empty()) {
      lua_pushstring(L, archiveHash.c_str());
      lua_setfield(L, -2, "sha256");
    }

    std::string error = "Lua error in pack archive completion handler: ";
    LuaHelpers::RunScriptOnStack(L, error, 1, 0, true);
  }

  static void handleFileError(
      Lua* L, const std::string& errorMessage, int onResponseRef) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, onResponseRef);

    lua_newtable(L);

    LuaHelpers::Push(L, HttpErrorCode_FileError);
    lua_setfield(L, -2, "error");

    lua_pushstring(L, errorMessage.c_str());
    lua_setfield(L, -2, "errorMessage");

    std::string error = "Lua error in HTTP response handler: ";
    LuaHelpers::RunScriptOnStack(L, error, 1, 0, true);
  }

  static void handleHttpResponse(
      Lua* L, const ix::HttpResponsePtr& response, int onResponseRef) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, onResponseRef);

    lua_newtable(L);
    const ix::HttpResponsePtr safeResponse =
        response ? response
                 : std::make_shared<ix::HttpResponse>(
                       0, std::string(), ix::HttpErrorCode::Invalid,
                       ix::WebSocketHttpHeaders(), std::string(),
                       "empty HTTP response", 0, 0);

    switch (safeResponse->errorCode) {
      case ix::HttpErrorCode::Ok:
        lua_pushnil(L);
        break;
      case ix::HttpErrorCode::CannotConnect:
        LuaHelpers::Push(L, HttpErrorCode_CannotConnect);
        break;
      case ix::HttpErrorCode::Timeout:
        LuaHelpers::Push(L, HttpErrorCode_Timeout);
        break;
      case ix::HttpErrorCode::Gzip:
        LuaHelpers::Push(L, HttpErrorCode_Gzip);
        break;
      case ix::HttpErrorCode::UrlMalformed:
        LuaHelpers::Push(L, HttpErrorCode_UrlMalformed);
        break;
      case ix::HttpErrorCode::CannotCreateSocket:
        LuaHelpers::Push(L, HttpErrorCode_CannotCreateSocket);
        break;
      case ix::HttpErrorCode::SendError:
        LuaHelpers::Push(L, HttpErrorCode_SendError);
        break;
      case ix::HttpErrorCode::ReadError:
        LuaHelpers::Push(L, HttpErrorCode_ReadError);
        break;
      case ix::HttpErrorCode::CannotReadStatusLine:
        LuaHelpers::Push(L, HttpErrorCode_CannotReadStatusLine);
        break;
      case ix::HttpErrorCode::MissingStatus:
        LuaHelpers::Push(L, HttpErrorCode_MissingStatus);
        break;
      case ix::HttpErrorCode::HeaderParsingError:
        LuaHelpers::Push(L, HttpErrorCode_HeaderParsingError);
        break;
      case ix::HttpErrorCode::MissingLocation:
        LuaHelpers::Push(L, HttpErrorCode_MissingLocation);
        break;
      case ix::HttpErrorCode::TooManyRedirects:
        LuaHelpers::Push(L, HttpErrorCode_TooManyRedirects);
        break;
      case ix::HttpErrorCode::ChunkReadError:
        LuaHelpers::Push(L, HttpErrorCode_ChunkReadError);
        break;
      case ix::HttpErrorCode::CannotReadBody:
        LuaHelpers::Push(L, HttpErrorCode_CannotReadBody);
        break;
      case ix::HttpErrorCode::Cancelled:
        LuaHelpers::Push(L, HttpErrorCode_Cancelled);
        break;
      default:
        LuaHelpers::Push(L, HttpErrorCode_UnknownError);
        break;
    }
    lua_setfield(L, -2, "error");

    if (safeResponse->errorMsg == "") {
      lua_pushnil(L);
    } else {
      lua_pushstring(L, safeResponse->errorMsg.c_str());
    }
    lua_setfield(L, -2, "errorMessage");

    lua_pushinteger(L, safeResponse->statusCode);
    lua_setfield(L, -2, "statusCode");

    lua_newtable(L);
    std::size_t headerCount = 0;
    for (const auto& entry : safeResponse->headers) {
      if (++headerCount > kMaxHttpHeaderCount ||
          !IsSafeHttpHeaderName(entry.first) ||
          !IsSafeHeaderValue(entry.second)) {
        continue;
      }
      lua_pushstring(L, entry.second.c_str());
      lua_setfield(L, -2, entry.first.c_str());
    }
    lua_setfield(L, -2, "headers");

    lua_pushlstring(L, safeResponse->body.c_str(), safeResponse->body.length());
    lua_setfield(L, -2, "body");

    lua_pushnumber(L, safeResponse->uploadSize);
    lua_setfield(L, -2, "uploadSize");

    lua_pushnumber(L, safeResponse->downloadSize);
    lua_setfield(L, -2, "downloadSize");

    std::string error = "Lua error in HTTP response handler: ";
    LuaHelpers::RunScriptOnStack(L, error, 1, 0, true);
  }

  static bool handleProgress(
      Lua* L, int64_t current, int64_t total, int onProgressRef) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, onProgressRef);
    lua_pushinteger(L, current);
    lua_pushinteger(L, total);

    std::string error = "Lua error in HTTP progress handler: ";
    if (!LuaHelpers::RunScriptOnStack(L, error, 2, 1, true)) {
      return false;
    }
    bool keepGoing = true;
    if (lua_isboolean(L, -1)) {
      keepGoing = lua_toboolean(L, -1);
    }
    lua_pop(L, 1);
    return keepGoing;
  }

  static void handleMessage(
      Lua* L, ix::WebSocketMessageType type, const std::string& data,
      const ix::WebSocketErrorInfo& errorInfo,
      const ix::WebSocketOpenInfo& openInfo,
      const ix::WebSocketCloseInfo& closeInfo, bool binary, int onMessageRef) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, onMessageRef);

    lua_newtable(L);

    switch (type) {
      case ix::WebSocketMessageType::Message:
        LuaHelpers::Push(L, WebSocketMessageType_Message);
        lua_setfield(L, -2, "type");

        lua_pushlstring(L, data.c_str(), data.length());
        lua_setfield(L, -2, "data");

        lua_pushboolean(L, binary);
        lua_setfield(L, -2, "binary");
        break;
      case ix::WebSocketMessageType::Open: {
        LuaHelpers::Push(L, WebSocketMessageType_Open);
        lua_setfield(L, -2, "type");

        lua_pushstring(L, openInfo.uri.c_str());
        lua_setfield(L, -2, "uri");

        lua_newtable(L);
        std::size_t headerCount = 0;
        for (const auto& entry : openInfo.headers) {
          if (++headerCount > kMaxHttpHeaderCount ||
              !IsSafeHttpHeaderName(entry.first) ||
              !IsSafeHeaderValue(entry.second)) {
            continue;
          }
          lua_pushstring(L, entry.second.c_str());
          lua_setfield(L, -2, entry.first.c_str());
        }
        lua_setfield(L, -2, "headers");

        lua_pushstring(L, openInfo.protocol.c_str());
        lua_setfield(L, -2, "protocol");
        break;
      }
      case ix::WebSocketMessageType::Close:
        LuaHelpers::Push(L, WebSocketMessageType_Close);
        lua_setfield(L, -2, "type");

        lua_pushstring(L, closeInfo.reason.c_str());
        lua_setfield(L, -2, "reason");

        lua_pushboolean(L, closeInfo.remote);
        lua_setfield(L, -2, "remote");
        break;
      case ix::WebSocketMessageType::Error:
        LuaHelpers::Push(L, WebSocketMessageType_Error);
        lua_setfield(L, -2, "type");

        lua_pushinteger(L, errorInfo.retries);
        lua_setfield(L, -2, "retries");

        lua_pushnumber(L, errorInfo.wait_time);
        lua_setfield(L, -2, "waitTime");

        if (errorInfo.http_status > 0) {
          lua_pushinteger(L, errorInfo.http_status);
        } else {
          lua_pushnil(L);
        }
        lua_setfield(L, -2, "httpStatusCode");

        lua_pushstring(L, errorInfo.reason.c_str());
        lua_setfield(L, -2, "reason");

        lua_pushboolean(L, errorInfo.decompressionError);
        lua_setfield(L, -2, "decompressionError");
        break;
      case ix::WebSocketMessageType::Ping:
      case ix::WebSocketMessageType::Pong:
      case ix::WebSocketMessageType::Fragment:
      default:
        lua_pop(L, 2);
        return;
    }

    std::string error = "Lua error in WebSocket message handler: ";
    LuaHelpers::RunScriptOnStack(L, error, 1, 0, true);
  }
};

LUA_REGISTER_CLASS(NetworkManager)
// lua end

/*
 * (c) 2021 Martin Natano
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, and/or sell copies of the Software, and to permit persons to
 * whom the Software is furnished to do so, provided that the above
 * copyright notice(s) and this permission notice appear in all copies of
 * the Software and that both the above copyright notice(s) and this
 * permission notice appear in supporting documentation.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
 * THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
 * INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT
 * OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 */
