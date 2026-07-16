#include "ModelTypes.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <limits>
#include <numeric>
#include <string>
#include <unordered_set>

#include "IniFile.h"
#include "RageException.h"
#include "RageFile.h"
#include "RageMath.h"
#include "RageTexture.h"
#include "RageTextureID.h"
#include "RageTextureManager.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "StdString.h"
#include "XmlFile.h"
#include "global.h"

#define MS_MAX_NAME 32

namespace {
constexpr int kMaxBones = 4096;
constexpr int kMaxBoneKeys = 200000;
constexpr int kMaxAnimationKeys = 1000000;
constexpr float kDefaultFrameDelaySeconds = 1.0f;

bool IsFiniteVector(const RageVector2& v) {
  return std::isfinite(v[0]) && std::isfinite(v[1]);
}

bool IsFiniteVector(const RageVector3& v) {
  return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]);
}

void ValidateCount(
    int count, int maxCount, const char* label, const std::string& sPath,
    int iLineNum, const std::string& sLine) {
  if (count < 0 || count > maxCount) {
    RageException::Throw(
        "Parse error in \"%s\" at line %d: invalid %s count %d in \"%s\".",
        sPath.c_str(), iLineNum, label, count, sLine.c_str());
  }
}

void ValidateKeyTime(
    float value, const char* label, const std::string& sPath, int iLineNum,
    const std::string& sLine) {
  if (!std::isfinite(value) || value < 0.0f ||
      value > static_cast<float>(std::numeric_limits<int>::max() - 1)) {
    RageException::Throw(
        "Parse error in \"%s\" at line %d: invalid %s time %.6f in \"%s\".",
        sPath.c_str(), iLineNum, label, value, sLine.c_str());
  }
}

std::string ResolveAnimatedTexturePath(
    const std::string& iniPath, std::string fileName) {
  FixSlashesInPlace(fileName);
  std::vector<std::string> parts;
  split(fileName, "/", parts, false);
  const bool absolute = !fileName.empty() &&
                        (fileName.front() == '/' ||
                         (fileName.size() > 1 && fileName[1] == ':'));
  if (absolute || std::find(parts.begin(), parts.end(), "..") != parts.end()) {
    RageException::Throw(
        "Animated texture \"%s\" references a frame outside its directory: "
        "\"%s\".",
        iniPath.c_str(), fileName.c_str());
  }
  std::string path = Dirname(iniPath) + fileName;
  CollapsePath(path);
  return path;
}
}  // namespace

AnimatedTexture::AnimatedTexture() {
  m_iCurState = 0;
  m_fSecsIntoFrame = 0;
  m_bSphereMapped = false;
  m_vTexOffset = RageVector2(0, 0);
  m_vTexVelocity = RageVector2(0, 0);
  m_BlendMode = BLEND_NORMAL;
}

AnimatedTexture::~AnimatedTexture() { Unload(); }

RageVector3 RadianToDegree(RageVector3 radian) {
  constexpr float RAD_TO_DEG = 180.0f / PI;
  return radian * RAD_TO_DEG;
}

void AnimatedTexture::LoadBlank() {
  Unload();
  AnimatedTextureState state(nullptr, 1, RageVector2(0, 0));
  vFrames.push_back(state);
}

