#include "BGAnimation.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "Actor.h"
#include "ActorFrame.h"
#include "ActorUtil.h"
#include "BGAnimationLayer.h"
#include "IniFile.h"
#include "LuaManager.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "StdString.h"
#include "XmlFile.h"
#include "global.h"

REGISTER_ACTOR_CLASS(BGAnimation);

BGAnimation::BGAnimation() {}

BGAnimation::~BGAnimation() { DeleteAllChildren(); }

namespace {
constexpr size_t MAX_BG_ANIMATION_IMPORT_DEPTH = 64;

bool ParseLayerNumber(const std::string& name, int& number) {
  constexpr char prefix[] = "Layer";
  if (name.compare(0, sizeof(prefix) - 1, prefix) != 0 ||
      name.size() == sizeof(prefix) - 1) {
    return false;
  }
  const std::string suffix = name.substr(sizeof(prefix) - 1);
  if (!std::all_of(suffix.begin(), suffix.end(), [](unsigned char ch) {
        return std::isdigit(ch) != 0;
      })) {
    return false;
  }
  size_t parsed = 0;
  number = StringToInt(suffix, &parsed, 10, -1);
  return parsed == suffix.size() && number >= 0;
}
}  // namespace

static bool CompareLayerNames(const std::string& s1, const std::string& s2) {
  int i1 = 0;
  int i2 = 0;
  const bool bParsed1 = ParseLayerNumber(s1, i1);
  const bool bParsed2 = ParseLayerNumber(s2, i2);
  if (!bParsed1 || !bParsed2) {
    LOG->Warn(
        "BGAnimation saw malformed layer names '%s' "
        "and '%s'.",
        s1.c_str(), s2.c_str());
    if (bParsed1 != bParsed2) {
      return bParsed1;
    }
    return s1 < s2;
  }
  if (i1 != i2) {
    return i1 < i2;
  }
  return s1 < s2;
}

void BGAnimation::AddLayersFromAniDir(
    const std::string& _sAniDir, const XNode* pNode) {
  std::vector<std::string> importStack;
  AddLayersFromAniDir(_sAniDir, pNode, importStack);
}

void BGAnimation::AddLayersFromAniDir(
    const std::string& _sAniDir, const XNode* pNode,
    std::vector<std::string>& importStack) {
  if (pNode == nullptr) {
    LOG->Warn(
        "BGAnimation ignored a null animation node for "
        "'%s'.",
        _sAniDir.c_str());
    return;
  }
  if (importStack.size() >= MAX_BG_ANIMATION_IMPORT_DEPTH) {
    LOG->Warn(
        "BGAnimation stopped imports at depth %zu "
        "while loading '%s'.",
        importStack.size(), _sAniDir.c_str());
    return;
  }
  const std::string& sAniDir = _sAniDir;
  if (std::find(importStack.begin(), importStack.end(), sAniDir) !=
      importStack.end()) {
    LOG->Warn(
        "BGAnimation skipped circular import at '%s'.",
        sAniDir.c_str());
    return;
  }
  importStack.push_back(sAniDir);

  {
    std::vector<std::string> vsLayerNames;
    FOREACH_CONST_Child(pNode, pLayer) {
      if (strncmp(pLayer->GetName().c_str(), "Layer", 5) == 0) {
        vsLayerNames.push_back(pLayer->GetName());
      }
    }

    sort(vsLayerNames.begin(), vsLayerNames.end(), CompareLayerNames);

    for (const std::string& sLayer : vsLayerNames) {
      const XNode* pKey = pNode->GetChild(sLayer);
      if (pKey == nullptr) {
        LOG->Warn(
            "BGAnimation layer '%s' disappeared while "
            "loading '%s'.",
            sLayer.c_str(), sAniDir.c_str());
        continue;
      }

      std::string sImportDir;
      if (pKey->GetAttrValue("Import", sImportDir)) {
        bool bCond;
        if (pKey->GetAttrValue("Condition", bCond) && !bCond) {
          continue;
        }

        // import a whole BGAnimation
        const std::string sRawImportDir = sImportDir;
        sImportDir = sAniDir + sImportDir;
        CollapsePath(sImportDir);

        if (Right(sImportDir, 1) != "/") {
          sImportDir += "/";
        }

        if (sImportDir.compare(0, sAniDir.size(), sAniDir) != 0) {
          LOG->Warn(
              "BGAnimation rejected import '%s' from "
              "'%s' because it escapes the animation directory.",
              sRawImportDir.c_str(), sAniDir.c_str());
          continue;
        }

        if (!IsADirectory(sImportDir)) {
          LOG->Warn(
              "BGAnimation import '%s' is not a "
              "directory.",
              sImportDir.c_str());
          continue;
        }

        std::string sPathToIni = sImportDir + "BGAnimation.ini";

        IniFile ini2;
        if (!ini2.ReadFile(sPathToIni)) {
          LOG->Warn(
              "BGAnimation import '%s' could not read "
              "BGAnimation.ini.",
              sImportDir.c_str());
          continue;
        }

        AddLayersFromAniDir(sImportDir, &ini2, importStack);
      } else {
        // import as a single layer
        std::unique_ptr<BGAnimationLayer> bgLayer(new BGAnimationLayer);
        bgLayer->LoadFromNode(pKey);
        if (bgLayer->GetNumChildren() == 0) {
          LOG->Warn(
              "BGAnimation skipped empty layer '%s' "
              "while loading '%s'.",
              sLayer.c_str(), sAniDir.c_str());
          continue;
        }
        this->AddChild(bgLayer.release());
      }
    }
  }
  importStack.pop_back();
}

