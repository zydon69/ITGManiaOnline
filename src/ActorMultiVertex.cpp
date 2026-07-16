#include "ActorMultiVertex.h"

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cmath>
#include <limits>
#include <numeric>
#include <string>
#include <vector>

#include "Actor.h"
#include "ActorUtil.h"
#include "CubicSpline.h"
#include "EnumHelper.h"
#include "LuaBinding.h"
#include "LuaManager.h"
#include "RageDisplay.h"
#include "RageLog.h"
#include "RageTexture.h"
#include "RageTextureID.h"
#include "RageTextureManager.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Tween.h"
#include "XmlFile.h"
#include "global.h"

const float min_state_delay = 0.0001f;
constexpr size_t kMaxActorMultiVertexVertices = 1000000;
constexpr size_t kMaxActorMultiVertexStates = 65536;

static const char* DrawModeNames[] = {
    "Quads",     "QuadStrip",          "Fan", "Strip", "Triangles",
    "LineStrip", "SymmetricQuadStrip",
};

static const int DrawModeVertexGroupSizes[] = {
    4,  // Quads
    2,  // QuadStrip
    1,  // Fan
    1,  // Strip
    3,  // Triangles
    1,  // LineStrip
    3,  // SymmetricQuadStrip
    1,  // NUM_DrawMode
    1,  // DrawMode_Invalid
};

static const int DrawModeMinimumToDraw[] = {
    4,  // Quads
    4,  // QuadStrip
    3,  // Fan
    3,  // Strip
    3,  // Triangles
    2,  // LineStrip
    6,  // SymmetricQuadStrip
    1,  // NUM_DrawMode
    1,  // DrawMode_Invalid
};

XToString(DrawMode);
XToLocalizedString(DrawMode);
LuaXType(DrawMode);

REGISTER_ACTOR_CLASS(ActorMultiVertex);

namespace {
bool IsValidDrawMode(DrawMode dm) {
  return dm >= DrawMode_Quads && dm < NUM_DrawMode;
}

const char* GetSafeDrawModeName(DrawMode dm) {
  return IsValidDrawMode(dm) ? DrawModeNames[dm] : "Invalid";
}

bool IsFiniteRect(const RectF& rect) {
  return std::isfinite(rect.left) && std::isfinite(rect.top) &&
         std::isfinite(rect.right) && std::isfinite(rect.bottom);
}

float GetValidStateDelay(float delay) {
  return std::isfinite(delay) && delay > min_state_delay ? delay
                                                         : min_state_delay;
}

bool IsValidState(const ActorMultiVertex::State& state) {
  return IsFiniteRect(state.rect) && std::isfinite(state.delay) &&
         state.delay > 0.0f;
}

uint8_t MultiplyColorChannel(uint8_t channel, float multiplier) {
  if (!std::isfinite(multiplier)) {
    return 0;
  }
  const float value = std::clamp(
      static_cast<float>(channel) * multiplier, 0.0f, 255.0f);
  return static_cast<uint8_t>(value);
}
}  // namespace

ActorMultiVertex::ActorMultiVertex() {
  // Use blank texture by default.
  _Texture = nullptr;
  if (TEXTUREMAN != nullptr) {
    RageTextureID ID = TEXTUREMAN->GetDefaultTextureID();
    _Texture = TEXTUREMAN->LoadTexture(ID);
  }

  _EffectMode = EffectMode_Normal;
  _TextureMode = TextureMode_Modulate;
  _splines.resize(num_vert_splines);
  for (size_t i = 0; i < num_vert_splines; ++i) {
    _splines[i].redimension(3);
    _splines[i].m_owned_by_actor = true;
  }
  _skip_next_update = true;
  _decode_movie = true;
  _use_animation_state = false;
  _secs_into_state = 0.0f;
  _cur_state = 0;
}

ActorMultiVertex::~ActorMultiVertex() { UnloadTexture(); }

ActorMultiVertex::ActorMultiVertex(const ActorMultiVertex& cpy) : Actor(cpy) {
  AMV_Tweens = cpy.AMV_Tweens;
  AMV_current = cpy.AMV_current;
  AMV_start = cpy.AMV_start;
  _EffectMode = cpy._EffectMode;
  _TextureMode = cpy._TextureMode;
  _splines = cpy._splines;
  _skip_next_update = cpy._skip_next_update;
  _decode_movie = cpy._decode_movie;
  _use_animation_state = cpy._use_animation_state;
  _secs_into_state = cpy._secs_into_state;
  _cur_state = cpy._cur_state;
  _states = cpy._states;

  if (TEXTUREMAN != nullptr && cpy._Texture != nullptr) {
    _Texture = TEXTUREMAN->CopyTexture(cpy._Texture);
  } else {
    _Texture = nullptr;
  }
}

void ActorMultiVertex::LoadFromNode(const XNode* Node) {
  if (Node == nullptr) {
    Actor::LoadFromNode(Node);
    return;
  }
  std::string path;
  Node->GetAttrValue("Texture", path);
  if (!path.empty() && TEXTUREMAN != nullptr &&
      !TEXTUREMAN->IsTextureRegistered(RageTextureID(path))) {
    ActorUtil::GetAttrPath(Node, "Texture", path);
  }
  if (!path.empty()) {
    LoadFromTexture(path);
  }

  Actor::LoadFromNode(Node);
}

void ActorMultiVertex::SetTexture(RageTexture* Texture) {
  if (Texture == nullptr) {
    UnloadTexture();
    return;
  }
  if (_Texture == Texture) {
    return;
  }
  if (TEXTUREMAN == nullptr) {
    LOG->Warn("ActorMultiVertex: can't copy texture without texture manager.");
    return;
  }
  RageTexture* pCopy = TEXTUREMAN->CopyTexture(Texture);
  if (pCopy == nullptr) {
    LOG->Warn("ActorMultiVertex: texture copy failed.");
    return;
  }
  AdoptTexture(pCopy);
}

void ActorMultiVertex::AdoptTexture(RageTexture* Texture) {
  if (_Texture != Texture) {
    UnloadTexture();
    _Texture = Texture;
  }
}

void ActorMultiVertex::LoadFromTexture(RageTextureID ID) {
  RageTexture* Texture = nullptr;
  if (_Texture && _Texture->GetID() == ID) {
    return;
  }
  if (TEXTUREMAN == nullptr) {
    LOG->Warn("ActorMultiVertex: can't load texture without texture manager.");
    return;
  }
  Texture = TEXTUREMAN->LoadTexture(ID);
  AdoptTexture(Texture);
}

