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

read_source("src/Inventory.cpp" inventory_cpp)
read_source("src/Inventory.h" inventory_h)

require_contains(
  "${inventory_cpp}"
  "static void WarnInventory"
  "Inventory warnings are routed through a log-safe helper")
require_contains(
  "${inventory_cpp}"
  "if (LOG != nullptr)"
  "Inventory warning helper guards LOG")
require_not_contains(
  "${inventory_cpp}"
  "LOG->Warn(\"SRC_AUDIT_FIX"
  "Inventory defensive diagnostics must not dereference LOG directly")
require_contains(
  "${inventory_cpp}"
  "InventoryThemeIsReady"
  "Inventory checks theme lifecycle before metric access")
require_contains(
  "${inventory_cpp}"
  "THEME != nullptr && THEME->IsThemeLoaded()"
  "Inventory theme readiness guard checks loaded theme")
require_not_contains(
  "${inventory_cpp}"
  "ThemeMetric<float> ITEM_USE_RATE_SECONDS"
  "Inventory use-rate metric must not be a static ThemeMetric")
require_not_contains(
  "${inventory_cpp}"
  "#define ITEM_"
  "Inventory item metrics must not use raw macros")
require_contains(
  "${inventory_cpp}"
  "GetSafeItemDurationSeconds"
  "Inventory validates item duration before awarding")
require_contains(
  "${inventory_cpp}"
  "MAX_INVENTORY_ITEM_DURATION_SECONDS"
  "Inventory item duration has an explicit upper bound")
require_contains(
  "${inventory_cpp}"
  "if (value > 128.0f)"
  "Inventory item count is bounded before integer conversion")
require_contains(
  "${inventory_cpp}"
  "GetSafeItemUseRateSeconds"
  "Inventory validates CPU use-rate metric")
require_contains(
  "${inventory_cpp}"
  "IsValidInventoryModifier"
  "Inventory validates item effect metrics")
require_contains(
  "${inventory_cpp}"
  "FromOneModString"
  "Inventory validates item effects through option parsers")
require_contains(
  "${inventory_cpp}"
  "static_cast<double>(m_fSecondsUntilCpuUseCheck) + fDelta"
  "Inventory CPU item timing accumulates frame deltas with wide arithmetic")
require_contains(
  "${inventory_cpp}"
  "std::clamp(1.0f / useRate, 0.0f, 1.0f)"
  "Inventory CPU item probability remains in its probability domain")
require_not_contains(
  "${inventory_cpp}"
  "static_cast<int>(fDelta)"
  "Inventory CPU item timing must not truncate frame deltas")
require_not_contains(
  "${inventory_cpp}"
  "RageTimer::GetTimeSinceStartSeconds"
  "Inventory CPU item timing must not depend on wall-clock second races")
require_contains(
  "${inventory_cpp}"
  "m_pPlayerState->m_PlayerController == PC_CPU"
  "Inventory CPU auto-use path is explicit")
require_contains(
  "${inventory_cpp}"
  "m_pPlayerState->m_PlayerController != PC_HUMAN"
  "Inventory blocks all non-human item acquisition")
require_contains(
  "${inventory_cpp}"
  "IsMatchingInventoryItem"
  "Inventory can recover the original item identity")
require_contains(
  "${inventory_cpp}"
  "m_iInventoryItemIndex[iOpenSlot] = iItemIndex"
  "Inventory stores the awarded item identity")
require_contains(
  "${inventory_cpp}"
  "m_vpSoundUseItem[itemIndex]->Play(false)"
  "Inventory plays use sounds by item identity")
require_contains(
  "${inventory_cpp}"
  "remove the item only after validating the full target/effect path"
  "Inventory use-item mutation is transactionally ordered")
require_contains(
  "${inventory_cpp}"
  "if (SCREENMAN != nullptr)"
  "Inventory guards battle damage screen messages")
require_not_contains(
  "${inventory_cpp}"
  "#define CROSSED"
  "Inventory combo checks must not leak local macros")
require_not_contains(
  "${inventory_cpp}"
  "#define BROKE_ABOVE"
  "Inventory combo checks must not leak local macros")
require_contains(
  "${inventory_h}"
  "void Update(float fDelta) override"
  "Inventory Update declares its Actor override")
require_contains(
  "${inventory_h}"
  "void DrawPrimitives() override"
  "Inventory DrawPrimitives declares its Actor override")
require_contains(
  "${inventory_h}"
  "std::array<int, NUM_INVENTORY_SLOTS> m_iInventoryItemIndex"
  "Inventory tracks item identities per slot")
