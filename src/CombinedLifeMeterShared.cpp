#include "CombinedLifeMeterShared.h"

#include <cmath>

#include "GameState.h"
#include "PerfDiagnostics.h"
#include "PlayerStageStats.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "RageUtil.h"

CombinedLifeMeterShared::CombinedLifeMeterShared(
    const PlayerState* pPlayerState, PlayerStageStats* pPlayerStageStats,
    LifeType lifeType)
    : m_pLifeMeter(LifeMeter::MakeLifeMeter(lifeType)) {
  if (m_pLifeMeter == nullptr) {
    LOG->Warn("CombinedLifeMeterShared: failed to create inner life meter.");
    return;
  }
  if (pPlayerState == nullptr || pPlayerStageStats == nullptr) {
    LOG->Warn("CombinedLifeMeterShared: missing player state or stage stats.");
    RageUtil::SafeDelete(m_pLifeMeter);
    return;
  }

  m_pLifeMeter->Load(pPlayerState, pPlayerStageStats);
  m_pLifeMeter->SetName("CoopLifeMeterInternal");
  AddChild(m_pLifeMeter);
  LogRoutineCoupleDiagnostics(
      "component=life event=construct player=%d life_type=%d initial=%.6f",
      static_cast<int>(pPlayerState->m_PlayerNumber),
      static_cast<int>(lifeType), m_pLifeMeter->GetLife());
}

CombinedLifeMeterShared::~CombinedLifeMeterShared() {
  if (m_pLifeMeter != nullptr) {
    RemoveChild(m_pLifeMeter);
    RageUtil::SafeDelete(m_pLifeMeter);
  }
}

void CombinedLifeMeterShared::OnLoadSong() {
  if (m_pLifeMeter != nullptr) {
    m_pLifeMeter->OnLoadSong();
    LogRoutineCoupleDiagnostics(
        "component=life event=load_song life=%.6f failing=%d",
        m_pLifeMeter->GetLife(), m_pLifeMeter->IsFailing() ? 1 : 0);
  }
}

void CombinedLifeMeterShared::ChangeLife(
    PlayerNumber pn, TapNoteScore tns) {
  if (ShouldAcceptCallback(pn)) {
    const float before = m_pLifeMeter->GetLife();
    m_pLifeMeter->ChangeLife(tns);
    LogRoutineCoupleDiagnostics(
        "component=life event=tap player=%d judgment=%s before=%.6f "
        "after=%.6f failing=%d",
        static_cast<int>(pn), TapNoteScoreToString(tns).c_str(), before,
        m_pLifeMeter->GetLife(), m_pLifeMeter->IsFailing() ? 1 : 0);
  }
}

void CombinedLifeMeterShared::ChangeLife(
    PlayerNumber pn, HoldNoteScore hns, TapNoteScore tns) {
  if (ShouldAcceptCallback(pn)) {
    const float before = m_pLifeMeter->GetLife();
    m_pLifeMeter->ChangeLife(hns, tns);
    LogRoutineCoupleDiagnostics(
        "component=life event=hold player=%d judgment=%s tap=%s "
        "before=%.6f after=%.6f failing=%d",
        static_cast<int>(pn), HoldNoteScoreToString(hns).c_str(),
        TapNoteScoreToString(tns).c_str(), before, m_pLifeMeter->GetLife(),
        m_pLifeMeter->IsFailing() ? 1 : 0);
  }
}

void CombinedLifeMeterShared::ChangeLife(PlayerNumber pn, float delta) {
  if (ShouldAcceptCallback(pn)) {
    const float before = m_pLifeMeter->GetLife();
    m_pLifeMeter->ChangeLife(delta);
    LogRoutineCoupleDiagnostics(
        "component=life event=delta player=%d delta=%.6f before=%.6f "
        "after=%.6f failing=%d",
        static_cast<int>(pn), delta, before, m_pLifeMeter->GetLife(),
        m_pLifeMeter->IsFailing() ? 1 : 0);
  }
}

void CombinedLifeMeterShared::SetLife(PlayerNumber pn, float value) {
  if (ShouldAcceptCallback(pn) && std::isfinite(value)) {
    const float before = m_pLifeMeter->GetLife();
    m_pLifeMeter->SetLife(value);
    LogRoutineCoupleDiagnostics(
        "component=life event=set player=%d requested=%.6f before=%.6f "
        "after=%.6f failing=%d",
        static_cast<int>(pn), value, before, m_pLifeMeter->GetLife(),
        m_pLifeMeter->IsFailing() ? 1 : 0);
  }
}

void CombinedLifeMeterShared::HandleTapScoreNone(PlayerNumber pn) {
  if (ShouldAcceptCallback(pn)) {
    const float before = m_pLifeMeter->GetLife();
    m_pLifeMeter->HandleTapScoreNone();
    LogRoutineCoupleDiagnostics(
        "component=life event=tap_none player=%d before=%.6f after=%.6f "
        "failing=%d",
        static_cast<int>(pn), before, m_pLifeMeter->GetLife(),
        m_pLifeMeter->IsFailing() ? 1 : 0);
  }
}

bool CombinedLifeMeterShared::IsInDanger() const {
  return m_pLifeMeter != nullptr && m_pLifeMeter->IsInDanger();
}

bool CombinedLifeMeterShared::IsHot() const {
  return m_pLifeMeter != nullptr && m_pLifeMeter->IsHot();
}

bool CombinedLifeMeterShared::IsFailing() const {
  return m_pLifeMeter != nullptr && m_pLifeMeter->IsFailing();
}

float CombinedLifeMeterShared::GetLife(PlayerNumber /*pn*/) const {
  return m_pLifeMeter != nullptr ? m_pLifeMeter->GetLife() : 0.0f;
}

LifeMeter* CombinedLifeMeterShared::GetInnerLifeMeter() const {
  return m_pLifeMeter;
}

bool CombinedLifeMeterShared::ShouldAcceptCallback(PlayerNumber pn) const {
  if (m_pLifeMeter == nullptr) {
    return false;
  }
  if (GAMESTATE == nullptr) {
    LOG->Warn(
        "Routine shared life ignored callback for player %i because GAMESTATE "
        "is null.",
        static_cast<int>(pn));
    return false;
  }

  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  if (pn != master) {
    LogRoutineCoupleDiagnostics(
        "component=life event=callback_ignored reason=non_master player=%d "
        "master=%d",
        static_cast<int>(pn), static_cast<int>(master));
    return false;
  }
  return true;
}