void ActorMultiVertex::UnloadTexture() {
  if (_Texture != nullptr) {
    if (TEXTUREMAN != nullptr) {
      TEXTUREMAN->UnloadTexture(_Texture);
    }
    _Texture = nullptr;
  }
}

void ActorMultiVertex::SetNumVertices(size_t n) {
  if (n > kMaxActorMultiVertexVertices) {
    LuaHelpers::ReportScriptErrorFmt(
        "ActorMultiVertex:SetNumVertices: refusing to allocate %u vertices.",
        static_cast<unsigned int>(n));
    return;
  }
  if (n == 0) {
    for (size_t i = 0; i < AMV_Tweens.size(); ++i) {
      AMV_Tweens[i].vertices.clear();
    }
    AMV_current.vertices.clear();
    AMV_start.vertices.clear();
  } else {
    for (size_t i = 0; i < AMV_Tweens.size(); ++i) {
      AMV_Tweens[i].vertices.resize(n);
    }
    AMV_current.vertices.resize(n);
    AMV_start.vertices.resize(n);
  }
}

void ActorMultiVertex::AddVertex() {
  if (AMV_DestTweenState().vertices.size() >= kMaxActorMultiVertexVertices) {
    LuaHelpers::ReportScriptError(
        "ActorMultiVertex:AddVertex: vertex limit reached.");
    return;
  }
  for (size_t i = 0; i < AMV_Tweens.size(); ++i) {
    AMV_Tweens[i].vertices.push_back(RageSpriteVertex());
  }
  AMV_current.vertices.push_back(RageSpriteVertex());
  AMV_start.vertices.push_back(RageSpriteVertex());
}

void ActorMultiVertex::AddVertices(int Add) {
  if (Add <= 0) {
    return;
  }
  const size_t current_size = AMV_DestTweenState().vertices.size();
  const size_t add = static_cast<size_t>(Add);
  if (add > kMaxActorMultiVertexVertices - current_size) {
    LuaHelpers::ReportScriptErrorFmt(
        "ActorMultiVertex:AddVertices: refusing to allocate %u vertices.",
        static_cast<unsigned int>(current_size + add));
    return;
  }
  SetNumVertices(current_size + add);
}

void ActorMultiVertex::SetVertexPos(int index, float x, float y, float z) {
  if (index < 0 ||
      static_cast<size_t>(index) >= AMV_DestTweenState().vertices.size()) {
    LuaHelpers::ReportScriptErrorFmt(
        "ActorMultiVertex:SetVertexPos: vertex index %d out of range.",
        index + 1);
    return;
  }
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {
    LuaHelpers::ReportScriptError(
        "ActorMultiVertex:SetVertexPos: position must be finite.");
    return;
  }
  AMV_DestTweenState().vertices[index].p = RageVector3(x, y, z);
}

void ActorMultiVertex::SetVertexColor(int index, RageColor c) {
  if (index < 0 ||
      static_cast<size_t>(index) >= AMV_DestTweenState().vertices.size()) {
    LuaHelpers::ReportScriptErrorFmt(
        "ActorMultiVertex:SetVertexColor: vertex index %d out of range.",
        index + 1);
    return;
  }
  if (!std::isfinite(c.r) || !std::isfinite(c.g) || !std::isfinite(c.b) ||
      !std::isfinite(c.a)) {
    LuaHelpers::ReportScriptError(
        "ActorMultiVertex:SetVertexColor: color must be finite.");
    return;
  }
  AMV_DestTweenState().vertices[index].c = c;
}

void ActorMultiVertex::SetVertexCoords(
    int index, float TexCoordX, float TexCoordY) {
  if (index < 0 ||
      static_cast<size_t>(index) >= AMV_DestTweenState().vertices.size()) {
    LuaHelpers::ReportScriptErrorFmt(
        "ActorMultiVertex:SetVertexCoords: vertex index %d out of range.",
        index + 1);
    return;
  }
  if (!std::isfinite(TexCoordX) || !std::isfinite(TexCoordY)) {
    LuaHelpers::ReportScriptError(
        "ActorMultiVertex:SetVertexCoords: texture coordinates must be finite.");
    return;
  }
  AMV_DestTweenState().vertices[index].t = RageVector2(TexCoordX, TexCoordY);
}

void ActorMultiVertex::DrawPrimitives() {
  if (DISPLAY == nullptr || _Texture == nullptr || m_pTempState == nullptr) {
    return;
  }

  Actor::SetGlobalRenderStates();  // set Actor-specified render states

  DISPLAY->ClearAllTextures();
  DISPLAY->SetTexture(TextureUnit_1, _Texture->GetTexHandle());

  Actor::SetTextureRenderStates();
  DISPLAY->SetEffectMode(_EffectMode);

  // Set temporary diffuse and glow without sharing mutable draw state.
  AMV_TweenState TS = AMV_current;

  // skip if no change or fully transparent
  if (m_pTempState->diffuse[0] != RageColor(1, 1, 1, 1) &&
      m_pTempState->diffuse[0].a > 0) {
    for (size_t i = 0; i < TS.vertices.size(); i++) {
      // RageVColor uses a uint8_t for each channel.  0-255.
      // RageColor uses a float. 0-1.
      // So each channel of the RageVColor needs to be converted to a float,
      // multiplied by the channel from the RageColor, then the result
      // converted to uint8_t.  If implicit conversion is allowed to happen,
      // sometimes the compiler decides to turn the RageColor into a uint8_t,
      // which makes any value other than 1 into 0.  Thus, the explicit
      // conversions.  -Kyz
      // RageVColor * RageColor
      TS.vertices[i].c.b =
          MultiplyColorChannel(TS.vertices[i].c.b, m_pTempState->diffuse[0].b);
      TS.vertices[i].c.r =
          MultiplyColorChannel(TS.vertices[i].c.r, m_pTempState->diffuse[0].r);
      TS.vertices[i].c.g =
          MultiplyColorChannel(TS.vertices[i].c.g, m_pTempState->diffuse[0].g);
      TS.vertices[i].c.a =
          MultiplyColorChannel(TS.vertices[i].c.a, m_pTempState->diffuse[0].a);
    }
  }

  // Draw diffuse pass.
  if (m_pTempState->diffuse[0].a > 0) {
    DISPLAY->SetTextureMode(TextureUnit_1, _TextureMode);
    DrawInternal(&TS);
  }

  // Draw the glow pass
  if (m_pTempState->glow.a > 0) {
    for (size_t i = 0; i < TS.vertices.size(); i++) {
      TS.vertices[i].c = m_pTempState->glow;
    }
    DISPLAY->SetTextureMode(TextureUnit_1, TextureMode_Glow);
    DrawInternal(&TS);
  }
  DISPLAY->SetTexture(TextureUnit_1, 0);
  DISPLAY->SetEffectMode(EffectMode_Normal);
}