void AnimatedTexture::Load(const std::string& sTexOrIniPath) {
  Unload();

  if (TEXTUREMAN == nullptr) {
    RageException::Throw(
        "Cannot load animated texture \"%s\" without the texture manager.",
        sTexOrIniPath.c_str());
  }

  m_bSphereMapped = sTexOrIniPath.find("sphere") != std::string::npos;
  if (sTexOrIniPath.find("add") != std::string::npos) {
    m_BlendMode = BLEND_ADD;
  } else {
    m_BlendMode = BLEND_NORMAL;
  }

  if (CompareNoCase(GetExtension(sTexOrIniPath), "ini") == 0) {
    IniFile ini;
    if (!ini.ReadFile(sTexOrIniPath)) {
      RageException::Throw(
          "Error reading \"%s\": %s", sTexOrIniPath.c_str(),
          ini.GetError().c_str());
    }

    const XNode* pAnimatedTexture = ini.GetChild("AnimatedTexture");
    if (pAnimatedTexture == nullptr) {
      RageException::Throw(
          "The animated texture file \"%s\" doesn't contain a section called "
          "\"AnimatedTexture\".",
          sTexOrIniPath.c_str());
    }

    pAnimatedTexture->GetAttrValue("TexVelocityX", m_vTexVelocity.x);
    pAnimatedTexture->GetAttrValue("TexVelocityY", m_vTexVelocity.y);
    pAnimatedTexture->GetAttrValue("TexOffsetX", m_vTexOffset.x);
    pAnimatedTexture->GetAttrValue("TexOffsetY", m_vTexOffset.y);
    if (!IsFiniteVector(m_vTexVelocity)) {
      m_vTexVelocity = RageVector2(0, 0);
    }
    if (!IsFiniteVector(m_vTexOffset)) {
      m_vTexOffset = RageVector2(0, 0);
    }

    for (int i = 0; i < 1000; i++) {
      std::string sFileKey = ssprintf("Frame%04d", i);
      std::string sDelayKey = ssprintf("Delay%04d", i);

      std::string sFileName;
      float fDelay = 0;
      if (pAnimatedTexture->GetAttrValue(sFileKey, sFileName) &&
          pAnimatedTexture->GetAttrValue(sDelayKey, fDelay)) {
        if (!std::isfinite(fDelay) || fDelay <= 0.0f) {
          RageException::Throw(
              "Animated texture \"%s\" has invalid delay %.6f for frame %d.",
              sTexOrIniPath.c_str(), fDelay, i);
        }
        std::string sTranslateXKey = ssprintf("TranslateX%04d", i);
        std::string sTranslateYKey = ssprintf("TranslateY%04d", i);

        RageVector2 vOffset(0, 0);
        pAnimatedTexture->GetAttrValue(sTranslateXKey, vOffset.x);
        pAnimatedTexture->GetAttrValue(sTranslateYKey, vOffset.y);
        if (!IsFiniteVector(vOffset)) {
          vOffset = RageVector2(0, 0);
        }

        RageTextureID ID;
        ID.filename = ResolveAnimatedTexturePath(sTexOrIniPath, sFileName);
        ID.bStretch = true;
        ID.bHotPinkColorKey = true;
        ID.bMipMaps = true;  // use mipmaps in Models
        AnimatedTextureState state(TEXTUREMAN->LoadTexture(ID), fDelay, vOffset);
        vFrames.push_back(state);
      } else {
        break;
      }
    }
    if (vFrames.empty()) {
      LoadBlank();
    }
  } else {
    RageTextureID ID;
    ID.filename = sTexOrIniPath;
    ID.bHotPinkColorKey = true;
    ID.bStretch = true;
    ID.bMipMaps = true;  // use mipmaps in Models
    AnimatedTextureState state(
        TEXTUREMAN->LoadTexture(ID), kDefaultFrameDelaySeconds,
        RageVector2(0, 0));
    vFrames.push_back(state);
  }
}

void AnimatedTexture::Update(float fDelta) {
  if (vFrames.empty() || !std::isfinite(fDelta)) {
    return;
  }
  if (m_iCurState < 0 || m_iCurState >= static_cast<int>(vFrames.size())) {
    m_iCurState = 0;
    m_fSecsIntoFrame = 0.0f;
  }
  const double seconds =
      static_cast<double>(GetSecondsIntoAnimation()) + fDelta;
  if (!std::isfinite(seconds)) {
    m_iCurState = 0;
    m_fSecsIntoFrame = 0.0f;
    return;
  }
  SetSecondsIntoAnimation(static_cast<float>(seconds));
}

