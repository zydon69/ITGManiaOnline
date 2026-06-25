#include "TeejusbFsrManager.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <sstream>

#include "IniFile.h"
#include "LuaBinding.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "SpecialFiles.h"
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
constexpr auto kDeviceScanInterval = std::chrono::milliseconds(1000);
constexpr auto kValuePollInterval = std::chrono::milliseconds(40);
const std::string kAssignmentsPath = "Save/TeejusbFsr.ini";

std::chrono::steady_clock::time_point g_LastDeviceScan =
    std::chrono::steady_clock::time_point::min();

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

std::string PlayerAssignmentKey(int playerIndexOneBased) {
  return "Player" + std::to_string(playerIndexOneBased);
}

bool IsValidAssignablePlayer(int playerIndexOneBased) {
  return playerIndexOneBased >= 1 &&
         playerIndexOneBased <= TeejusbFsrManager::NUM_ASSIGNABLE_PLAYERS;
}

void PushStringField(lua_State* L, const char* field, const std::string& value) {
  LuaHelpers::Push(L, value);
  lua_setfield(L, -2, field);
}

void PushBoolField(lua_State* L, const char* field, bool value) {
  LuaHelpers::Push(L, value);
  lua_setfield(L, -2, field);
}

void PushIntField(lua_State* L, const char* field, int value) {
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

TeejusbFsrManager::TeejusbFsrManager() {
  m_sAssignedPorts.fill("");
  LoadAssignments();

  WithLua([this](Lua* L) {
    this->PushSelf(L);
    lua_setglobal(L, "TEEJUSBFSR");
  });
}

TeejusbFsrManager::~TeejusbFsrManager() { CloseAllDevices(); }

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
  SyncDeviceList();
  for (DeviceState& device : m_vDevices) {
    if (OpenDevice(device)) {
      m_sActivePort = device.port;
      RequestThresholdsForPort(device.port);
      return true;
    }
  }
  return false;
}

bool TeejusbFsrManager::Connect(const std::string& port) {
  DeviceState* device = FindOrCreateDevice(port);
  if (device == nullptr) {
    return false;
  }

  if (!OpenDevice(*device)) {
    return false;
  }

  m_sActivePort = port;
  RequestThresholdsForPort(port);
  return true;
}

void TeejusbFsrManager::Disconnect() {
  DeviceState* device = GetActiveDevice();
  if (device != nullptr) {
    CloseDevice(*device);
  }
  m_sActivePort.clear();
}

bool TeejusbFsrManager::IsConnected() const {
  const DeviceState* device = GetActiveDevice();
  return device != nullptr && device->fd >= 0;
}

void TeejusbFsrManager::Poll() {
  PollAll();
  DeviceState* device = GetActiveDevice();
  if (device == nullptr && !m_vDevices.empty()) {
    m_sActivePort = m_vDevices.front().port;
  }
}

void TeejusbFsrManager::PollAll() {
  const auto now = std::chrono::steady_clock::now();
  if (g_LastDeviceScan == std::chrono::steady_clock::time_point::min() ||
      now - g_LastDeviceScan >= kDeviceScanInterval) {
    SyncDeviceList();
    g_LastDeviceScan = now;
  }

  for (DeviceState& device : m_vDevices) {
    if (device.fd < 0) {
      OpenDevice(device);
    }
    if (device.fd >= 0) {
      MaybeRequestValues(device);
      ReadAvailableLines(device);
    }
  }
}

bool TeejusbFsrManager::RequestValues() {
  DeviceState* device = GetActiveDevice();
  return device != nullptr && WriteCommand(*device, "v");
}

bool TeejusbFsrManager::RequestThresholds() {
  DeviceState* device = GetActiveDevice();
  return device != nullptr && WriteCommand(*device, "t");
}

bool TeejusbFsrManager::SetThreshold(int sensorIndexOneBased, int threshold) {
  return SetThresholdForPort(m_sActivePort, sensorIndexOneBased, threshold);
}

bool TeejusbFsrManager::SaveThresholds() {
  return SaveThresholdsForPort(m_sActivePort);
}

