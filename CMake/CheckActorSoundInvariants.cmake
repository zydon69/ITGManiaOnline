if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(read_source relative_path output_var)
  set(path "${ITGMANIA_SOURCE_DIR}/${relative_path}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing source file: ${path}")
  endif()
  file(READ "${path}" contents)
  set("${output_var}" "${contents}" PARENT_SCOPE)
endfunction()

function(require_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing invariant: ${label}")
  endif()
endfunction()

function(require_not_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(NOT found_at EQUAL -1)
    message(FATAL_ERROR "Forbidden pattern: ${label}")
  endif()
endfunction()

function(require_order haystack first second label)
  string(FIND "${haystack}" "${first}" first_at)
  string(FIND "${haystack}" "${second}" second_at)
  if(first_at EQUAL -1 OR second_at EQUAL -1 OR NOT first_at LESS second_at)
    message(FATAL_ERROR "Order invariant failed: ${label}")
  endif()
endfunction()

read_source("src/ActorSound.h" actor_sound_h)
read_source("src/ActorSound.cpp" actor_sound_cpp)
read_source(
  "Themes/Arrow Cloud/BGAnimations/ScreenSelectMusicCasual overlay/SoundEffects.lua"
  arrow_casual_sfx_lua)

require_contains(
  "${actor_sound_h}"
  "ActorSound* Copy() const override;"
  "ActorSound declares Copy override")
require_contains(
  "${actor_sound_h}"
  "void LoadFromNode(const XNode* pNode) override;"
  "ActorSound declares LoadFromNode override")
require_contains(
  "${actor_sound_h}"
  "void PushSelf(lua_State* L) override;"
  "ActorSound declares PushSelf override")
require_contains(
  "${actor_sound_h}"
  "bool IsSoundLoaded() const { return m_bSoundLoaded; }"
  "ActorSound exposes logical load state")
require_contains(
  "${actor_sound_h}"
  "void SetIsAction(bool bIsAction)"
  "ActorSound action flag is set through a method")
require_contains(
  "${actor_sound_h}"
  "bool GetIsAction() const"
  "ActorSound action flag is read through a method")
require_contains(
  "${actor_sound_h}"
  "bool m_bIsAction;"
  "ActorSound stores encapsulated action flag")
require_contains(
  "${actor_sound_h}"
  "bool m_bSoundLoaded;"
  "ActorSound stores logical load state")
require_contains(
  "${actor_sound_h}"
  "bool m_bPrecache;"
  "ActorSound preserves precache setting")
require_contains(
  "${actor_sound_h}"
  "RageSoundLoadParams m_LoadParams;"
  "ActorSound preserves load params")
require_not_contains(
  "${actor_sound_h}"
  "bool m_is_action;"
  "ActorSound action flag must not be public")

require_contains(
  "${actor_sound_cpp}"
  "ActorSound::ActorSound()"
  "ActorSound initializes explicit state")
require_contains(
  "${actor_sound_cpp}"
  "void ActorSound::ResetLoadedSound()"
  "ActorSound has a single reset path")
require_contains(
  "${actor_sound_cpp}"
  "m_Sound.Unload();"
  "ActorSound reset unloads stale sounds")
require_contains(
  "${actor_sound_cpp}"
  "m_bSoundLoaded = false;"
  "ActorSound clears logical load state")
require_contains(
  "${actor_sound_cpp}"
  "RageSound nextSound;"
  "ActorSound loads into a temporary sound")
require_contains(
  "${actor_sound_cpp}"
  "if (!nextSound.Load(sResolvedPath, bPrecache, &params))"
  "ActorSound checks RageSound load failure")
require_contains(
  "${actor_sound_cpp}"
  "SRC_AUDIT_FIX SRC-2673"
  "ActorSound logs rejected failed decodes")
require_contains(
  "${actor_sound_cpp}"
  "m_Sound = nextSound;"
  "ActorSound commits only a successfully loaded sound")
require_contains(
  "${actor_sound_cpp}"
  "m_bSoundLoaded = true;"
  "ActorSound marks logical load success")
require_contains(
  "${actor_sound_cpp}"
  "SRC_AUDIT_FIX SRC-2672"
  "ActorSound logs stale sound clearing")
require_contains(
  "${actor_sound_cpp}"
  "if (!m_bSoundLoaded)"
  "ActorSound play/pause/stop use logical load state")
require_not_contains(
  "${actor_sound_cpp}"
  "if (!m_Sound.IsLoaded())"
  "ActorSound must not treat fallback silence as a valid load")
require_order(
  "${actor_sound_cpp}"
  "LoadResolvedPath(sFile, params, bPrecache);"
  "Actor::LoadFromNode(pNode);"
  "ActorSound loads the File before InitCommand")
require_contains(
  "${actor_sound_cpp}"
  "lua_istable(L, 2)"
  "ActorSound Lua load accepts an optional params table")
require_contains(
  "${actor_sound_cpp}"
  "\"SupportPan\""
  "ActorSound Lua load preserves SupportPan")
require_contains(
  "${actor_sound_cpp}"
  "\"SupportRateChanging\""
  "ActorSound Lua load preserves SupportRateChanging")
require_contains(
  "${actor_sound_cpp}"
  "\"Precache\""
  "ActorSound Lua load preserves Precache")
require_contains(
  "${actor_sound_cpp}"
  "p->SetIsAction(BArg(1));"
  "ActorSound Lua is_action setter uses the method")
require_contains(
  "${actor_sound_cpp}"
  "DEFINE_METHOD(get_is_action, GetIsAction());"
  "ActorSound Lua is_action getter uses the method")

require_contains(
  "${arrow_casual_sfx_lua}"
  "if type(params) ~= \"table\" or type(params.Action) ~= \"string\" then return end"
  "Arrow Cloud validates SFX message payload shape")
require_contains(
  "${arrow_casual_sfx_lua}"
  "local ok, actor = pcall(function() return self:GetChild(params.Action) end)"
  "Arrow Cloud protects SFX child lookup")
require_contains(
  "${arrow_casual_sfx_lua}"
  "GAMESTATE and GAMESTATE.IsHumanPlayer and GAMESTATE:IsHumanPlayer(params.Player)"
  "Arrow Cloud validates SFX player before panning")
require_contains(
  "${arrow_casual_sfx_lua}"
  "pcall(function() actor:playforplayer(params.Player) end)"
  "Arrow Cloud protects panned SFX playback")
require_contains(
  "${arrow_casual_sfx_lua}"
  "pcall(function() actor:play() end)"
  "Arrow Cloud protects normal SFX playback")