RageTexture* AnimatedTexture::GetCurrentTexture() {
  if (vFrames.empty()) {
    return nullptr;
  }
  if (m_iCurState < 0 || m_iCurState >= static_cast<int>(vFrames.size())) {
    m_iCurState = 0;
  }
  return vFrames[m_iCurState].pTexture;
}

int AnimatedTexture::GetNumStates() const { return vFrames.size(); }

void AnimatedTexture::SetState(int iState) {
  if (vFrames.empty()) {
    m_iCurState = 0;
    m_fSecsIntoFrame = 0;
    return;
  }
  rage_clamp(iState, 0, GetNumStates() - 1);
  m_iCurState = iState;
  m_fSecsIntoFrame = 0.0f;
}

float AnimatedTexture::GetAnimationLengthSeconds() const {
  double total = 0.0;
  for (const AnimatedTextureState& state : vFrames) {
    if (std::isfinite(state.fDelaySecs) && state.fDelaySecs > 0.0f) {
      total += state.fDelaySecs;
    }
  }
  return static_cast<float>(std::min(
      total, static_cast<double>(std::numeric_limits<float>::max())));
}

void AnimatedTexture::SetSecondsIntoAnimation(float fSeconds) {
  const float length = GetAnimationLengthSeconds();
  if (vFrames.empty() || !std::isfinite(fSeconds) || !std::isfinite(length) ||
      length <= 0.0f) {
    m_iCurState = 0;
    m_fSecsIntoFrame = 0;
    return;
  }
  fSeconds = std::fmod(fSeconds, length);
  if (fSeconds < 0.0f) {
    fSeconds += length;
  }

  m_iCurState = 0;
  for (unsigned i = 0; i < vFrames.size(); i++) {
    AnimatedTextureState& ats = vFrames[i];
    if (fSeconds >= ats.fDelaySecs) {
      fSeconds -= ats.fDelaySecs;
      m_iCurState = std::min<int>(i + 1, vFrames.size() - 1);
    } else {
      break;
    }
  }
  m_fSecsIntoFrame = fSeconds;  // remainder
}

float AnimatedTexture::GetSecondsIntoAnimation() const {
  if (vFrames.empty() || m_iCurState < 0 ||
      m_iCurState >= static_cast<int>(vFrames.size()) ||
      !std::isfinite(m_fSecsIntoFrame)) {
    return 0.0f;
  }
  double seconds = 0.0;

  for (unsigned i = 0; i < vFrames.size(); i++) {
    const AnimatedTextureState& ats = vFrames[i];
    if (int(i) >= m_iCurState) {
      break;
    }

    if (!std::isfinite(ats.fDelaySecs) || ats.fDelaySecs <= 0.0f) {
      return 0.0f;
    }
    seconds += ats.fDelaySecs;
  }
  seconds += m_fSecsIntoFrame;
  return std::isfinite(seconds)
             ? static_cast<float>(std::min(
                   seconds,
                   static_cast<double>(std::numeric_limits<float>::max())))
             : 0.0f;
}

void AnimatedTexture::Unload() {
  if (TEXTUREMAN != nullptr) {
    for (unsigned i = 0; i < vFrames.size(); ++i) {
    TEXTUREMAN->UnloadTexture(vFrames[i].pTexture);
    }
  }
  vFrames.clear();
  m_iCurState = 0;
  m_fSecsIntoFrame = 0;
  m_vTexOffset = RageVector2(0, 0);
  m_vTexVelocity = RageVector2(0, 0);
  m_bSphereMapped = false;
  m_BlendMode = BLEND_NORMAL;
}

