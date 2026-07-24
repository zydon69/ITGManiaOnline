#include "ModIcon.h"

#include <algorithm>
#include <string>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "StdString.h"
#include "ThemeManager.h"

namespace {
void WarnModIcon(const char* message) {
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

int SanitizeCropTextWidth(int width) {
  return std::clamp(width, 0, 4096);
}
}  // namespace

ModIcon::ModIcon() { m_iCropTextToWidth = 0; }

ModIcon::ModIcon(const ModIcon& cpy)
    : ActorFrame(cpy),
      m_text(cpy.m_text),
      m_sprFilled(cpy.m_sprFilled),
      m_sprEmpty(cpy.m_sprEmpty),
      CROP_TEXT_TO_WIDTH(cpy.CROP_TEXT_TO_WIDTH),
      STOP_WORDS(cpy.STOP_WORDS),
      m_iCropTextToWidth(cpy.m_iCropTextToWidth),
      m_vStopWords(cpy.m_vStopWords) {
  this->RemoveAllChildren();
  this->AddChild(m_sprFilled);
  this->AddChild(m_sprEmpty);
  this->AddChild(&m_text);
}

void ModIcon::Load(std::string sMetricsGroup) {
  DetachAndUnload(*this, m_sprFilled);
  DetachAndUnload(*this, m_sprEmpty);
  RemoveChild(&m_text);

  if (THEME != nullptr && !sMetricsGroup.empty()) {
    m_sprFilled.Load(THEME->GetPathG(sMetricsGroup, "Filled"));
  } else {
    WarnModIcon("ModIcon loaded without THEME.");
    m_sprFilled.LoadFallback();
  }
  if (m_sprFilled.IsLoaded()) {
    m_sprFilled->SetName("Filled");
    if (THEME != nullptr && !sMetricsGroup.empty()) {
      ActorUtil::LoadAllCommands(m_sprFilled, sMetricsGroup);
    }
    this->AddChild(m_sprFilled);
  }

  if (THEME != nullptr && !sMetricsGroup.empty()) {
    m_sprEmpty.Load(THEME->GetPathG(sMetricsGroup, "Empty"));
  } else {
    m_sprEmpty.LoadFallback();
  }
  if (m_sprEmpty.IsLoaded()) {
    m_sprEmpty->SetName("Empty");
    if (THEME != nullptr && !sMetricsGroup.empty()) {
      ActorUtil::LoadAllCommands(m_sprEmpty, sMetricsGroup);
    }
    this->AddChild(m_sprEmpty);
  }

  if (THEME != nullptr && !sMetricsGroup.empty()) {
    m_text.LoadFromFont(THEME->GetPathF(sMetricsGroup, "Text"));
  }
  m_text.SetName("Text");
  if (THEME != nullptr && !sMetricsGroup.empty()) {
    ActorUtil::LoadAllCommandsAndSetXYAndOnCommand(m_text, sMetricsGroup);
  }
  this->AddChild(&m_text);

  m_iCropTextToWidth = 0;
  if (THEME != nullptr && !sMetricsGroup.empty()) {
    CROP_TEXT_TO_WIDTH.Load(sMetricsGroup, "CropTextToWidth");
    m_iCropTextToWidth =
        SanitizeCropTextWidth(CROP_TEXT_TO_WIDTH.GetValue());
  }

  // stop words
  std::string stopWords;
  if (THEME != nullptr && !sMetricsGroup.empty()) {
    STOP_WORDS.Load(sMetricsGroup, "StopWords");
    stopWords = STOP_WORDS.GetValue();
  }
  m_vStopWords.clear();
  if (stopWords != "") {
    split(stopWords, ",", m_vStopWords);
  }
  for (std::string& stopWord : m_vStopWords) {
    Trim(stopWord);
  }
  m_vStopWords.erase(
      std::remove(m_vStopWords.begin(), m_vStopWords.end(), ""),
      m_vStopWords.end());

  Set("");
}

void ModIcon::Set(const std::string& _sText) {
  std::string sText = _sText;

  for (unsigned i = 0; i < m_vStopWords.size(); i++) {
    if (EqualsNoCase(sText, m_vStopWords[i])) {
      sText = "";
    }
  }

  Replace(sText, " ", "\n");

  bool bVacant = (sText == "");
  if (m_sprFilled.IsLoaded()) {
    m_sprFilled->SetVisible(!bVacant);
  }
  if (m_sprEmpty.IsLoaded()) {
    m_sprEmpty->SetVisible(bVacant);
  }

  m_text.SetText(sText);
  m_text.CropToWidth(m_iCropTextToWidth);
}

/*
 * (c) 2002-2004 Chris Danford
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
