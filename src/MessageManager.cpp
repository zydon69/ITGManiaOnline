#include "MessageManager.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "EnumHelper.h"
#include "LuaManager.h"
#include "PerfDiagnostics.h"
#include "RageLog.h"
#include "RageThreads.h"
#include "global.h"

MessageManager* MESSAGEMAN =
    nullptr;  // global and accessible from anywhere in our program

static const char* MessageIDNames[] = {
    "CurrentGameChanged",
    "CurrentStyleChanged",
    "PlayModeChanged",
    "CoinsChanged",
    "CurrentSongChanged",
    "CurrentStepsP1Changed",
    "CurrentStepsP2Changed",
    "CurrentCourseChanged",
    "CurrentTrailP1Changed",
    "CurrentTrailP2Changed",
    "GameplayLeadInChanged",
    "EditStepsTypeChanged",
    "EditCourseDifficultyChanged",
    "EditSourceStepsChanged",
    "EditSourceStepsTypeChanged",
    "PreferredStepsTypeChanged",
    "PreferredDifficultyP1Changed",
    "PreferredDifficultyP2Changed",
    "PreferredCourseDifficultyP1Changed",
    "PreferredCourseDifficultyP2Changed",
    "EditCourseEntryIndexChanged",
    "EditLocalProfileIDChanged",
    "GoalCompleteP1",
    "GoalCompleteP2",
    "NoteCrossed",
    "NoteWillCrossIn400Ms",
    "NoteWillCrossIn800Ms",
    "NoteWillCrossIn1200Ms",
    "CardRemovedP1",
    "CardRemovedP2",
    "BeatCrossed",
    "MenuUpP1",
    "MenuUpP2",
    "MenuDownP1",
    "MenuDownP2",
    "MenuLeftP1",
    "MenuLeftP2",
    "MenuRightP1",
    "MenuRightP2",
    "MenuStartP1",
    "MenuStartP2",
    "MenuSelectionChanged",
    "PlayerJoined",
    "PlayerUnjoined",
    "PlayerProfileSet",
    "AutosyncChanged",
    "PreferredSongGroupChanged",
    "PreferredCourseGroupChanged",
    "SortOrderChanged",
    "LessonTry1",
    "LessonTry2",
    "LessonTry3",
    "LessonCleared",
    "LessonFailed",
    "StorageDevicesChanged",
    "AutoJoyMappingApplied",
    "ScreenChanged",
    "SongModified",
    "ScoreMultiplierChangedP1",
    "ScoreMultiplierChangedP2",
    "StarPowerChangedP1",
    "StarPowerChangedP2",
    "CurrentComboChangedP1",
    "CurrentComboChangedP2",
    "StarMeterChangedP1",
    "StarMeterChangedP2",
    "LifeMeterChangedP1",
    "LifeMeterChangedP2",
    "UpdateScreenHeader",
    "LeftClick",
    "RightClick",
    "MiddleClick",
    "MouseWheelUp",
    "MouseWheelDown",
};
XToString(MessageID);

static RageMutex g_Mutex("MessageManager");

typedef std::set<IMessageSubscriber*> SubscribersSet;
static std::map<std::string, SubscribersSet> g_MessageToSubscribers;

static bool MessageNameStartsWith(
    const std::string& messageName, const std::string& prefix) {
  return messageName.compare(0, prefix.size(), prefix) == 0;
}

static bool OnlineVerboseLogsEnabledFromThemePrefs() {
  return OnlineNetworkDiagnosticsEnabled();
}

