#include "OptionsCursor.h"

#include <cmath>
#include <string>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "ThemeManager.h"
#include "Tween.h"

namespace {
void WarnOptionsCursor(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void DetachAndUnload(ActorFrame& frame, AutoActor& actor) {
  if (actor.IsLoaded()) {
    frame.RemoveChild(actor);
  }
  actor.Unload();
}

bool LoadCursorSprite(
    ActorFrame& frame,
    AutoActor& actor,
    const std::string& group,
    const std::string& name) {
  DetachAndUnload(frame, actor);
  if (THEME != nullptr && !group.empty()) {
    actor.Load(THEME->GetPathG(group, name));
  } else {
    WarnOptionsCursor("SRC_AUDIT_FIX SRC-1212: OptionsCursor loaded without THEME.");
    actor.Load(new Actor);
  }
  if (!actor.IsLoaded()) {
    return false;
  }
  actor->SetName(name);
  if (THEME != nullptr && !group.empty()) {
    ActorUtil::LoadAllCommandsAndSetXYAndOnCommand(actor, group);
  }
  frame.AddChild(actor);
  return true;
}

float SanitizeBarWidth(int width) {
  if (width <= 0) {
    return 0.0f;
  }
  return std::min(std::ceil(width / 2.0f) * 2.0f, 10000.0f);
}
}  // namespace

OptionsCursor::OptionsCursor() {
  m_iOriginalLeftX = 0;
  m_iOriginalRightX = 0;
  m_iOriginalCanGoLeftX = 0;
  m_iOriginalCanGoRightX = 0;
}

OptionsCursor::OptionsCursor(const OptionsCursor& cpy)
    : ActorFrame(cpy),
      m_sprMiddle(cpy.m_sprMiddle),
      m_sprLeft(cpy.m_sprLeft),
      m_sprRight(cpy.m_sprRight),
      m_sprCanGoLeft(cpy.m_sprCanGoLeft),
      m_sprCanGoRight(cpy.m_sprCanGoRight),
      m_iOriginalLeftX(cpy.m_iOriginalLeftX),
      m_iOriginalRightX(cpy.m_iOriginalRightX),
      m_iOriginalCanGoLeftX(cpy.m_iOriginalCanGoLeftX),
      m_iOriginalCanGoRightX(cpy.m_iOriginalCanGoRightX) {
  // Re-add children, or m_SubActors will point to cpy's children and not our
  // own.
  m_SubActors.clear();
  this->AddChild(m_sprMiddle);
  this->AddChild(m_sprLeft);
  this->AddChild(m_sprRight);
  if (m_sprCanGoLeft) {
    this->AddChild(m_sprCanGoLeft);
  }
  if (m_sprCanGoRight) {
    this->AddChild(m_sprCanGoRight);
  }
}

void OptionsCursor::Load(const std::string& sMetricsGroup, bool bLoadCanGos) {
  LoadCursorSprite(*this, m_sprMiddle, sMetricsGroup, "Middle");
  LoadCursorSprite(*this, m_sprLeft, sMetricsGroup, "Left");
  LoadCursorSprite(*this, m_sprRight, sMetricsGroup, "Right");
  if (bLoadCanGos) {
    LoadCursorSprite(*this, m_sprCanGoLeft, sMetricsGroup, "CanGoLeft");
    LoadCursorSprite(*this, m_sprCanGoRight, sMetricsGroup, "CanGoRight");
  } else {
    DetachAndUnload(*this, m_sprCanGoLeft);
    DetachAndUnload(*this, m_sprCanGoRight);
  }

  m_iOriginalLeftX =
      m_sprLeft.IsLoaded() ? static_cast<int>(m_sprLeft->GetX()) : 0;
  m_iOriginalRightX =
      m_sprRight.IsLoaded() ? static_cast<int>(m_sprRight->GetX()) : 0;
  if (m_sprCanGoLeft.IsLoaded() && m_sprCanGoRight.IsLoaded()) {
    m_iOriginalCanGoLeftX = static_cast<int>(m_sprCanGoLeft->GetX());
    m_iOriginalCanGoRightX = static_cast<int>(m_sprCanGoRight->GetX());
  } else {
    m_iOriginalCanGoLeftX = 0;
    m_iOriginalCanGoRightX = 0;
  }

  SetCanGo(false, false);
}

void OptionsCursor::SetCanGo(bool bCanGoLeft, bool bCanGoRight) {
  if (m_sprCanGoLeft.IsLoaded() && m_sprCanGoRight.IsLoaded()) {
    m_sprCanGoLeft->EnableAnimation(bCanGoLeft);
    m_sprCanGoRight->EnableAnimation(bCanGoRight);

    m_sprCanGoLeft->SetDiffuse(
        bCanGoLeft ? RageColor(1, 1, 1, 1) : RageColor(1, 1, 1, 0));
    m_sprCanGoRight->SetDiffuse(
        bCanGoRight ? RageColor(1, 1, 1, 1) : RageColor(1, 1, 1, 0));
  }
}

void OptionsCursor::StopTweening() {
  ActorFrame::StopTweening();

  if (m_sprMiddle.IsLoaded()) {
    m_sprMiddle->StopTweening();
  }
  if (m_sprLeft.IsLoaded()) {
    m_sprLeft->StopTweening();
  }
  if (m_sprRight.IsLoaded()) {
    m_sprRight->StopTweening();
  }

  if (m_sprCanGoLeft.IsLoaded() && m_sprCanGoRight.IsLoaded()) {
    m_sprCanGoLeft->StopTweening();
    m_sprCanGoRight->StopTweening();
  }
}

void OptionsCursor::BeginTweening(float fSecs, TweenType tt) {
  ActorFrame::BeginTweening(fSecs, tt);

  if (m_sprMiddle.IsLoaded()) {
    m_sprMiddle->BeginTweening(fSecs, tt);
  }
  if (m_sprLeft.IsLoaded()) {
    m_sprLeft->BeginTweening(fSecs, tt);
  }
  if (m_sprRight.IsLoaded()) {
    m_sprRight->BeginTweening(fSecs, tt);
  }

  if (m_sprCanGoLeft.IsLoaded() && m_sprCanGoRight.IsLoaded()) {
    m_sprCanGoLeft->BeginTweening(fSecs, tt);
    m_sprCanGoRight->BeginTweening(fSecs, tt);
  }
}

void OptionsCursor::SetBarWidth(int iWidth) {
  float fWidth = SanitizeBarWidth(iWidth);

  if (m_sprMiddle.IsLoaded()) {
    m_sprMiddle->ZoomToWidth(fWidth);
  }

  if (m_sprLeft.IsLoaded()) {
    m_sprLeft->SetX(m_iOriginalLeftX - fWidth / 2);
  }
  if (m_sprRight.IsLoaded()) {
    m_sprRight->SetX(m_iOriginalRightX + fWidth / 2);
  }
  if (m_sprCanGoLeft.IsLoaded() && m_sprCanGoRight.IsLoaded()) {
    m_sprCanGoLeft->SetX(m_iOriginalCanGoLeftX - fWidth / 2);
    m_sprCanGoRight->SetX(m_iOriginalCanGoRightX + fWidth / 2);
  }
}

int OptionsCursor::GetBarWidth() const {
  if (!m_sprMiddle.IsLoaded()) {
    return 0;
  }
  float fWidth = m_sprMiddle->GetZoomX() * m_sprMiddle->GetUnzoomedWidth();
  if (!std::isfinite(fWidth) || fWidth < 0.0f) {
    return 0;
  }
  return (int)fWidth;
}

/*
 * (c) 2001-2003 Chris Danford
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