bool TeejusbFsrManager::SetActivePort(const std::string& port) {
  DeviceState* device = FindOrCreateDevice(port);
  if (device == nullptr) {
    return false;
  }
  m_sActivePort = port;
  return OpenDevice(*device);
}

bool TeejusbFsrManager::RequestValuesForPort(const std::string& port) {
  DeviceState* device = FindDevice(port);
  return device != nullptr && WriteCommand(*device, "v");
}

bool TeejusbFsrManager::RequestThresholdsForPort(const std::string& port) {
  DeviceState* device = FindDevice(port);
  return device != nullptr && WriteCommand(*device, "t");
}

bool TeejusbFsrManager::SetThresholdForPort(
    const std::string& port, int sensorIndexOneBased, int threshold) {
  DeviceState* device = FindDevice(port);
  if (device == nullptr) {
    return false;
  }

  if (sensorIndexOneBased < 1 || sensorIndexOneBased > NUM_SENSORS) {
    SetStatus(*device, "Invalid sensor index");
    return false;
  }

  rage_clamp(threshold, 0, 1023);
  device->thresholds[sensorIndexOneBased - 1] = threshold;

  std::ostringstream command;
  command << (sensorIndexOneBased - 1) << " " << threshold;
  return WriteCommand(*device, command.str());
}

bool TeejusbFsrManager::SaveThresholdsForPort(const std::string& port) {
  DeviceState* device = FindDevice(port);
  return device != nullptr && WriteCommand(*device, "s");
}

bool TeejusbFsrManager::AssignPlayer(
    int playerIndexOneBased, const std::string& port) {
  if (!IsValidAssignablePlayer(playerIndexOneBased)) {
    return false;
  }

  if (!port.empty()) {
    for (std::string& assignedPort : m_sAssignedPorts) {
      if (assignedPort == port) {
        assignedPort.clear();
      }
    }
  }
  m_sAssignedPorts[playerIndexOneBased - 1] = port;
  if (!port.empty()) {
    SetActivePort(port);
  }
  return SaveAssignments();
}

std::string TeejusbFsrManager::GetAssignedPort(int playerIndexOneBased) const {
  if (!IsValidAssignablePlayer(playerIndexOneBased)) {
    return "";
  }
  return m_sAssignedPorts[playerIndexOneBased - 1];
}

bool TeejusbFsrManager::SaveAssignments() const {
  IniFile ini;
  for (int i = 1; i <= NUM_ASSIGNABLE_PLAYERS; ++i) {
    ini.SetValue("Assignments", PlayerAssignmentKey(i), m_sAssignedPorts[i - 1]);
  }
  return ini.WriteFile(kAssignmentsPath);
}

void TeejusbFsrManager::LoadAssignments() {
  IniFile ini;
  if (!ini.ReadFile(kAssignmentsPath)) {
    return;
  }

  for (int i = 1; i <= NUM_ASSIGNABLE_PLAYERS; ++i) {
    std::string port;
    if (ini.GetValue("Assignments", PlayerAssignmentKey(i), port)) {
      m_sAssignedPorts[i - 1] = port;
    }
  }
}

std::string TeejusbFsrManager::GetStatus() const {
  const DeviceState* device = GetActiveDevice();
  return device == nullptr ? "Not connected" : device->status;
}

std::array<int, TeejusbFsrManager::NUM_SENSORS> TeejusbFsrManager::GetValues()
    const {
  const DeviceState* device = GetActiveDevice();
  return device == nullptr ? std::array<int, NUM_SENSORS>{{0, 0, 0, 0}}
                           : device->values;
}

std::array<int, TeejusbFsrManager::NUM_SENSORS>
TeejusbFsrManager::GetThresholds() const {
  const DeviceState* device = GetActiveDevice();
  return device == nullptr
             ? std::array<int, NUM_SENSORS>{{kDefaultThreshold,
                                             kDefaultThreshold,
                                             kDefaultThreshold,
                                             kDefaultThreshold}}
             : device->thresholds;
}

void TeejusbFsrManager::PushSnapshot(lua_State* L) const {
  PushDeviceSnapshot(L, GetActiveDevice());
}

