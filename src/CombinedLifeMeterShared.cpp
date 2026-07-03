#include "CombinedLifeMeterShared.h"

#include <cmath>

#include "GameState.h"
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
  }
}

void CombinedLifeMeterShared::ChangeLife(
    PlayerNumber pn, TapNoteScore tns) {
  if (ShouldAcceptCallback(pn)) {
    m_pLifeMeter->ChangeLife(tns);
  }
}

void CombinedLifeMeterShared::ChangeLife(
    PlayerNumber pn, HoldNoteScore hns, TapNoteScore tns) {
  if (ShouldAcceptCallback(pn)) {
    m_pLifeMeter->ChangeLife(hns, tns);
  }
}

void CombinedLifeMeterShared::ChangeLife(PlayerNumber pn, float delta) {
  if (ShouldAcceptCallback(pn)) {
    m_pLifeMeter->ChangeLife(delta);
  }
}

void CombinedLifeMeterShared::SetLife(PlayerNumber pn, float value) {
  if (ShouldAcceptCallback(pn) && std::isfinite(value)) {
    m_pLifeMeter->SetLife(value);
  }
}

void CombinedLifeMeterShared::HandleTapScoreNone(PlayerNumber pn) {
  if (ShouldAcceptCallback(pn)) {
    m_pLifeMeter->HandleTapScoreNone();
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
    LOG->Trace(
        "Routine shared life ignored non-master callback: player=%i master=%i.",
        static_cast<int>(pn), static_cast<int>(master));
    return false;
  }
  return true;
}
