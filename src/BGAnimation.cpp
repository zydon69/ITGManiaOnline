#include "BGAnimation.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
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

static bool CompareLayerNames(const std::string& s1, const std::string& s2) {
  int i1 = 0;
  int i2 = 0;
  const bool bParsed1 = sscanf(s1.c_str(), "Layer%d", &i1) == 1;
  const bool bParsed2 = sscanf(s2.c_str(), "Layer%d", &i2) == 1;
  if (!bParsed1 || !bParsed2) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-701: BGAnimation saw malformed layer names '%s' "
        "and '%s'.",
        s1.c_str(), s2.c_str());
    if (bParsed1 != bParsed2) {
      return bParsed1;
    }
    return s1 < s2;
  }
  return i1 < i2;
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
        "SRC_AUDIT_FIX SRC-702: BGAnimation ignored a null animation node for "
        "'%s'.",
        _sAniDir.c_str());
    return;
  }
  const std::string& sAniDir = _sAniDir;
  if (std::find(importStack.begin(), importStack.end(), sAniDir) !=
      importStack.end()) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-703: BGAnimation skipped circular import at '%s'.",
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
            "SRC_AUDIT_FIX SRC-702: BGAnimation layer '%s' disappeared while "
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
              "SRC_AUDIT_FIX SRC-703: BGAnimation rejected import '%s' from "
              "'%s' because it escapes the animation directory.",
              sRawImportDir.c_str(), sAniDir.c_str());
          continue;
        }

        if (!IsADirectory(sImportDir)) {
          LOG->Warn(
              "SRC_AUDIT_FIX SRC-703: BGAnimation import '%s' is not a "
              "directory.",
              sImportDir.c_str());
          continue;
        }

        std::string sPathToIni = sImportDir + "BGAnimation.ini";

        IniFile ini2;
        if (!ini2.ReadFile(sPathToIni)) {
          LOG->Warn(
              "SRC_AUDIT_FIX SRC-703: BGAnimation import '%s' could not read "
              "BGAnimation.ini.",
              sImportDir.c_str());
          continue;
        }

        AddLayersFromAniDir(sImportDir, &ini2, importStack);
      } else {
        // import as a single layer
        BGAnimationLayer* bgLayer = new BGAnimationLayer;
        bgLayer->LoadFromNode(pKey);
        this->AddChild(bgLayer);
      }
    }
  }
  importStack.pop_back();
}

void BGAnimation::LoadFromAniDir(const std::string& _sAniDir) {
  DeleteAllChildren();

  if (_sAniDir.empty()) {
    return;
  }

  std::string sAniDir = _sAniDir;
  if (Right(sAniDir, 1) != "/") {
    sAniDir += "/";
  }

  if (!IsADirectory(sAniDir)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-704: BGAnimation directory '%s' does not exist.",
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
            "SRC_AUDIT_FIX SRC-704: BGAnimation could not read '%s'.",
            sPathToIni.c_str());
        return;
      }

      AddLayersFromAniDir(sAniDir, &ini);

      XNode* pBGAnimation = ini.GetChild("BGAnimation");
      XNode dummy("BGAnimation");
      if (pBGAnimation == nullptr) {
        pBGAnimation = &dummy;
      }

      LoadFromNode(pBGAnimation);
    } else  // We don't officially support .ini files anymore.
    {
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

    for (unsigned i = 0; i < asImagePaths.size(); i++) {
      const std::string sPath = asImagePaths[i];
      if (Left(Basename(sPath), 1) == "_") {
        continue;  // don't directly load files starting with an underscore
      }
      BGAnimationLayer* pLayer = new BGAnimationLayer;
      pLayer->LoadFromAniLayerFile(asImagePaths[i]);
      if (pLayer->GetNumChildren() == 0) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-704: BGAnimation skipped empty legacy layer "
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
    LOG->Warn("SRC_AUDIT_FIX SRC-702: BGAnimation ignored null node.");
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
          "SRC_AUDIT_FIX SRC-705: BGAnimation ignored invalid LengthSeconds "
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