void ActorMultiVertex::DrawInternal(const AMV_TweenState* TS) {
  if (DISPLAY == nullptr || TS == nullptr || !IsValidDrawMode(TS->_DrawMode) ||
      TS->FirstToDraw < 0) {
    return;
  }
  int FirstToDraw = TS->FirstToDraw;
  int NumToDraw = TS->GetSafeNumToDraw(TS->_DrawMode, TS->NumToDraw);

  if (NumToDraw == 0) {
    // Nothing to draw.
    return;
  }
  if (static_cast<size_t>(FirstToDraw) >= TS->vertices.size() ||
      static_cast<size_t>(NumToDraw) >
          TS->vertices.size() - static_cast<size_t>(FirstToDraw)) {
    return;
  }

  switch (TS->_DrawMode) {
    case DrawMode_Quads: {
      DISPLAY->DrawQuads(&TS->vertices[FirstToDraw], NumToDraw);
      break;
    }
    case DrawMode_QuadStrip: {
      DISPLAY->DrawQuadStrip(&TS->vertices[FirstToDraw], NumToDraw);
      break;
    }
    case DrawMode_Fan: {
      DISPLAY->DrawFan(&TS->vertices[FirstToDraw], NumToDraw);
      break;
    }
    case DrawMode_Strip: {
      DISPLAY->DrawStrip(&TS->vertices[FirstToDraw], NumToDraw);
      break;
    }
    case DrawMode_Triangles: {
      DISPLAY->DrawTriangles(&TS->vertices[FirstToDraw], NumToDraw);
      break;
    }
    case DrawMode_LineStrip: {
      DISPLAY->DrawLineStrip(
          &TS->vertices[FirstToDraw], NumToDraw, TS->line_width);
      break;
    }
    case DrawMode_SymmetricQuadStrip: {
      DISPLAY->DrawSymmetricQuadStrip(&TS->vertices[FirstToDraw], NumToDraw);
      break;
    }
    default:
      break;
  }

  DISPLAY->SetEffectMode(EffectMode_Normal);
}

bool ActorMultiVertex::EarlyAbortDraw() const {
  if (_Texture == nullptr || DISPLAY == nullptr || AMV_current.FirstToDraw < 0 ||
      static_cast<size_t>(AMV_current.FirstToDraw) >=
          AMV_current.vertices.size() ||
      !IsValidDrawMode(AMV_current._DrawMode)) {
    return true;
  }
  return false;
}

void ActorMultiVertex::SetVertsFromSplinesInternal(
    size_t num_splines, size_t offset) {
  if (num_splines == 0 || num_splines > _splines.size()) {
    return;
  }
  std::vector<RageSpriteVertex>& verts = AMV_DestTweenState().vertices;
  if (AMV_DestTweenState().FirstToDraw < 0) {
    return;
  }
  size_t first = static_cast<size_t>(AMV_DestTweenState().FirstToDraw) + offset;
  const int iSafeNum =
      AMV_DestTweenState().GetSafeNumToDraw(
          AMV_DestTweenState()._DrawMode, AMV_DestTweenState().NumToDraw);
  if (iSafeNum <= 0 || static_cast<size_t>(iSafeNum) <= offset ||
      first >= verts.size()) {
    return;
  }
  size_t num_verts = static_cast<size_t>(iSafeNum) - offset;
  if (num_verts > verts.size() - first) {
    num_verts = verts.size() - first;
  }
  const float num_parts =
      (static_cast<float>(num_verts) / static_cast<float>(num_splines)) - 1.0f;
  if (!std::isfinite(num_parts) || num_parts <= 0.0f) {
    return;
  }
  std::vector<float> tper(num_splines, 0.0f);
  for (size_t i = 0; i < num_splines; ++i) {
    tper[i] = _splines[i].get_max_t() / num_parts;
  }
  for (size_t v = 0; v < num_verts; ++v) {
    std::vector<float> pos;
    const int spi = v % num_splines;
    float part = static_cast<float>(v / num_splines);
    _splines[spi].evaluate(part * tper[spi], pos);
    if (pos.size() < 3) {
      return;
    }
    verts[v + first].p.x = pos[0];
    verts[v + first].p.y = pos[1];
    verts[v + first].p.z = pos[2];
  }
}

void ActorMultiVertex::SetVertsFromSplines() {
  if (AMV_DestTweenState().vertices.empty()) {
    return;
  }
  switch (AMV_DestTweenState()._DrawMode) {
    case DrawMode_Quads:
      SetVertsFromSplinesInternal(4, 0);
      break;
    case DrawMode_QuadStrip:
    case DrawMode_Strip:
      SetVertsFromSplinesInternal(2, 0);
      break;
    case DrawMode_Fan:
      // Skip the first vert because it is the center of the fan. -Kyz
      SetVertsFromSplinesInternal(1, 1);
      break;
    case DrawMode_Triangles:
    case DrawMode_SymmetricQuadStrip:
      SetVertsFromSplinesInternal(3, 0);
      break;
    case DrawMode_LineStrip:
      SetVertsFromSplinesInternal(1, 0);
      break;
    default:
      break;
  }
}

CubicSplineN* ActorMultiVertex::GetSpline(size_t i) {
  if (i >= _splines.size()) {
    return nullptr;
  }
  return &(_splines[i]);
}

void ActorMultiVertex::SetState(int i) {
  if (_states.empty()) {
    _cur_state = 0;
    _secs_into_state = 0.0f;
    return;
  }
  if (i < 0 || static_cast<size_t>(i) >= _states.size()) {
    LuaHelpers::ReportScriptErrorFmt(
        "ActorMultiVertex:SetState: state index %d out of range.", i + 1);
    return;
  }
  _cur_state = static_cast<size_t>(i);
  _secs_into_state = 0.0f;
}

void ActorMultiVertex::AddState(const State& new_state) {
  if (_states.size() >= kMaxActorMultiVertexStates ||
      !IsValidState(new_state)) {
    LuaHelpers::ReportScriptError(
        "ActorMultiVertex:AddState: invalid state or state limit reached.");
    return;
  }
  _states.push_back(new_state);
}

void ActorMultiVertex::SetStateData(size_t i, const State& state) {
  if (i >= _states.size() || !IsValidState(state)) {
    return;
  }
  _states[i] = state;
}