void TeejusbFsrManager::PushSnapshotForPort(
    lua_State* L, const std::string& port) const {
  PushDeviceSnapshot(L, FindDevice(port));
}

void TeejusbFsrManager::PushSnapshotForPlayer(
    lua_State* L, int playerIndexOneBased) const {
  if (!IsValidAssignablePlayer(playerIndexOneBased)) {
    PushDeviceSnapshot(L, nullptr);
    return;
  }
  PushDeviceSnapshot(L, FindDevice(m_sAssignedPorts[playerIndexOneBased - 1]));
}

void TeejusbFsrManager::PushDevices(lua_State* L) const {
  lua_newtable(L);
  for (size_t i = 0; i < m_vDevices.size(); ++i) {
    PushDeviceSnapshot(L, &m_vDevices[i]);
    lua_rawseti(L, -2, static_cast<int>(i + 1));
  }
}

void TeejusbFsrManager::PushAssignments(lua_State* L) const {
  lua_newtable(L);
  for (int i = 1; i <= NUM_ASSIGNABLE_PLAYERS; ++i) {
    LuaHelpers::Push(L, m_sAssignedPorts[i - 1]);
    lua_rawseti(L, -2, i);
  }
}

TeejusbFsrManager::DeviceState* TeejusbFsrManager::FindDevice(
    const std::string& port) {
  const auto it = std::find_if(
      m_vDevices.begin(), m_vDevices.end(),
      [&port](const DeviceState& device) { return device.port == port; });
  return it == m_vDevices.end() ? nullptr : &(*it);
}

const TeejusbFsrManager::DeviceState* TeejusbFsrManager::FindDevice(
    const std::string& port) const {
  const auto it = std::find_if(
      m_vDevices.begin(), m_vDevices.end(),
      [&port](const DeviceState& device) { return device.port == port; });
  return it == m_vDevices.end() ? nullptr : &(*it);
}

TeejusbFsrManager::DeviceState* TeejusbFsrManager::FindOrCreateDevice(
    const std::string& port) {
  if (port.empty()) {
    return nullptr;
  }

  DeviceState* existing = FindDevice(port);
  if (existing != nullptr) {
    return existing;
  }

  DeviceState device;
  device.port = port;
  device.status = "Not connected";
  device.thresholds.fill(kDefaultThreshold);
  m_vDevices.push_back(device);
  return &m_vDevices.back();
}

TeejusbFsrManager::DeviceState* TeejusbFsrManager::GetActiveDevice() {
  if (m_sActivePort.empty()) {
    if (!m_sAssignedPorts[0].empty()) {
      m_sActivePort = m_sAssignedPorts[0];
    } else if (!m_vDevices.empty()) {
      m_sActivePort = m_vDevices.front().port;
    }
  }
  return FindDevice(m_sActivePort);
}

const TeejusbFsrManager::DeviceState* TeejusbFsrManager::GetActiveDevice()
    const {
  if (!m_sActivePort.empty()) {
    return FindDevice(m_sActivePort);
  }
  if (!m_sAssignedPorts[0].empty()) {
    return FindDevice(m_sAssignedPorts[0]);
  }
  return m_vDevices.empty() ? nullptr : &m_vDevices.front();
}

void TeejusbFsrManager::SyncDeviceList() {
  const std::vector<std::string> ports = GetDevicePorts();

  for (auto it = m_vDevices.begin(); it != m_vDevices.end();) {
    if (std::find(ports.begin(), ports.end(), it->port) == ports.end()) {
      CloseDevice(*it);
      if (m_sActivePort == it->port) {
        m_sActivePort.clear();
      }
      it = m_vDevices.erase(it);
    } else {
      ++it;
    }
  }

  for (const std::string& port : ports) {
    FindOrCreateDevice(port);
  }
}

