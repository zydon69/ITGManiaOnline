#include "TeejusbFsrManager.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <sstream>

#include "LuaBinding.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "global.h"

#if defined(MACOSX) || defined(UNIX)
#include <dirent.h>
#include <fcntl.h>
#include <sys/select.h>
#include <termios.h>
#include <unistd.h>
#endif

TeejusbFsrManager* TEEJUSBFSR = nullptr;

namespace {
constexpr int kDefaultThreshold = 1000;
constexpr auto kValuePollInterval = std::chrono::milliseconds(40);

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

bool StartsWith(const std::string& value, const std::string& prefix) {
  return value.size() >= prefix.size() &&
         value.compare(0, prefix.size(), prefix) == 0;
}

void PushStringField(lua_State* L, const char* field, const std::string& value) {
  LuaHelpers::Push(L, value);
  lua_setfield(L, -2, field);
}

void PushBoolField(lua_State* L, const char* field, bool value) {
  LuaHelpers::Push(L, value);
  lua_setfield(L, -2, field);
}

void PushIntArrayField(
    lua_State* L,
    const char* field,
    const std::array<int, TeejusbFsrManager::NUM_SENSORS>& values) {
  lua_newtable(L);
  for (int i = 0; i < TeejusbFsrManager::NUM_SENSORS; ++i) {
    LuaHelpers::Push(L, values[i]);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, field);
}

#if defined(MACOSX) || defined(UNIX)
void AddMatchingDevicePorts(
    const std::string& directory,
    const std::vector<std::string>& prefixes,
    std::vector<std::string>& ports) {
  DIR* dir = opendir(directory.c_str());
  if (dir == nullptr) {
    return;
  }

  while (dirent* entry = readdir(dir)) {
    const std::string name = entry->d_name;
    for (const std::string& prefix : prefixes) {
      if (StartsWith(name, prefix)) {
        ports.push_back(directory + "/" + name);
        break;
      }
    }
  }

  closedir(dir);
}

bool ConfigureSerialPort(int fd) {
  termios attrs;
  if (tcgetattr(fd, &attrs) != 0) {
    return false;
  }

  attrs.c_iflag = 0;
  attrs.c_oflag = 0;
  attrs.c_lflag = 0;
  attrs.c_cflag |= CLOCAL | CREAD;
  attrs.c_cflag &= ~CSIZE;
  attrs.c_cflag |= CS8;
  attrs.c_cflag &= ~PARENB;
  attrs.c_cflag &= ~CSTOPB;
  attrs.c_cflag &= ~CRTSCTS;
  attrs.c_cc[VMIN] = 0;
  attrs.c_cc[VTIME] = 0;

  cfsetispeed(&attrs, B115200);
  cfsetospeed(&attrs, B115200);

  if (tcsetattr(fd, TCSANOW, &attrs) != 0) {
    return false;
  }

  tcflush(fd, TCIOFLUSH);
  return true;
}
#endif
}  // namespace

TeejusbFsrManager::TeejusbFsrManager()
    : m_iFd(-1),
      m_iValues{0, 0, 0, 0},
      m_iThresholds{
          kDefaultThreshold, kDefaultThreshold, kDefaultThreshold,
          kDefaultThreshold},
      m_LastValueRequest(std::chrono::steady_clock::time_point::min()) {
  SetStatus("Not connected");

  WithLua([this](Lua* L) {
    this->PushSelf(L);
    lua_setglobal(L, "TEEJUSBFSR");
  });
}

TeejusbFsrManager::~TeejusbFsrManager() { Disconnect(); }

std::vector<std::string> TeejusbFsrManager::GetDevicePorts() const {
  std::vector<std::string> ports;
#if defined(MACOSX)
  AddMatchingDevicePorts("/dev", {"cu.usbmodem"}, ports);
#elif defined(UNIX)
  AddMatchingDevicePorts("/dev", {"ttyACM", "ttyUSB", "cu.usbmodem"}, ports);
#endif
  std::sort(ports.begin(), ports.end());
  ports.erase(std::unique(ports.begin(), ports.end()), ports.end());
  return ports;
}