void ActorMultiVertex::SetStateProperties(
    const std::vector<State>& new_states) {
  if (new_states.size() > kMaxActorMultiVertexStates ||
      !std::all_of(new_states.begin(), new_states.end(), IsValidState)) {
    LuaHelpers::ReportScriptError(
        "ActorMultiVertex:SetStateProperties: invalid states or state limit "
        "reached.");
    return;
  }
  _states = new_states;
  _cur_state = 0;
  _secs_into_state = 0.0f;
}

void ActorMultiVertex::SetAllStateDelays(float delay) {
  if (!std::isfinite(delay) || delay <= min_state_delay) {
    delay = min_state_delay;
  }
  for (State& s : _states) {
    s.delay = delay;
  }
}

float ActorMultiVertex::GetAnimationLengthSeconds() const {
  double total = 0.0;
  for (const State& state : _states) {
    total += GetValidStateDelay(state.delay);
    if (total >= std::numeric_limits<float>::max()) {
      return std::numeric_limits<float>::max();
    }
  }
  return static_cast<float>(total);
}

void ActorMultiVertex::SetSecondsIntoAnimation(float seconds) {
  if (!std::isfinite(seconds)) {
    seconds = 0.0f;
  }
  if (_Texture) {
    _Texture->SetPosition(seconds);
  }
  if (_states.empty()) {
    _cur_state = 0;
    _secs_into_state = 0.0f;
    return;
  }

  const double length = GetAnimationLengthSeconds();
  double phase = length > 0.0 ? std::fmod(static_cast<double>(seconds), length)
                              : 0.0;
  if (phase < 0.0) {
    phase += length;
  }
  _cur_state = 0;
  while (_cur_state + 1 < _states.size() &&
         phase >= GetValidStateDelay(_states[_cur_state].delay)) {
    phase -= GetValidStateDelay(_states[_cur_state].delay);
    ++_cur_state;
  }
  _secs_into_state = static_cast<float>(phase);
  UpdateAnimationState(true);
}

void ActorMultiVertex::UpdateAnimationState(bool force_update) {
  AMV_TweenState& dest = AMV_DestTweenState();
  std::vector<RageSpriteVertex>& verts = dest.vertices;
  std::vector<size_t>& qs = dest.quad_states;
  if (!_use_animation_state || _states.empty() ||
      dest._DrawMode == DrawMode_LineStrip || qs.empty()) {
    return;
  }
  if (_cur_state >= _states.size()) {
    _cur_state = 0;
  }
  if (dest.FirstToDraw < 0 || !IsValidDrawMode(dest._DrawMode)) {
    return;
  }
  const int iSafeNum = dest.GetSafeNumToDraw(dest._DrawMode, dest.NumToDraw);
  if (iSafeNum <= 0) {
    return;
  }
  size_t first = static_cast<size_t>(dest.FirstToDraw);
  if (first >= verts.size()) {
    return;
  }
  size_t last = first + static_cast<size_t>(iSafeNum);
  if (last > verts.size()) {
    return;
  }
  const size_t previous_state = _cur_state;
  double phase = _secs_into_state;
  for (size_t i = 0; i < _cur_state; ++i) {
    phase += GetValidStateDelay(_states[i].delay);
  }
  const double length = GetAnimationLengthSeconds();
  phase = length > 0.0 ? std::fmod(phase, length) : 0.0;
  if (phase < 0.0) {
    phase += length;
  }
  _cur_state = 0;
  while (_cur_state + 1 < _states.size() &&
         phase >= GetValidStateDelay(_states[_cur_state].delay)) {
    phase -= GetValidStateDelay(_states[_cur_state].delay);
    ++_cur_state;
  }
  _secs_into_state = static_cast<float>(phase);
  const bool state_changed = force_update || previous_state != _cur_state;
  if (state_changed) {
    switch (AMV_DestTweenState()._DrawMode) {
      case DrawMode_Quads:
        for (size_t i = first; i < last; ++i) {
          const size_t quad_id = (i - first) / 4;
          const size_t state_id =
              (_cur_state + qs[quad_id % qs.size()]) % _states.size();
          const auto& rect = _states[state_id].rect;

          switch ((i - first) % 4) {
            case 0:
              verts[i].t.x = rect.left;
              verts[i].t.y = rect.top;
              break;

            case 1:
              verts[i].t.x = rect.right;
              verts[i].t.y = rect.top;
              break;

            case 2:
              verts[i].t.x = rect.right;
              verts[i].t.y = rect.bottom;
              break;

            case 3:
              verts[i].t.x = rect.left;
              verts[i].t.y = rect.bottom;
              break;
          }
        }
        break;
      case DrawMode_QuadStrip:
        for (size_t i = first; i < last; ++i) {
          const size_t quad_id = (i - first) / 2;
          const size_t state_id =
              (_cur_state + qs[quad_id % qs.size()]) % _states.size();
          const auto& rect = _states[state_id].rect;

          if ((i - first) % 2 == 0) {
            verts[i].t.x = rect.left;
            verts[i].t.y = rect.top;
          } else {
            verts[i].t.x = rect.left;
            verts[i].t.y = rect.bottom;
          }
        }
        break;
      case DrawMode_Strip:
      case DrawMode_Fan:
        for (size_t i = first; i < last; ++i) {
          const size_t quad_id = (i - first);
          const size_t state_id =
              (_cur_state + qs[quad_id % qs.size()]) % _states.size();
          const auto& rect = _states[state_id].rect;

          verts[i].t.x = rect.left;
          verts[i].t.y = rect.top;
        }
        break;
      case DrawMode_Triangles:
        for (size_t i = first; i < last; ++i) {
          const size_t quad_id = (i - first) / 3;
          const size_t state_id =
              (_cur_state + qs[quad_id % qs.size()]) % _states.size();
          const auto& rect = _states[state_id].rect;

          switch ((i - first) % 3) {
            case 0:
              verts[i].t.x = rect.left;
              verts[i].t.y = rect.top;
              break;
            case 1:
              verts[i].t.x = rect.right;
              verts[i].t.y = rect.top;
              break;
            case 2:
              verts[i].t.x = rect.right;
              verts[i].t.y = rect.bottom;
              break;
          }
        }
        break;
      case DrawMode_SymmetricQuadStrip:
        for (size_t i = first; i < last; ++i) {
          const size_t quad_id = (i - first) / 3;
          const size_t state_id =
              (_cur_state + qs[quad_id % qs.size()]) % _states.size();
          const auto& rect = _states[state_id].rect;

          switch ((i - first) % 3) {
            case 0:
            case 2:
              verts[i].t.x = rect.left;
              verts[i].t.y = rect.top;
              break;
            case 1:
              verts[i].t.x = rect.right;
              verts[i].t.y = rect.top;
              break;
          }
        }
        break;
      default:
        break;
    }
  }
}