void BGAnimation::LoadFromAniDir(const std::string& _sAniDir) {
  if (_sAniDir.empty()) {
    DeleteAllChildren();
    return;
  }

  std::string sAniDir = _sAniDir;
  if (Right(sAniDir, 1) != "/") {
    sAniDir += "/";
  }

  if (!IsADirectory(sAniDir)) {
    LOG->Warn(
        "BGAnimation directory '%s' does not exist.",
        sAniDir.c_str());
    return;
  }

  std::string sPathToIni = sAniDir + "BGAnimation.ini";

  if (DoesFileExist(sPathToIni)) {
    if (PREFSMAN != nullptr && PREFSMAN->m_bQuirksMode) {
      // This is a 3.9-style BGAnimation (using .ini)
      IniFile ini;
      if (!ini.ReadFile(sPathToIni)) {
        LOG->Warn(
            "BGAnimation could not read '%s'.",
            sPathToIni.c_str());
        return;
      }

      DeleteAllChildren();
      AddLayersFromAniDir(sAniDir, &ini);

      XNode* pBGAnimation = ini.GetChild("BGAnimation");
      XNode dummy("BGAnimation");
      if (pBGAnimation == nullptr) {
        pBGAnimation = &dummy;
      }

      LoadFromNode(pBGAnimation);
    } else  // We don't officially support .ini files anymore.
    {
      DeleteAllChildren();
      XNode dummy("BGAnimation");
      XNode* pBG = &dummy;
      LoadFromNode(pBG);
    }
  } else {
    // This is an 3.0 and before-style BGAnimation (not using .ini)

    // loading a directory of layers
    std::vector<std::string> asImagePaths;
    GetDirListing(sAniDir + "*.png", asImagePaths, false, true);
    GetDirListing(sAniDir + "*.jpg", asImagePaths, false, true);
    GetDirListing(sAniDir + "*.jpeg", asImagePaths, false, true);
    GetDirListing(sAniDir + "*.gif", asImagePaths, false, true);
    GetDirListing(sAniDir + "*.ogv", asImagePaths, false, true);
    GetDirListing(sAniDir + "*.avi", asImagePaths, false, true);
    GetDirListing(sAniDir + "*.mpg", asImagePaths, false, true);
    GetDirListing(sAniDir + "*.mpeg", asImagePaths, false, true);

    SortRStringArray(asImagePaths);
    DeleteAllChildren();

    for (unsigned i = 0; i < asImagePaths.size(); i++) {
      const std::string sPath = asImagePaths[i];
      if (Left(Basename(sPath), 1) == "_") {
        continue;  // don't directly load files starting with an underscore
      }
      BGAnimationLayer* pLayer = new BGAnimationLayer;
      pLayer->LoadFromAniLayerFile(asImagePaths[i]);
      if (pLayer->GetNumChildren() == 0) {
        LOG->Warn(
            "BGAnimation skipped empty legacy layer "
            "'%s'.",
            asImagePaths[i].c_str());
        delete pLayer;
      } else {
        AddChild(pLayer);
      }
    }
  }
}

void BGAnimation::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    LOG->Warn("BGAnimation ignored null node.");
    return;
  }
  std::string sDir;
  if (pNode->GetAttrValue("AniDir", sDir)) {
    LoadFromAniDir(sDir);
  }

  ActorFrame::LoadFromNode(pNode);

  /* Backwards-compatibility: if a "LengthSeconds" value is present, create a
   * dummy actor that sleeps for the given length of time. This will extend
   * GetTweenTimeLeft. */
  float fLengthSeconds = 0;
  if (pNode->GetAttrValue("LengthSeconds", fLengthSeconds)) {
    if (!std::isfinite(fLengthSeconds) || fLengthSeconds < 0.0f) {
      LOG->Warn(
          "BGAnimation ignored invalid LengthSeconds "
          "%.6f.",
          fLengthSeconds);
      return;
    }
    Actor* pActor = new Actor;
    pActor->SetName("BGAnimation dummy");
    pActor->SetVisible(false);
    apActorCommands ap =
        ActorUtil::ParseActorCommands(ssprintf("sleep,%f", fLengthSeconds));
    pActor->AddCommand("On", ap);
    AddChild(pActor);
  }
}

/*
 * (c) 2001-2004 Ben Nordstrom, Chris Danford
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
