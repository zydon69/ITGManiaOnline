#ifndef TEEJUSB_FSR_MANAGER_H
#define TEEJUSB_FSR_MANAGER_H

#include <array>
#include <chrono>
#include <string>
#include <vector>

#include "LuaManager.h"

class TeejusbFsrManager {
 public:
  static constexpr int NUM_SENSORS = 4;

  TeejusbFsrManager();
  ~TeejusbFsrManager();

  std::vector<std::string> GetDevicePorts() const;
  bool ConnectAuto();
  bool Connect(const std::string& port);
  void Disconnect();
  bool IsConnected() const;

  void Poll();
  bool RequestValues();
  bool RequestThresholds();
  bool SetThreshold(int sensorIndexOneBased, int threshold);
  bool SaveThresholds();

  const std::string& GetPort() const { return m_sPort; }
  const std::string& GetStatus() const { return m_sStatus; }
  const std::array<int, NUM_SENSORS>& GetValues() const { return m_iValues; }
  const std::array<int, NUM_SENSORS>& GetThresholds() const {
    return m_iThresholds;
  }
  void PushSnapshot(lua_State* L) const;
  void PushSelf(lua_State* L);

 private:
  void CloseFd();
  bool WriteCommand(const std::string& command);
  void ReadAvailableLines();
  void ProcessLine(const std::string& line);
  void MaybeRequestValues();
  void SetStatus(const std::string& status);

  int m_iFd;
  std::string m_sPort;
  std::string m_sReadBuffer;
  std::string m_sStatus;
  std::string m_sLastResponse;
  std::array<int, NUM_SENSORS> m_iValues;
  std::array<int, NUM_SENSORS> m_iThresholds;
  std::chrono::steady_clock::time_point m_LastValueRequest;
};

extern TeejusbFsrManager* TEEJUSBFSR;

#endif