void ActorMultiVertex::EnableAnimation(bool bEnable) {
  bool bWasEnabled = m_bIsAnimating;
  Actor::EnableAnimation(bEnable);

  if (bEnable && !bWasEnabled) {
    _skip_next_update = true;
  }
}

void ActorMultiVertex::Update(float fDelta) {
  if (!std::isfinite(fDelta)) {
    return;
  }
  Actor::Update(fDelta);  // do tweening
  const bool skip_this_movie_update = _skip_next_update;
  _skip_next_update = false;
  if (!m_bIsAnimating) {
    return;
  }
  if (!_Texture) {
    return;
  }
  float time_passed = GetEffectDeltaTime();
  if (!std::isfinite(time_passed)) {
    return;
  }
  _secs_into_state += time_passed;
  if (_secs_into_state < 0) {
    const float fLength = GetAnimationLengthSeconds();
    if (std::isfinite(fLength) && fLength > min_state_delay) {
      wrap(_secs_into_state, fLength);
    } else {
      _secs_into_state = 0.0f;
    }
  }
  UpdateAnimationState();
  if (!skip_this_movie_update && _decode_movie) {
    _Texture->UpdateMovie(std::max(0.0f, time_passed));
  }
}

void ActorMultiVertex::SetCurrentTweenStart() { AMV_start = AMV_current; }

void ActorMultiVertex::EraseHeadTween() {
  if (AMV_Tweens.empty()) {
    return;
  }
  AMV_current = AMV_Tweens[0];
  AMV_Tweens.erase(AMV_Tweens.begin());
}

void ActorMultiVertex::UpdatePercentThroughTween(float PercentThroughTween) {
  if (AMV_Tweens.empty()) {
    return;
  }
  AMV_TweenState::MakeWeightedAverage(
      AMV_current, AMV_start, AMV_Tweens[0], PercentThroughTween);
}

void ActorMultiVertex::BeginTweening(float time, ITween* pTween) {
  Actor::BeginTweening(time, pTween);

  if (!AMV_Tweens.empty())  // if there was already a TS on the stack
  {
    AMV_Tweens.push_back(AMV_Tweens.back());
  } else {
    AMV_Tweens.push_back(AMV_current);
  }
}

void ActorMultiVertex::StopTweening() {
  AMV_Tweens.clear();
  Actor::StopTweening();
}

void ActorMultiVertex::FinishTweening() {
  if (!AMV_Tweens.empty()) {
    AMV_current = AMV_DestTweenState();
  }
  Actor::FinishTweening();
}

void ActorMultiVertex::AMV_TweenState::SetDrawState(
    DrawMode dm, int first, int num) {
  if (!IsValidDrawMode(dm)) {
    LuaHelpers::ReportScriptError(
        "ActorMultiVertex:SetDrawState: invalid draw mode.");
    return;
  }
  if (first < 0) {
    LuaHelpers::ReportScriptErrorFmt(
        "ActorMultiVertex:SetDrawState: FirstToDraw %d is invalid.",
        first + 1);
    return;
  }
  if (static_cast<size_t>(first) >= vertices.size() && !vertices.empty()) {
    LuaHelpers::ReportScriptErrorFmt(
        "ActorMultiVertex:SetDrawState: FirstToDraw > vertices.size(), %d > %u",
        first + 1, (unsigned int)vertices.size());
    return;
  }
  int safe_num = GetSafeNumToDraw(dm, num);
  if (num != safe_num && num != -1) {
    LuaHelpers::ReportScriptErrorFmt(
        "ActorMultiVertex:SetDrawState: NumToDraw %d is not valid for %u "
        "vertices with DrawMode %s",
        num, (unsigned int)vertices.size(), GetSafeDrawModeName(dm));
    return;
  }
  _DrawMode = dm;
  FirstToDraw = first;
  NumToDraw = num;
}

void ActorMultiVertex::AMV_TweenState::MakeWeightedAverage(
    AMV_TweenState& average_out, const AMV_TweenState& ts1,
    const AMV_TweenState& ts2, float percent_between) {
  if (!std::isfinite(percent_between)) {
    percent_between = 0.0f;
  }
  average_out.line_width =
      lerp(percent_between, ts1.line_width, ts2.line_width);
  if (!std::isfinite(average_out.line_width) || average_out.line_width < 0.0f) {
    average_out.line_width = 1.0f;
  }
  const size_t iVertexCount = std::min(
      average_out.vertices.size(),
      std::min(ts1.vertices.size(), ts2.vertices.size()));
  for (size_t v = 0; v < iVertexCount; ++v) {
    WeightedAvergeOfRSVs(
        average_out.vertices[v], ts1.vertices[v], ts2.vertices[v],
        percent_between);
  }
}