RageVector2 AnimatedTexture::GetTextureTranslate() {
  const float length = GetAnimationLengthSeconds();
  float fPercentIntoAnimation = 0.0f;
  if (std::isfinite(length) && length > 0.0f) {
    fPercentIntoAnimation = GetSecondsIntoAnimation() / length;
  }
  RageVector2 v = m_vTexVelocity * fPercentIntoAnimation + m_vTexOffset;
  if (!IsFiniteVector(v)) {
    v = RageVector2(0, 0);
  }

  if (vFrames.empty()) {
    return v;
  }

  if (m_iCurState < 0 || m_iCurState >= static_cast<int>(vFrames.size())) {
    m_iCurState = 0;
  }
  v += vFrames[m_iCurState].vTranslate;

  return v;
}

#define THROW                                                               \
  RageException::Throw(                                                     \
      "Parse error in \"%s\" at line %d: \"%s\".", sPath.c_str(), iLineNum, \
      sLine.c_str())

bool msAnimation::LoadMilkshapeAsciiBones(
    std::string sAniName, std::string sPath) {
  FixSlashesInPlace(sPath);
  const std::string sDir = Dirname(sPath);

  RageFile f;
  if (!f.Open(sPath)) {
    RageException::Throw(
        "Model:: Could not open \"%s\": %s", sPath.c_str(),
        f.GetError().c_str());
  }

  std::string sLine;
  int iLineNum = 0;

  msAnimation& Animation = *this;

  bool bLoaded = false;
  int totalKeys = 0;
  while (f.GetLine(sLine) > 0) {
    iLineNum++;

    if (!strncmp(sLine.c_str(), "//", 2)) {
      continue;
    }

    // bones
    int nNumBones = 0;
    if (sscanf(sLine.c_str(), "Bones: %d", &nNumBones) != 1) {
      continue;
    }
    if (bLoaded) {
      RageException::Throw(
          "Parse error in \"%s\" at line %d: duplicate Bones section.",
          sPath.c_str(), iLineNum);
    }
    bLoaded = true;
    ValidateCount(nNumBones, kMaxBones, "bone", sPath, iLineNum, sLine);

    char szName[MS_MAX_NAME];

    Animation.Bones.resize(nNumBones);
    std::unordered_set<std::string> boneNames;

    for (int i = 0; i < nNumBones; i++) {
      msBone& Bone = Animation.Bones[i];

      // name
      if (f.GetLine(sLine) <= 0) {
        THROW;
      }
      if (sscanf(sLine.c_str(), "\"%31[^\"]\"", szName) != 1) {
        THROW;
      }
      Bone.sName = szName;
      if (!boneNames.insert(Bone.sName).second) {
        RageException::Throw(
            "Parse error in \"%s\" at line %d: duplicate bone name \"%s\".",
            sPath.c_str(), iLineNum, Bone.sName.c_str());
      }

      // parent
      if (f.GetLine(sLine) <= 0) {
        THROW;
      }
      strcpy(szName, "");
      sscanf(sLine.c_str(), "\"%31[^\"]\"", szName);

      Bone.sParentName = szName;

      // flags, position, rotation
      RageVector3 Position, Rotation;
      if (f.GetLine(sLine) <= 0) {
        THROW;
      }

      int nFlags;
      if (sscanf(
              sLine.c_str(), "%d %f %f %f %f %f %f", &nFlags, &Position[0],
              &Position[1], &Position[2], &Rotation[0], &Rotation[1],
              &Rotation[2]) != 7) {
        THROW;
      }
      if (!IsFiniteVector(Position) || !IsFiniteVector(Rotation)) {
        THROW;
      }
      Rotation = RadianToDegree(Rotation);

      Bone.nFlags = nFlags;
      memcpy(&Bone.Position, &Position, sizeof(Bone.Position));
      memcpy(&Bone.Rotation, &Rotation, sizeof(Bone.Rotation));

      // position key count
      if (f.GetLine(sLine) <= 0) {
        THROW;
      }
      int nNumPositionKeys = 0;
      if (sscanf(sLine.c_str(), "%d", &nNumPositionKeys) != 1) {
        THROW;
      }
      ValidateCount(
          nNumPositionKeys, kMaxBoneKeys, "position key", sPath, iLineNum,
          sLine);
      if (nNumPositionKeys > kMaxAnimationKeys - totalKeys) {
        RageException::Throw(
            "Parse error in \"%s\" at line %d: animation exceeds %d keys.",
            sPath.c_str(), iLineNum, kMaxAnimationKeys);
      }
      totalKeys += nNumPositionKeys;

      Bone.PositionKeys.resize(nNumPositionKeys);

      for (int j = 0; j < nNumPositionKeys; ++j) {
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }

        float fTime;
        if (sscanf(
                sLine.c_str(), "%f %f %f %f", &fTime, &Position[0],
                &Position[1], &Position[2]) != 4) {
          THROW;
        }
        ValidateKeyTime(fTime, "position key", sPath, iLineNum, sLine);
        if (!IsFiniteVector(Position)) {
          THROW;
        }

        msPositionKey key = {};
        key.fTime = fTime;
        key.Position = RageVector3(Position[0], Position[1], Position[2]);
        Bone.PositionKeys[j] = key;
      }

      // rotation key count
      if (f.GetLine(sLine) <= 0) {
        THROW;
      }
      int nNumRotationKeys = 0;
      if (sscanf(sLine.c_str(), "%d", &nNumRotationKeys) != 1) {
        THROW;
      }
      ValidateCount(
          nNumRotationKeys, kMaxBoneKeys, "rotation key", sPath, iLineNum,
          sLine);
      if (nNumRotationKeys > kMaxAnimationKeys - totalKeys) {
        RageException::Throw(
            "Parse error in \"%s\" at line %d: animation exceeds %d keys.",
            sPath.c_str(), iLineNum, kMaxAnimationKeys);
      }
      totalKeys += nNumRotationKeys;

      Bone.RotationKeys.resize(nNumRotationKeys);

      for (int j = 0; j < nNumRotationKeys; ++j) {
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }

        float fTime;
        if (sscanf(
                sLine.c_str(), "%f %f %f %f", &fTime, &Rotation[0],
                &Rotation[1], &Rotation[2]) != 4) {
          THROW;
        }
        ValidateKeyTime(fTime, "rotation key", sPath, iLineNum, sLine);
        if (!IsFiniteVector(Rotation)) {
          THROW;
        }
        Rotation = RadianToDegree(Rotation);

        msRotationKey key = {};
        key.fTime = fTime;
        Rotation = RageVector3(Rotation[0], Rotation[1], Rotation[2]);
        RageQuatFromHPR(&key.Rotation, Rotation);
        Bone.RotationKeys[j] = key;
      }
      std::sort(
          Bone.PositionKeys.begin(), Bone.PositionKeys.end(),
          [](const msPositionKey& a, const msPositionKey& b) {
            return a.fTime < b.fTime;
          });
      std::sort(
          Bone.RotationKeys.begin(), Bone.RotationKeys.end(),
          [](const msRotationKey& a, const msRotationKey& b) {
            return a.fTime < b.fTime;
          });
    }

    // Ignore "Frames:" in file.  Calculate it ourself
    Animation.nTotalFrames = 0;
    for (int i = 0; i < (int)Animation.Bones.size(); i++) {
      msBone& Bone = Animation.Bones[i];
      for (unsigned j = 0; j < Bone.PositionKeys.size(); ++j) {
        Animation.nTotalFrames = std::max(
            Animation.nTotalFrames,
            static_cast<int>(std::ceil(Bone.PositionKeys[j].fTime)));
      }
      for (unsigned j = 0; j < Bone.RotationKeys.size(); ++j) {
        Animation.nTotalFrames = std::max(
            Animation.nTotalFrames,
            static_cast<int>(std::ceil(Bone.RotationKeys[j].fTime)));
      }
    }
  }

  return !bLoaded;
}

/*
 * (c) 2003-2004 Chris Danford
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
