#ifndef TEEJUSB_FSR_MANAGER_H
#define TEEJUSB_FSR_MANAGER_H

#include <array>
#include <chrono>
#include <cstdint>
#include <string>
#include <vector>

#include "LuaManager.h"

class TeejusbFsrManager {
 public:
  static constexpr int NUM_SENSORS = 4;
  static constexpr int NUM_ASSIGNABLE_PLAYERS = 4;

  TeejusbFsrManager();
  ~TeejusbFsrManager();
  TeejusbFsrManager(const TeejusbFsrManager&) = delete;
  TeejusbFsrManager& operator=(const TeejusbFsrManager&) = delete;

  std::vector<std::string> GetDevicePorts() const;

  bool ConnectAuto();
  bool Connect(const std::string& port);
  void Disconnect();
  bool IsConnected() const;

  void Poll();
  void PollAll();
  bool RequestValues();
  bool RequestThresholds();
  bool LoadThresholds();
  bool SetThreshold(int sensorIndexOneBased, int threshold);
  bool SaveThresholds();

  bool SetActivePort(const std::string& port);
  bool RequestValuesForPort(const std::string& port);
  bool RequestThresholdsForPort(const std::string& port);
  bool LoadThresholdsForPort(const std::string& port);
  bool SetThresholdForPort(
      const std::string& port, int sensorIndexOneBased, int threshold);
  bool SaveThresholdsForPort(const std::string& port);

  bool AssignPlayer(int playerIndexOneBased, const std::string& port);
  std::string GetAssignedPort(int playerIndexOneBased) const;
  bool SaveAssignments() const;
  void LoadAssignments();

  const std::string& GetPort() const { return m_sActivePort; }
  std::string GetStatus() const;
  std::array<int, NUM_SENSORS> GetValues() const;
  std::array<int, NUM_SENSORS> GetThresholds() const;

  void PushSnapshot(lua_State* L) const;
  void PushSnapshotForPort(lua_State* L, const std::string& port) const;
  void PushSnapshotForPlayer(lua_State* L, int playerIndexOneBased) const;
  void PushDevices(lua_State* L) const;
  void PushAssignments(lua_State* L) const;
  void PushSelf(lua_State* L);

 private:
  struct DeviceState {
    intptr_t fd = -1;
    std::string port;
    std::string readBuffer;
    std::string status = "Not connected";
    std::string notice;
    std::string lastResponse;
    bool protocolVerified = false;
    bool pendingThresholdLoad = false;
    bool pendingEepromSave = false;
    bool pendingEepromFinalCommand = false;
    int pendingEepromNextSensor = 0;
    std::array<int, NUM_SENSORS> values = {{0, 0, 0, 0}};
    std::array<int, NUM_SENSORS> thresholds = {{1000, 1000, 1000, 1000}};
    std::array<int, NUM_SENSORS> pendingEepromThresholds =
        {{1000, 1000, 1000, 1000}};
    std::chrono::steady_clock::time_point pendingCommandDeadline =
        std::chrono::steady_clock::time_point::min();
    std::chrono::steady_clock::time_point lastValueRequest =
        std::chrono::steady_clock::time_point::min();
    std::chrono::steady_clock::time_point noticeUntil =
        std::chrono::steady_clock::time_point::min();
    std::chrono::steady_clock::time_point reconnectAfter =
        std::chrono::steady_clock::time_point::min();
  };

  DeviceState* FindDevice(const std::string& port);
  const DeviceState* FindDevice(const std::string& port) const;
  DeviceState* FindOrCreateDevice(const std::string& port);
  DeviceState* GetActiveDevice();
  const DeviceState* GetActiveDevice() const;

  void SyncDeviceList();
  bool OpenDevice(DeviceState& device);
  void CloseDevice(DeviceState& device);
  void CloseAllDevices();
  bool WriteCommand(DeviceState& device, const std::string& command);
  bool SendNextEepromSaveCommand(DeviceState& device);
  void ResetPendingEepromSave(DeviceState& device);
  void FlushDeviceInput(DeviceState& device);
  void ReadAvailableLines(DeviceState& device);
  void ProcessLine(DeviceState& device, const std::string& line);
  void MaybeRequestValues(DeviceState& device);
  bool IsPortAssigned(const std::string& port) const;
  bool IsOperationPending(const DeviceState& device) const;
  void SetStatus(DeviceState& device, const std::string& status);
  void SetNotice(DeviceState& device, const std::string& notice);
  void PushDeviceSnapshot(lua_State* L, const DeviceState* device) const;

  std::vector<DeviceState> m_vDevices;
  std::string m_sActivePort;
  std::array<std::string, NUM_ASSIGNABLE_PLAYERS> m_sAssignedPorts;
  std::chrono::steady_clock::time_point m_LastDeviceScan =
      std::chrono::steady_clock::time_point::min();
};

extern TeejusbFsrManager* TEEJUSBFSR;

#endif