int ActorMultiVertex::AMV_TweenState::GetSafeNumToDraw(
    DrawMode dm, int num) const {
  if (!IsValidDrawMode(dm) || FirstToDraw < 0 ||
      static_cast<size_t>(FirstToDraw) >= vertices.size()) {
    return 0;
  }
  int max = static_cast<int>(
      std::min<size_t>(
          vertices.size() - static_cast<size_t>(FirstToDraw),
          static_cast<size_t>(std::numeric_limits<int>::max())));
  // NumToDraw == -1 draws all vertices
  if (num == -1 || num > max) {
    num = max;
  }
  if (num < 0) {
    return 0;
  }
  num -= (num % DrawModeVertexGroupSizes[dm]);
  if (num < DrawModeMinimumToDraw[dm]) {
    num = 0;
  }
  return num;
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ActorMultiVertex. */
class LunaActorMultiVertex : public Luna<ActorMultiVertex> {
 public:
  static int SetNumVertices(T* p, lua_State* L) {
    int iNumVertices = IArg(1);
    if (iNumVertices < 0) {
      LuaHelpers::ReportScriptError(
          "ActorMultiVertex:SetNumVertices: vertex count cannot be negative.");
      COMMON_RETURN_SELF;
    }
    p->SetNumVertices(static_cast<size_t>(iNumVertices));
    COMMON_RETURN_SELF;
  }
  static int GetNumVertices(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetNumVertices());
    return 1;
  }

  static void SetVertexFromStack(
      T* p, lua_State* L, int VertexIndex, int DataStackIndex) {
    // Use the number of arguments to determine which property a table is for
    if (lua_type(L, DataStackIndex) != LUA_TTABLE) {
      LuaHelpers::ReportScriptErrorFmt(
          "ActorMultiVertex::SetVertex: non-table parameter supplied. Table of "
          "tables of vertex data expected.");
      return;
    }
    size_t NumDataParts = lua_objlen(L, DataStackIndex);
    for (size_t i = 0; i < NumDataParts; ++i) {
      lua_pushnumber(L, i + 1);
      lua_gettable(L, DataStackIndex);
      int DataPieceIndex = lua_gettop(L);
      size_t DataPieceElements = lua_objlen(L, DataPieceIndex);
      if (lua_type(L, DataPieceIndex) != LUA_TTABLE) {
        LuaHelpers::ReportScriptErrorFmt(
            "ActorMultiVertex::SetVertex: non-table parameter %u supplied "
            "inside table of parameters, table expected.",
            (unsigned int)i);
        return;
      }
      int pushes = 1;
      if (DataPieceElements == 2) {
        pushes += 2;
        lua_rawgeti(L, DataPieceIndex, 1);
        float x = FArg(-1);
        lua_rawgeti(L, DataPieceIndex, 2);
        float y = FArg(-1);
        p->SetVertexCoords(VertexIndex, x, y);
      } else if (DataPieceElements == 3) {
        pushes += 3;
        lua_rawgeti(L, DataPieceIndex, 1);
        float x = FArg(-1);
        lua_rawgeti(L, DataPieceIndex, 2);
        float y = FArg(-1);
        lua_rawgeti(L, DataPieceIndex, 3);
        float z = FArg(-1);
        p->SetVertexPos(VertexIndex, x, y, z);
      } else if (DataPieceElements == 4) {
        // RageColor pops the things it pushes onto the stack, so we don't need
        // to.
        RageColor c;
        // Does not use FromStackCompat because we are not compatible with
        // passing a color in non-table form.
        c.FromStack(L, DataPieceIndex);
        p->SetVertexColor(VertexIndex, c);
      } else {
        LuaHelpers::ReportScriptErrorFmt(
            "ActorMultiVertex::SetVertex: Parameter %u has %u elements "
            "supplied. 2, 3, or 4 expected.",
            (unsigned int)i, (unsigned int)DataPieceElements);
      }
      // Avoid a stack underflow by only popping the amount we pushed.
      lua_pop(L, pushes);
    }
    return;
  }

  static int SetVertex(T* p, lua_State* L) {
    // Indices from Lua are one-indexed.  -1 to adjust.
    int Index = IArg(1) - 1;
    if (Index < 0) {
      LuaHelpers::ReportScriptErrorFmt(
          "ActorMultiVertex::SetVertex: index %d provided, cannot set Index < "
          "1",
          Index + 1);
      COMMON_RETURN_SELF;
    } else if (Index == (int)p->GetNumVertices()) {
      p->AddVertices(1);
    } else if (Index > (int)p->GetNumVertices()) {
      LuaHelpers::ReportScriptErrorFmt(
          "ActorMultiVertex::SetVertex: Cannot set vertex %d if there is no "
          "vertex %d, only %u vertices.",
          Index + 1, Index, (unsigned int)p->GetNumVertices());
      COMMON_RETURN_SELF;
    }
    SetVertexFromStack(p, L, Index, lua_gettop(L));
    COMMON_RETURN_SELF;
  }

  static int SetVertices(T* p, lua_State* L) {
    int First = 0;
    int StackIndex = lua_gettop(L);
    // Allow the user to just pass a table without specifying a starting point.
    if (lua_type(L, 1) == LUA_TNUMBER) {
      // Indices from Lua are one-indexed.  -1 to adjust.
      First = IArg(1) - 1;
      if (First < 0) {
        LuaHelpers::ReportScriptErrorFmt(
            "ActorMultiVertex::SetVertices: index %d provided, cannot set "
            "Index < 1",
            First + 1);
        COMMON_RETURN_SELF;
      }
    }
    size_t VertexCount = lua_objlen(L, StackIndex);
    if (VertexCount >
        static_cast<size_t>(std::numeric_limits<int>::max() - First)) {
      LuaHelpers::ReportScriptError(
          "ActorMultiVertex::SetVertices: too many vertices supplied.");
      COMMON_RETURN_SELF;
    }
    int Last = First + static_cast<int>(VertexCount);
    if (Last > (int)p->GetNumVertices()) {
      p->AddVertices(Last - p->GetNumVertices());
    }
    if (Last > (int)p->GetNumVertices()) {
      COMMON_RETURN_SELF;
    }
    for (int n = First; n < Last; ++n) {
      lua_pushnumber(L, n - First + 1);
      lua_gettable(L, StackIndex);
      SetVertexFromStack(p, L, n, lua_gettop(L));
      lua_pop(L, 1);
    }
    COMMON_RETURN_SELF;
  }

  static int SetEffectMode(T* p, lua_State* L) {
    EffectMode em = Enum::Check<EffectMode>(L, 1);
    p->SetEffectMode(em);
    COMMON_RETURN_SELF;
  }

  static int SetTextureMode(T* p, lua_State* L) {
    TextureMode tm = Enum::Check<TextureMode>(L, 1);
    p->SetTextureMode(tm);
    COMMON_RETURN_SELF;
  }

  static int SetLineWidth(T* p, lua_State* L) {
    float Width = FArg(1);
    if (!std::isfinite(Width) || Width < 0) {
      LuaHelpers::ReportScriptErrorFmt(
          "ActorMultiVertex::SetLineWidth: width must be finite and non-negative.");
      COMMON_RETURN_SELF;
    }
    p->SetLineWidth(Width);
    COMMON_RETURN_SELF;
  }

  static int SetDrawState(T* p, lua_State* L) {
    DrawMode dm = p->GetDestDrawMode();
    int first = p->GetDestFirstToDraw();
    int num = p->GetDestNumToDraw();
    int ArgsIndex = 1;
    if (!lua_istable(L, ArgsIndex)) {
      LuaHelpers::ReportScriptErrorFmt(
          "ActorMultiVertex:SetDrawState: Table expected, something else "
          "recieved.  Doing nothing.");
      COMMON_RETURN_SELF;
    }
    // Fetch the draw mode, if provided.
    lua_getfield(L, ArgsIndex, "Mode");
    if (!lua_isnil(L, -1)) {
      dm = Enum::Check<DrawMode>(L, -1);
    }
    lua_pop(L, 1);
    // Fetch FirstToDraw, if provided.
    lua_getfield(L, ArgsIndex, "First");
    if (!lua_isnil(L, -1)) {
      // Indices from Lua are one-indexed.  -1 to adjust.
      first = IArg(-1) - 1;
    }
    lua_pop(L, 1);
    // Fetch NumToDraw, if provided.
    lua_getfield(L, ArgsIndex, "Num");
    if (!lua_isnil(L, -1)) {
      num = IArg(-1);
    }
    lua_pop(L, 1);
    p->SetDrawState(dm, first, num);
    COMMON_RETURN_SELF;
  }

  static int GetDestDrawMode(T* p, lua_State* L) {
    Enum::Push(L, p->GetDestDrawMode());
    return 1;
  }

  static int GetDestFirstToDraw(T* p, lua_State* L) {
    // Indices in Lua are one-indexed.  +1 to adjust.
    lua_pushnumber(L, p->GetDestFirstToDraw() + 1);
    return 1;
  }

  static int GetDestNumToDraw(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetDestNumToDraw());
    return 1;
  }

  static int GetCurrDrawMode(T* p, lua_State* L) {
    Enum::Push(L, p->GetCurrDrawMode());
    return 1;
  }

  static int GetCurrFirstToDraw(T* p, lua_State* L) {
    // Indices in Lua are one-indexed.  +1 to adjust.
    lua_pushnumber(L, p->GetCurrFirstToDraw() + 1);
    return 1;
  }

  static int GetCurrNumToDraw(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetCurrNumToDraw());
    return 1;
  }

  static int LoadTexture(T* p, lua_State* L) {
    if (TEXTUREMAN == nullptr) {
      LuaHelpers::ReportScriptError(
          "ActorMultiVertex: cannot load texture without texture manager.");
      COMMON_RETURN_SELF;
    }
    if (lua_isnil(L, 1)) {
      p->UnloadTexture();
      p->LoadFromTexture(TEXTUREMAN->GetDefaultTextureID());
    } else {
      RageTextureID ID(SArg(1));
      TEXTUREMAN->DisableOddDimensionWarning();
      p->LoadFromTexture(ID);
      TEXTUREMAN->EnableOddDimensionWarning();
    }
    COMMON_RETURN_SELF;
  }

  static int GetSpline(T* p, lua_State* L) {
    size_t i = static_cast<size_t>(IArg(1) - 1);
    if (i >= ActorMultiVertex::num_vert_splines) {
      luaL_error(
          L,
          "Spline index must be greater than 0 and less than or equal to %zu.",
          ActorMultiVertex::num_vert_splines);
    }
    p->GetSpline(i)->PushSelf(L);
    return 1;
  }

  static int SetVertsFromSplines(T* p, lua_State* L) {
    p->SetVertsFromSplines();
    COMMON_RETURN_SELF;
  }

  DEFINE_METHOD(GetUseAnimationState, _use_animation_state);
  static int SetUseAnimationState(T* p, lua_State* L) {
    p->_use_animation_state = BArg(1);
    COMMON_RETURN_SELF;
  }
  static int GetNumStates(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetNumStates());
    return 1;
  }
  static void FillStateFromLua(
      lua_State* L, ActorMultiVertex::State& state, RageTexture* tex,
      int index) {
    if (tex == nullptr) {
      luaL_error(L, "The texture must be set before adding states.");
    }
    // State looks like this:
    // {{left, top, right, bottom}, delay}
#define DATA_ERROR(i)                                                       \
  if (!lua_istable(L, i)) {                                                 \
    luaL_error(                                                             \
        L,                                                                  \
        "The state data must be in a table like this: {{left, top, right, " \
        "bottom}, delay}");                                                 \
  }
#define SET_SIDE(i, side) \
  lua_rawgeti(L, -1, i);  \
  state.side = FArg(-1);  \
  lua_pop(L, 1);

    DATA_ERROR(index);
    lua_rawgeti(L, index, 1);
    DATA_ERROR(-1);
    SET_SIDE(1, rect.left);
    SET_SIDE(2, rect.top);
    SET_SIDE(3, rect.right);
    SET_SIDE(4, rect.bottom);
    lua_pop(L, 1);
    SET_SIDE(2, delay);
    const float width_ratio = tex->GetImageToTexCoordsRatioX();
    const float height_ratio = tex->GetImageToTexCoordsRatioY();
    if (!std::isfinite(state.delay) || state.delay <= min_state_delay) {
      state.delay = min_state_delay;
    }
    if (!IsFiniteRect(state.rect) || !std::isfinite(width_ratio) ||
        !std::isfinite(height_ratio) || width_ratio <= 0.0f ||
        height_ratio <= 0.0f) {
      luaL_error(L, "ActorMultiVertex: invalid state rectangle.");
    }
    state.rect.left = state.rect.left * width_ratio;
    state.rect.top = state.rect.top * height_ratio;
    // Pixel centers are at .5, so add an extra pixel to the size to adjust.
    state.rect.right = (state.rect.right * width_ratio) + width_ratio;
    state.rect.bottom = (state.rect.bottom * height_ratio) + height_ratio;
#undef SET_SIDE
#undef DATA_ERROR
  }
  static int AddState(T* p, lua_State* L) {
    ActorMultiVertex::State s;
    FillStateFromLua(L, s, p->GetTexture(), 1);
    p->AddState(s);
    COMMON_RETURN_SELF;
  }
  static size_t ValidStateIndex(T* p, lua_State* L, int pos) {
    int index = IArg(pos) - 1;
    if (index < 0 || index >= p->GetNumStates()) {
      luaL_error(L, "Invalid state index %d.", index + 1);
    }
    return static_cast<size_t>(index);
  }
  static int RemoveState(T* p, lua_State* L) {
    p->RemoveState(ValidStateIndex(p, L, 1));
    COMMON_RETURN_SELF;
  }
  static int GetState(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetState() + 1);
    return 1;
  }
  static int SetState(T* p, lua_State* L) {
    p->SetState(ValidStateIndex(p, L, 1));
    COMMON_RETURN_SELF;
  }
  static int GetStateData(T* p, lua_State* L) {
    RageTexture* tex = p->GetTexture();
    if (tex == nullptr) {
      luaL_error(L, "The texture must be set before adding states.");
    }
    const float width_pix = tex->GetImageToTexCoordsRatioX();
    const float height_pix = tex->GetImageToTexCoordsRatioY();
    const float width_ratio = 1.0f / tex->GetImageToTexCoordsRatioX();
    const float height_ratio = 1.0f / tex->GetImageToTexCoordsRatioY();
    const ActorMultiVertex::State& state =
        p->GetStateData(ValidStateIndex(p, L, 1));
    lua_createtable(L, 2, 0);
    lua_createtable(L, 4, 0);
    lua_pushnumber(L, static_cast<lua_Number>(state.rect.left) * width_ratio);
    lua_rawseti(L, -2, 1);
    lua_pushnumber(L, static_cast<lua_Number>(state.rect.top) * height_ratio);
    lua_rawseti(L, -2, 2);
    lua_pushnumber(
        L,
        (static_cast<lua_Number>(state.rect.right) - width_pix) * width_ratio);
    lua_rawseti(L, -2, 3);
    lua_pushnumber(
        L, (static_cast<lua_Number>(state.rect.bottom) - height_pix) *
               height_ratio);
    lua_rawseti(L, -2, 4);
    lua_rawseti(L, -2, 1);
    lua_pushnumber(L, state.delay);
    lua_rawseti(L, -2, 2);
    return 1;
  }
  static int SetStateData(T* p, lua_State* L) {
    ActorMultiVertex::State& state = p->GetStateData(ValidStateIndex(p, L, 1));
    FillStateFromLua(L, state, p->GetTexture(), 2);
    COMMON_RETURN_SELF;
  }
  static int SetStateProperties(T* p, lua_State* L) {
    if (!lua_istable(L, 1)) {
      luaL_error(L, "The states must be inside a table.");
    }
    RageTexture* tex = p->GetTexture();
    if (tex == nullptr) {
      luaL_error(L, "The texture must be set before adding states.");
    }
    std::vector<ActorMultiVertex::State> new_states;
    size_t num_states = lua_objlen(L, 1);
    new_states.resize(num_states);
    for (size_t i = 0; i < num_states; ++i) {
      lua_rawgeti(L, 1, i + 1);
      FillStateFromLua(L, new_states[i], tex, -1);
      lua_pop(L, 1);
    }
    p->SetStateProperties(new_states);
    COMMON_RETURN_SELF;
  }
  static int SetAllStateDelays(T* p, lua_State* L) {
    p->SetAllStateDelays(FArg(1));
    COMMON_RETURN_SELF;
  }
  DEFINE_METHOD(GetAnimationLengthSeconds, GetAnimationLengthSeconds());
  static int SetSecondsIntoAnimation(T* p, lua_State* L) {
    p->SetSecondsIntoAnimation(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int GetNumQuadStates(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetNumQuadStates());
    return 1;
  }
  static size_t QuadStateIndex(T* p, lua_State* L, int pos) {
    int index = IArg(pos) - 1;
    if (index < 0 || static_cast<size_t>(index) >= p->GetNumQuadStates()) {
      luaL_error(L, "Invalid state index %d.", index + 1);
    }
    return static_cast<size_t>(index);
  }
  static int AddQuadState(T* p, lua_State* L) {
    int state = IArg(1) - 1;
    if (state < 0) {
      luaL_error(L, "Invalid state index %d.", state + 1);
    }
    p->AddQuadState(static_cast<size_t>(state));
    COMMON_RETURN_SELF;
  }
  static int RemoveQuadState(T* p, lua_State* L) {
    p->RemoveQuadState(QuadStateIndex(p, L, 1));
    COMMON_RETURN_SELF;
  }
  static int GetQuadState(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetQuadState(QuadStateIndex(p, L, 1)) + 1);
    return 1;
  }
  static int SetQuadState(T* p, lua_State* L) {
    int state = IArg(2) - 1;
    if (state < 0) {
      luaL_error(L, "Invalid state index %d.", state + 1);
    }
    p->SetQuadState(QuadStateIndex(p, L, 1), static_cast<size_t>(state));
    COMMON_RETURN_SELF;
  }
  static int ForceStateUpdate(T* p, lua_State* L) {
    p->UpdateAnimationState(true);
    COMMON_RETURN_SELF;
  }
  DEFINE_METHOD(GetDecodeMovie, _decode_movie);
  static int SetDecodeMovie(T* p, lua_State* L) {
    p->_decode_movie = BArg(1);
    COMMON_RETURN_SELF;
  }

  static int SetTexture(T* p, lua_State* L) {
    RageTexture* Texture = Luna<RageTexture>::check(L, 1);
    p->SetTexture(Texture);
    COMMON_RETURN_SELF;
  }
  static int GetTexture(T* p, lua_State* L) {
    RageTexture* texture = p->GetTexture();
    if (texture != nullptr) {
      texture->PushSelf(L);
    } else {
      lua_pushnil(L);
    }
    return 1;
  }

  LunaActorMultiVertex() {
    ADD_METHOD(SetVertex);
    ADD_METHOD(SetVertices);

    ADD_METHOD(SetEffectMode);
    ADD_METHOD(SetTextureMode);
    ADD_METHOD(SetLineWidth);

    ADD_METHOD(SetDrawState);
    ADD_METHOD(SetNumVertices);
    ADD_METHOD(GetNumVertices);
    ADD_METHOD(GetDestDrawMode);
    ADD_METHOD(GetDestFirstToDraw);
    ADD_METHOD(GetDestNumToDraw);
    ADD_METHOD(GetCurrDrawMode);
    ADD_METHOD(GetCurrFirstToDraw);
    ADD_METHOD(GetCurrNumToDraw);

    ADD_METHOD(GetSpline);
    ADD_METHOD(SetVertsFromSplines);

    ADD_METHOD(GetUseAnimationState);
    ADD_METHOD(SetUseAnimationState);
    ADD_METHOD(GetNumStates);
    ADD_METHOD(GetNumQuadStates);
    ADD_METHOD(AddState);
    ADD_METHOD(RemoveState);
    ADD_METHOD(GetState);
    ADD_METHOD(SetState);
    ADD_METHOD(GetStateData);
    ADD_METHOD(SetStateData);
    ADD_METHOD(SetStateProperties);
    ADD_METHOD(SetAllStateDelays);
    ADD_METHOD(SetSecondsIntoAnimation);
    ADD_METHOD(AddQuadState);
    ADD_METHOD(RemoveQuadState);
    ADD_METHOD(GetQuadState);
    ADD_METHOD(SetQuadState);
    ADD_METHOD(ForceStateUpdate);
    ADD_METHOD(GetDecodeMovie);
    ADD_METHOD(SetDecodeMovie);

    // Copy from RageTexture
    ADD_METHOD(SetTexture);
    ADD_METHOD(GetTexture);
    // Load from file path
    ADD_METHOD(LoadTexture);
  }
};

LUA_REGISTER_DERIVED_CLASS(ActorMultiVertex, Actor)

/*
 * (c) 2014 Matthew Gardner and Eric Reese
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