bool TeejusbFsrManager::OpenDevice(DeviceState& device) {
  if (device.fd >= 0) {
    return true;
  }

#if defined(MACOSX) || defined(UNIX)
  const int fd = open(device.port.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK);
  if (fd < 0) {
    SetStatus(device, "Open failed: " + std::string(std::strerror(errno)));
    return false;
  }

  if (!ConfigureSerialPort(fd)) {
    const std::string error = std::strerror(errno);
    close(fd);
    SetStatus(device, "Serial setup failed: " + error);
    return false;
  }

  device.fd = fd;
  device.readBuffer.clear();
  device.lastResponse.clear();
  device.lastValueRequest = std::chrono::steady_clock::time_point::min();
  SetStatus(device, "Connected");
  WriteCommand(device, "t");
  return true;
#else
  SetStatus(device, "Serial teejusb-fsr support is unavailable");
  return false;
#endif
}

void TeejusbFsrManager::CloseDevice(DeviceState& device) {
#if defined(MACOSX) || defined(UNIX)
  if (device.fd >= 0) {
    close(device.fd);
  }
#endif
  device.fd = -1;
  device.readBuffer.clear();
  SetStatus(device, "Not connected");
}

void TeejusbFsrManager::CloseAllDevices() {
  for (DeviceState& device : m_vDevices) {
    CloseDevice(device);
  }
  m_sActivePort.clear();
}

bool TeejusbFsrManager::WriteCommand(
    DeviceState& device, const std::string& command) {
  if (device.fd < 0 && !OpenDevice(device)) {
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
        write(device.fd, payload.data() + offset, payload.size() - offset);
    if (written < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        continue;
      }

      const std::string error = std::strerror(errno);
      CloseDevice(device);
      SetStatus(device, "Write failed: " + error);
      return false;
    }

    if (written == 0) {
      CloseDevice(device);
      SetStatus(device, "Write failed: no bytes written");
      return false;
    }

    offset += static_cast<std::size_t>(written);
  }
  return true;
#else
  SetStatus(device, "Serial teejusb-fsr support is unavailable");
  return false;
#endif
}

void TeejusbFsrManager::ReadAvailableLines(DeviceState& device) {
#if defined(MACOSX) || defined(UNIX)
  if (device.fd < 0) {
    return;
  }

  for (;;) {
    fd_set readSet;
    FD_ZERO(&readSet);
    FD_SET(device.fd, &readSet);

    timeval timeout;
    timeout.tv_sec = 0;
    timeout.tv_usec = 0;

    const int ready = select(device.fd + 1, &readSet, nullptr, nullptr, &timeout);
    if (ready <= 0) {
      break;
    }

    char buffer[512];
    const ssize_t bytesRead = read(device.fd, buffer, sizeof(buffer));
    if (bytesRead > 0) {
      device.readBuffer.append(buffer, static_cast<std::size_t>(bytesRead));
      continue;
    }

    if (bytesRead == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) {
      const std::string error = bytesRead == 0 ? "Device disconnected"
                                               : std::strerror(errno);
      CloseDevice(device);
      SetStatus(device, error);
    }
    break;
  }

  std::size_t newline = std::string::npos;
  while ((newline = device.readBuffer.find('\n')) != std::string::npos) {
    std::string line = device.readBuffer.substr(0, newline);
    device.readBuffer.erase(0, newline + 1);
    Trim(line);
    if (!line.empty()) {
      ProcessLine(device, line);
    }
  }
#endif
}

void TeejusbFsrManager::ProcessLine(DeviceState& device, const std::string& line) {
  device.lastResponse = line;

  std::vector<std::string> parts;
  split(line, " ", parts, true);
  if (parts.size() == 2 && (parts[0] == "s" || parts[0] == "S")) {
    SetStatus(device, "Thresholds saved");
    return;
  }

  if (parts.size() != NUM_SENSORS + 1) {
    return;
  }

  std::array<int, NUM_SENSORS> parsed{};
  for (int i = 0; i < NUM_SENSORS; ++i) {
    parsed[i] = StringToInt(parts[i + 1]);
  }

  const std::string& command = parts[0];
  if (command == "v" || command == "V") {
    device.values = parsed;
    SetStatus(device, "Connected");
  } else if (command == "t" || command == "T" || command == "s" ||
             command == "S") {
    device.thresholds = parsed;
    SetStatus(device, command == "s" || command == "S" ? "Thresholds saved"
                                                        : "Connected");
  }
}