bool TeejusbFsrManager::ConnectAuto() {
  for (const std::string& port : GetDevicePorts()) {
    if (Connect(port)) {
      return true;
    }
  }

  SetStatus("No teejusb-fsr serial device found");
  return false;
}

bool TeejusbFsrManager::Connect(const std::string& port) {
  Disconnect();

#if defined(MACOSX) || defined(UNIX)
  int fd = open(port.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK);
  if (fd < 0) {
    SetStatus("Open failed: " + std::string(std::strerror(errno)));
    return false;
  }

  if (!ConfigureSerialPort(fd)) {
    const std::string error = std::strerror(errno);
    close(fd);
    SetStatus("Serial setup failed: " + error);
    return false;
  }

  m_iFd = fd;
  m_sPort = port;
  m_sReadBuffer.clear();
  m_sLastResponse.clear();
  m_LastValueRequest = std::chrono::steady_clock::time_point::min();
  SetStatus("Connected");
  RequestThresholds();
  return true;
#else
  SetStatus("Serial teejusb-fsr support is unavailable on this platform");
  return false;
#endif
}

void TeejusbFsrManager::Disconnect() {
  CloseFd();
  m_sPort.clear();
  m_sReadBuffer.clear();
  SetStatus("Not connected");
}

bool TeejusbFsrManager::IsConnected() const { return m_iFd >= 0; }

void TeejusbFsrManager::Poll() {
  if (!IsConnected()) {
    return;
  }

  MaybeRequestValues();
  ReadAvailableLines();
}

bool TeejusbFsrManager::RequestValues() { return WriteCommand("v"); }

bool TeejusbFsrManager::RequestThresholds() { return WriteCommand("t"); }

bool TeejusbFsrManager::SetThreshold(int sensorIndexOneBased, int threshold) {
  if (sensorIndexOneBased < 1 || sensorIndexOneBased > NUM_SENSORS) {
    SetStatus("Invalid sensor index");
    return false;
  }

  rage_clamp(threshold, 0, 1023);
  m_iThresholds[sensorIndexOneBased - 1] = threshold;

  std::ostringstream command;
  command << (sensorIndexOneBased - 1) << " " << threshold;
  return WriteCommand(command.str());
}

bool TeejusbFsrManager::SaveThresholds() { return WriteCommand("s"); }

void TeejusbFsrManager::PushSnapshot(lua_State* L) const {
  lua_newtable(L);
  PushBoolField(L, "connected", IsConnected());
  PushStringField(L, "port", m_sPort);
  PushStringField(L, "status", m_sStatus);
  PushStringField(L, "last_response", m_sLastResponse);
  PushIntArrayField(L, "values", m_iValues);
  PushIntArrayField(L, "thresholds", m_iThresholds);
}

void TeejusbFsrManager::CloseFd() {
#if defined(MACOSX) || defined(UNIX)
  if (m_iFd >= 0) {
    close(m_iFd);
  }
#endif
  m_iFd = -1;
}

bool TeejusbFsrManager::WriteCommand(const std::string& command) {
  if (!IsConnected()) {
    SetStatus("Not connected");
    return false;
  }

#if defined(MACOSX) || defined(UNIX)
  std::string payload = command;
  if (payload.empty() || payload.back() != '\n') {
    payload += '\n';
  }

  std::size_t offset = 0;
  while (offset < payload.size()) {
    const ssize_t written =
        write(m_iFd, payload.data() + offset, payload.size() - offset);
    if (written < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        continue;
      }

      const std::string error = std::strerror(errno);
      Disconnect();
      SetStatus("Write failed: " + error);
      return false;
    }

    if (written == 0) {
      Disconnect();
      SetStatus("Write failed: no bytes written");
      return false;
    }

    offset += static_cast<std::size_t>(written);
  }
  return true;
#else
  SetStatus("Serial teejusb-fsr support is unavailable on this platform");
  return false;
#endif
}

