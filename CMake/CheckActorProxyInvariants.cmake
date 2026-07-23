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

read_source("src/ActorProxy.cpp" actor_proxy_cpp)
read_source("src/ActorProxy.h" actor_proxy_h)
read_source("src/LuaBinding.cpp" lua_binding_cpp)
read_source("src/LuaBinding.h" lua_binding_h)
read_source(
  "Themes/Simply Love/BGAnimations/ScreenPlayerOptions overlay/OptionRowPreviews/NoteSkinVariant.lua"
  noteskin_variant_previews)
read_source(
  "Themes/Simply Love/BGAnimations/ScreenPlayerOptions overlay/default.lua"
  player_options_overlay)

require_contains(
  "${actor_proxy_h}"
  "~ActorProxy() override;"
  "ActorProxy destructor declares override")
require_contains(
  "${actor_proxy_h}"
  "bool EarlyAbortDraw() const override;"
  "ActorProxy draw abort contract declares override")
require_contains(
  "${actor_proxy_h}"
  "void DrawPrimitives() override;"
  "ActorProxy draw contract declares override")
require_contains(
  "${actor_proxy_h}"
  "void LoadFromNode(const XNode* pNode) override;"
  "ActorProxy XML load contract declares override")
require_contains(
  "${actor_proxy_h}"
  "ActorProxy* Copy() const override;"
  "ActorProxy copy contract declares override")
require_contains(
  "${actor_proxy_h}"
  "void PushSelf(lua_State* L) override;"
  "ActorProxy Lua binding contract declares override")
require_contains(
  "${actor_proxy_h}"
  "std::shared_ptr<LifetimeToken> m_pLifetimeToken;"
  "ActorProxy owns an explicit lifetime token")

require_not_contains(
  "${actor_proxy_cpp}"
  "REGISTER_ACTOR_CLASS(ActorProxy)"
  "ActorProxy must keep explicit Copy policy instead of macro-generated copy")
require_contains(
  "${actor_proxy_cpp}"
  "ActorProxyRegistry()"
  "ActorProxy registry is function-local")
require_contains(
  "${actor_proxy_cpp}"
  "new std::set<ActorProxy*>"
  "ActorProxy registry survives static destruction order")
require_contains(
  "${actor_proxy_cpp}"
  "ActorLifetimeRegistry()"
  "ActorProxy tracks target lifetime during proxied draw")
require_contains(
  "${actor_proxy_cpp}"
  "MarkActorDestroyed(pTarget);"
  "ActorProxy marks target lifetime tokens dead during detach")
require_contains(
  "${actor_proxy_cpp}"
  "std::vector<ActorProxy*> proxies("
  "ActorProxy detaches through a snapshot of the registry")
require_contains(
  "${actor_proxy_cpp}"
  "std::shared_ptr<LifetimeToken> proxyToken = m_pLifetimeToken;"
  "ActorProxy draw keeps a local lifetime token before target draw")
require_contains(
  "${actor_proxy_cpp}"
  "TargetVisibilityGuard targetVisibilityGuard(target);"
  "ActorProxy draw scopes target visibility restoration")
require_contains(
  "${actor_proxy_cpp}"
  "DrawingTargetGuard drawingTargetGuard(this, proxyToken);"
  "ActorProxy draw scopes drawing-target reset")
require_contains(
  "${actor_proxy_cpp}"
  "m_pProxyToken != nullptr && m_pProxyToken->alive"
  "ActorProxy draw does not touch deleted proxies after target draw")
require_contains(
  "${actor_proxy_cpp}"
  "ActorProxy* ActorProxy::Copy() const"
  "ActorProxy copy policy is explicit")
require_contains(
  "${actor_proxy_cpp}"
  "ActorProxy copy intentionally dropped target"
  "ActorProxy copy documents target drop")
require_contains(
  "${actor_proxy_cpp}"
  "TryGetPointerFromStack("
  "ActorProxy Lua SetTarget uses non-throwing stale-reference lookup")
require_contains(
  "${actor_proxy_cpp}"
  "ActorProxy cleared stale Lua target"
  "ActorProxy Lua SetTarget clears stale references")
require_not_contains(
  "${actor_proxy_cpp}"
  "Actor* pTarget = Luna<Actor>::check(L, 1);"
  "ActorProxy Lua SetTarget must not use throwing Actor check")

require_contains(
  "${lua_binding_h}"
  "static bool TryGetPointerFromStack("
  "LuaBinding exposes non-throwing pointer lookup")
require_contains(
  "${lua_binding_cpp}"
  "bool LuaBinding::TryGetPointerFromStack"
  "LuaBinding implements non-throwing pointer lookup")
require_contains(
  "${lua_binding_cpp}"
  "return false;"
  "LuaBinding non-throwing lookup can report stale references")
require_contains(
  "${lua_binding_cpp}"
  "if (!TryGetPointerFromStack(L, sType, iArg, pRet))"
  "LuaBinding throwing lookup remains layered on the non-throwing path")

require_contains(
  "${noteskin_variant_previews}"
  "preloaded_all=true"
  "all selectable noteskin variants have proxy targets")
require_not_contains(
  "${noteskin_variant_previews}"
  "active_noteskins[noteskin]"
  "variant previews must not depend on the skin active at overlay load")
require_contains(
  "${player_options_overlay}"
  "Name=\"NoteSkin\",\n\t\t\t\t\t\tValue=current_noteskin"
  "the selected noteskin preview is targeted when options first open")
require_contains(
  "${player_options_overlay}"
  "local current_variant = SL[pn].ActiveModifiers.NoteSkinVariant\n\t\t\t\t\tor SL[pn].ActiveModifiers.NoteSkin or \"\""
  "the initial variant preview falls back to the selected base noteskin")