void TeejusbFsrManager::MaybeRequestValues(DeviceState& device) {
  const auto now = std::chrono::steady_clock::now();
  if (device.lastValueRequest != std::chrono::steady_clock::time_point::min() &&
      now - device.lastValueRequest < kValuePollInterval) {
    return;
  }

  if (WriteCommand(device, "v")) {
    device.lastValueRequest = now;
  }
}

void TeejusbFsrManager::SetStatus(
    DeviceState& device, const std::string& status) {
  device.status = status;
}

void TeejusbFsrManager::PushDeviceSnapshot(
    lua_State* L, const DeviceState* device) const {
  lua_newtable(L);
  PushBoolField(L, "connected", device != nullptr && device->fd >= 0);
  PushStringField(L, "port", device == nullptr ? "" : device->port);
  PushStringField(
      L, "status", device == nullptr ? "Not connected" : device->status);
  PushStringField(
      L, "last_response", device == nullptr ? "" : device->lastResponse);
  PushIntArrayField(
      L, "values",
      device == nullptr ? std::array<int, NUM_SENSORS>{{0, 0, 0, 0}}
                        : device->values);
  PushIntArrayField(
      L, "thresholds",
      device == nullptr
          ? std::array<int, NUM_SENSORS>{{kDefaultThreshold, kDefaultThreshold,
                                          kDefaultThreshold, kDefaultThreshold}}
          : device->thresholds);
  for (int i = 1; i <= NUM_ASSIGNABLE_PLAYERS; ++i) {
    if (device != nullptr && m_sAssignedPorts[i - 1] == device->port) {
      PushIntField(L, "assigned_player", i);
      return;
    }
  }
  PushIntField(L, "assigned_player", 0);
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

  static int PollAll(T* p, lua_State* L) {
    p->PollAll();
    p->PushDevices(L);
    return 1;
  }

  static int GetSnapshot(T* p, lua_State* L) {
    p->PushSnapshot(L);
    return 1;
  }

  static int GetSnapshotForPort(T* p, lua_State* L) {
    p->PushSnapshotForPort(L, SArg(1));
    return 1;
  }

  static int GetSnapshotForPlayer(T* p, lua_State* L) {
    p->PushSnapshotForPlayer(L, IArg(1));
    return 1;
  }

  static int GetAssignments(T* p, lua_State* L) {
    p->PushAssignments(L);
    return 1;
  }

  static int GetAssignedPort(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->GetAssignedPort(IArg(1)));
    return 1;
  }

  static int AssignPlayer(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->AssignPlayer(IArg(1), SArg(2)));
    return 1;
  }

  static int SetActivePort(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->SetActivePort(SArg(1)));
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

  static int RequestThresholdsForPort(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->RequestThresholdsForPort(SArg(1)));
    return 1;
  }

  static int SetThresholdForPort(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->SetThresholdForPort(SArg(1), IArg(2), IArg(3)));
    return 1;
  }

  static int SaveThresholdsForPort(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->SaveThresholdsForPort(SArg(1)));
    return 1;
  }

  LunaTeejusbFsrManager() {
    ADD_METHOD(GetDevicePorts);
    ADD_METHOD(ConnectAuto);
    ADD_METHOD(Connect);
    ADD_METHOD(Disconnect);
    ADD_METHOD(Poll);
    ADD_METHOD(PollAll);
    ADD_METHOD(GetSnapshot);
    ADD_METHOD(GetSnapshotForPort);
    ADD_METHOD(GetSnapshotForPlayer);
    ADD_METHOD(GetAssignments);
    ADD_METHOD(GetAssignedPort);
    ADD_METHOD(AssignPlayer);
    ADD_METHOD(SetActivePort);
    ADD_METHOD(RequestValues);
    ADD_METHOD(RequestThresholds);
    ADD_METHOD(SetThreshold);
    ADD_METHOD(SaveThresholds);
    ADD_METHOD(RequestThresholdsForPort);
    ADD_METHOD(SetThresholdForPort);
    ADD_METHOD(SaveThresholdsForPort);
  }
};

LUA_REGISTER_CLASS(TeejusbFsrManager)