void TeejusbFsrManager::ReadAvailableLines() {
#if defined(MACOSX) || defined(UNIX)
  if (!IsConnected()) {
    return;
  }

  for (;;) {
    fd_set readSet;
    FD_ZERO(&readSet);
    FD_SET(m_iFd, &readSet);

    timeval timeout;
    timeout.tv_sec = 0;
    timeout.tv_usec = 0;

    const int ready = select(m_iFd + 1, &readSet, nullptr, nullptr, &timeout);
    if (ready <= 0) {
      break;
    }

    char buffer[512];
    const ssize_t bytesRead = read(m_iFd, buffer, sizeof(buffer));
    if (bytesRead > 0) {
      m_sReadBuffer.append(buffer, static_cast<std::size_t>(bytesRead));
      continue;
    }

    if (bytesRead == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) {
      const std::string error = bytesRead == 0 ? "Device disconnected"
                                               : std::strerror(errno);
      Disconnect();
      SetStatus(error);
    }
    break;
  }

  std::size_t newline = std::string::npos;
  while ((newline = m_sReadBuffer.find('\n')) != std::string::npos) {
    std::string line = m_sReadBuffer.substr(0, newline);
    m_sReadBuffer.erase(0, newline + 1);
    Trim(line);
    if (!line.empty()) {
      ProcessLine(line);
    }
  }
#endif
}

void TeejusbFsrManager::ProcessLine(const std::string& line) {
  m_sLastResponse = line;

  std::vector<std::string> parts;
  split(line, " ", parts, true);
  if (parts.size() != NUM_SENSORS + 1) {
    return;
  }

  std::array<int, NUM_SENSORS> parsed{};
  for (int i = 0; i < NUM_SENSORS; ++i) {
    parsed[i] = StringToInt(parts[i + 1]);
  }

  const std::string& command = parts[0];
  if (command == "v" || command == "V") {
    m_iValues = parsed;
    SetStatus("Connected");
  } else if (command == "t" || command == "T" || command == "s" ||
             command == "S") {
    m_iThresholds = parsed;
    SetStatus(command == "s" || command == "S" ? "Thresholds saved"
                                                : "Connected");
  }
}

void TeejusbFsrManager::MaybeRequestValues() {
  const auto now = std::chrono::steady_clock::now();
  if (m_LastValueRequest != std::chrono::steady_clock::time_point::min() &&
      now - m_LastValueRequest < kValuePollInterval) {
    return;
  }

  if (RequestValues()) {
    m_LastValueRequest = now;
  }
}

void TeejusbFsrManager::SetStatus(const std::string& status) {
  m_sStatus = status;
}

// lua start
class LunaTeejusbFsrManager : public Luna<TeejusbFsrManager> {
 public:
  static int GetDevicePorts(T* p, lua_State* L) {
    LuaHelpers::CreateTableFromArray(p->GetDevicePorts(), L);
    return 1;
  }

  static int ConnectAuto(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->ConnectAuto());
    return 1;
  }

  static int Connect(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->Connect(SArg(1)));
    return 1;
  }

  static int Disconnect(T* p, lua_State* L) {
    p->Disconnect();
    COMMON_RETURN_SELF;
  }

  static int Poll(T* p, lua_State* L) {
    p->Poll();
    p->PushSnapshot(L);
    return 1;
  }

  static int GetSnapshot(T* p, lua_State* L) {
    p->PushSnapshot(L);
    return 1;
  }

  static int RequestValues(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->RequestValues());
    return 1;
  }

  static int RequestThresholds(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->RequestThresholds());
    return 1;
  }

  static int SetThreshold(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->SetThreshold(IArg(1), IArg(2)));
    return 1;
  }

  static int SaveThresholds(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->SaveThresholds());
    return 1;
  }

  LunaTeejusbFsrManager() {
    ADD_METHOD(GetDevicePorts);
    ADD_METHOD(ConnectAuto);
    ADD_METHOD(Connect);
    ADD_METHOD(Disconnect);
    ADD_METHOD(Poll);
    ADD_METHOD(GetSnapshot);
    ADD_METHOD(RequestValues);
    ADD_METHOD(RequestThresholds);
    ADD_METHOD(SetThreshold);
    ADD_METHOD(SaveThresholds);
  }
};

LUA_REGISTER_CLASS(TeejusbFsrManager)