static bool ShouldTraceOnlineMessage(const std::string& messageName) {
  if (!OnlineVerboseLogsEnabledFromThemePrefs()) {
    return false;
  }
  if (messageName.find("OnlineRealtimeHealth") != std::string::npos) {
    return false;
  }
  // These are high-frequency state replication messages. Their Lua owners
  // already emit throttled, domain-specific diagnostics; tracing every
  // broadcast here drowns out the room transitions needed for investigation.
  if (messageName == "OnlineLobbyState" ||
      messageName == "OnlinePackSyncLocalStatus") {
    return false;
  }
  return MessageNameStartsWith(messageName, "Online") ||
         MessageNameStartsWith(messageName, "ITGOnline") ||
         MessageNameStartsWith(messageName, "Lobby") ||
         messageName == "ConnectOnline" || messageName == "DisconnectOnline" ||
         messageName == "CreateLobby" || messageName == "JoinLobby" ||
         messageName == "LeaveLobby" || messageName == "SearchLobby" ||
         messageName == "StartOnlineRoom" ||
         messageName == "InviteOnlinePlayer" ||
         messageName == "JoinOnlinePlayerRoom" ||
         messageName == "AnswerPrivateJoinRequest" ||
         messageName == "AnswerRoomInvitation";
}

static std::string LuaStringSummary(const char* value) {
  std::string text = value == nullptr ? "" : value;
  const size_t originalLength = text.size();

  for (char& c : text) {
    if (std::iscntrl(static_cast<unsigned char>(c))) {
      c = ' ';
    }
  }

  std::string lower = text;
  std::transform(
      lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
      });
  if (lower.find("bearer ") != std::string::npos ||
      lower.find("access_token") != std::string::npos ||
      lower.find("access-token") != std::string::npos ||
      lower.find("token=") != std::string::npos ||
      lower.find("token:") != std::string::npos ||
      lower.find("\"token\"") != std::string::npos ||
      lower.find("'token'") != std::string::npos ||
      lower.find("password=") != std::string::npos ||
      lower.find("password:") != std::string::npos ||
      lower.find("\"password\"") != std::string::npos ||
      lower.find("'password'") != std::string::npos ||
      lower.find("authorization:") != std::string::npos) {
    return ssprintf("[redacted-string len=%zu]", originalLength);
  }

  constexpr size_t kMaxLuaLogStringLength = 160;
  if (text.size() > kMaxLuaLogStringLength) {
    text.resize(kMaxLuaLogStringLength);
    text += "...[truncated]";
  }
  return text;
}

static std::string LuaValueSummary(lua_State* L, int index) {
  switch (lua_type(L, index)) {
    case LUA_TNIL:
      return "nil";
    case LUA_TBOOLEAN:
      return lua_toboolean(L, index) ? "true" : "false";
    case LUA_TNUMBER:
      return ssprintf("%g", lua_tonumber(L, index));
    case LUA_TSTRING:
      return LuaStringSummary(lua_tostring(L, index));
    case LUA_TTABLE:
      return ssprintf("table:%p", lua_topointer(L, index));
    default:
      return lua_typename(L, lua_type(L, index));
  }
}

static std::string LuaFieldSummary(lua_State* L, int tableIndex) {
  if (!lua_istable(L, tableIndex)) {
    return std::string("type=") + lua_typename(L, lua_type(L, tableIndex));
  }

  const int absIndex = LuaHelpers::AbsIndex(L, tableIndex);
  std::string summary = ssprintf(
      "type=table ptr=%p array_len=%zu",
      lua_topointer(L, absIndex),
      lua_objlen(L, absIndex));

  const char* fields[] = {
      "event", "success", "left", "room_id", "roomId", "code", "phase",
      "name"};
  for (const char* field : fields) {
    lua_getfield(L, absIndex, field);
    if (!lua_isnil(L, -1)) {
      summary += ssprintf(" %s=%s", field, LuaValueSummary(L, -1).c_str());
    }
    lua_pop(L, 1);
  }

  return summary;
}

Message::Message(const std::string& s) {
  m_sName = s;
  m_pParams = new LuaTable;
  m_bBroadcast = false;
}

Message::Message(const MessageID id) {
  m_sName = MessageIDToString(id);
  m_pParams = new LuaTable;
  m_bBroadcast = false;
}

Message::Message(const std::string& s, const LuaReference& params) {
  m_sName = s;
  m_bBroadcast = false;
  Lua* L = LUA->Get();
  m_pParams = new LuaTable;  // XXX: creates an extra table
  params.PushSelf(L);
  m_pParams->SetFromStack(L);
  LUA->Release(L);
  //	m_pParams = new LuaTable( params );
}

Message::~Message() { delete m_pParams; }

void Message::PushParamTable(lua_State* L) { m_pParams->PushSelf(L); }

void Message::SetParamTable(const LuaReference& params) {
  Lua* L = LUA->Get();
  params.PushSelf(L);
  m_pParams->SetFromStack(L);
  LUA->Release(L);
}

const LuaReference& Message::GetParamTable() const { return *m_pParams; }

void Message::GetParamFromStack(lua_State* L, const std::string& sName) const {
  m_pParams->Get(L, sName);
}

void Message::SetParamFromStack(lua_State* L, const std::string& sName) {
  m_pParams->Set(L, sName);
}

MessageManager::MessageManager() {
  m_Logging = false;
  // Register with Lua.
  {
    Lua* L = LUA->Get();
    lua_pushstring(L, "MESSAGEMAN");
    this->PushSelf(L);
    lua_settable(L, LUA_GLOBALSINDEX);
    LUA->Release(L);
  }
}

MessageManager::~MessageManager() {
  // Unregister with Lua.
  LUA->UnsetGlobal("MESSAGEMAN");
}

void MessageManager::Subscribe(
    IMessageSubscriber* pSubscriber, const std::string& sMessage) {
  LockMut(g_Mutex);

  SubscribersSet& subs = g_MessageToSubscribers[sMessage];
#ifdef DEBUG
  SubscribersSet::iterator iter = subs.find(pSubscriber);
  ASSERT_M(
      iter == subs.end(),
      ssprintf("already subscribed to '%s'", sMessage.c_str()));
#endif
  subs.insert(pSubscriber);
}

void MessageManager::Subscribe(IMessageSubscriber* pSubscriber, MessageID m) {
  Subscribe(pSubscriber, MessageIDToString(m));
}

void MessageManager::Unsubscribe(
    IMessageSubscriber* pSubscriber, const std::string& sMessage) {
  LockMut(g_Mutex);

  SubscribersSet& subs = g_MessageToSubscribers[sMessage];
  SubscribersSet::iterator iter = subs.find(pSubscriber);
  ASSERT(iter != subs.end());
  subs.erase(iter);
}

void MessageManager::Unsubscribe(IMessageSubscriber* pSubscriber, MessageID m) {
  Unsubscribe(pSubscriber, MessageIDToString(m));
}

void MessageManager::Broadcast(Message& msg) const {
  const bool traceOnlineMessage = ShouldTraceOnlineMessage(msg.GetName());
  if (m_Logging) {
    LOG->Trace("MESSAGEMAN:Broadcast: %s", msg.GetName().c_str());
  }
  msg.SetBroadcast(true);

  std::vector<IMessageSubscriber*> subscribers;

  {
    LockMut(g_Mutex);

    std::map<std::string, SubscribersSet>::const_iterator iter =
        g_MessageToSubscribers.find(msg.GetName());
    if (iter == g_MessageToSubscribers.end()) {
      if (traceOnlineMessage) {
        LOG->Trace(
            "ITG Online MessageTrace: broadcast_no_subscribers name=%s",
            msg.GetName().c_str());
      }
      return;
    }

    subscribers.assign(iter->second.begin(), iter->second.end());
  }

  size_t deliveredSubscribers = 0;
  size_t inactiveSubscribers = 0;
  size_t unsubscribedDuringDispatch = 0;

  for (IMessageSubscriber* subscriber : subscribers) {
    bool stillSubscribed = false;
    {
      LockMut(g_Mutex);
      std::map<std::string, SubscribersSet>::const_iterator iter =
          g_MessageToSubscribers.find(msg.GetName());
      if (iter != g_MessageToSubscribers.end()) {
        stillSubscribed = iter->second.find(subscriber) != iter->second.end();
      }
    }

    if (!stillSubscribed) {
      ++unsubscribedDuringDispatch;
      continue;
    }

    if (!subscriber->IsMessageDeliveryEnabled()) {
      ++inactiveSubscribers;
      continue;
    }

    subscriber->HandleMessage(msg);
    ++deliveredSubscribers;
  }

  if (traceOnlineMessage) {
    LOG->Trace(
        "ITG Online MessageTrace: broadcast_complete name=%s "
        "subscribers=%zu delivered=%zu skipped_inactive=%zu "
        "skipped_unsubscribed=%zu",
        msg.GetName().c_str(),
        subscribers.size(),
        deliveredSubscribers,
        inactiveSubscribers,
        unsubscribedDuringDispatch);
  }
}

void MessageManager::Broadcast(const std::string& sMessage) const {
  ASSERT(!sMessage.empty());
  Message msg(sMessage);
  Broadcast(msg);
}

void MessageManager::Broadcast(MessageID m) const {
  Broadcast(MessageIDToString(m));
}

bool MessageManager::IsSubscribedToMessage(
    IMessageSubscriber* pSubscriber, const std::string& sMessage) const {
  SubscribersSet& subs = g_MessageToSubscribers[sMessage];
  return subs.find(pSubscriber) != subs.end();
}

void IMessageSubscriber::ClearMessages(const std::string sMessage) {}

MessageSubscriber::MessageSubscriber(const MessageSubscriber& cpy)
    : IMessageSubscriber(cpy),
      m_bMessageDeliveryEnabled(cpy.IsMessageDeliveryEnabled()) {
  for (const std::string& msg : cpy.m_vsSubscribedTo) {
    this->SubscribeToMessage(msg);
  }
}

MessageSubscriber& MessageSubscriber::operator=(const MessageSubscriber& cpy) {
  if (&cpy == this) {
    return *this;
  }

  UnsubscribeAll();
  SetMessageDeliveryEnabled(cpy.IsMessageDeliveryEnabled());

  for (const std::string& msg : cpy.m_vsSubscribedTo) {
    this->SubscribeToMessage(msg);
  }

  return *this;
}

void MessageSubscriber::SubscribeToMessage(const std::string& sMessageName) {
  MESSAGEMAN->Subscribe(this, sMessageName);
  m_vsSubscribedTo.push_back(sMessageName);
}

void MessageSubscriber::SubscribeToMessage(MessageID message) {
  MESSAGEMAN->Subscribe(this, message);
  m_vsSubscribedTo.push_back(MessageIDToString(message));
}

void MessageSubscriber::UnsubscribeAll() {
  for (const std::string& s : m_vsSubscribedTo) {
    MESSAGEMAN->Unsubscribe(this, s);
  }
  m_vsSubscribedTo.clear();
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the MessageManager. */
class LunaMessageManager : public Luna<MessageManager> {
 public:
	  static int Broadcast(T* p, lua_State* L) {
	    if (!lua_istable(L, 2) && !lua_isnoneornil(L, 2)) {
	      luaL_typerror(L, 2, "table or nil");
	    }

	    const std::string messageName = SArg(1);
	    const bool traceOnlineMessage = ShouldTraceOnlineMessage(messageName);
	    if (traceOnlineMessage) {
	      LOG->Trace(
	          "ITG Online MessageTrace: lua_broadcast name=%s %s",
	          messageName.c_str(),
	          LuaFieldSummary(L, 2).c_str());
	    }

	    LuaReference ParamTable;
	    lua_pushvalue(L, 2);
	    ParamTable.SetFromStack(L);

	    Message msg(messageName, ParamTable);
	    p->Broadcast(msg);
	    COMMON_RETURN_SELF;
	  }
  static int SetLogging(T* p, lua_State* L) {
    p->SetLogging(lua_toboolean(L, -1));
    COMMON_RETURN_SELF;
  }

  LunaMessageManager() {
    ADD_METHOD(Broadcast);
    ADD_METHOD(SetLogging);
  }
};

LUA_REGISTER_CLASS(MessageManager)
// lua end

/*
 * (c) 2003-2004 Chris Danford
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
