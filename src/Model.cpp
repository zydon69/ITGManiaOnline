#include "Model.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <utility>
#include <vector>

#include "Actor.h"
#include "ActorUtil.h"
#include "LuaBinding.h"
#include "LuaManager.h"
#include "ModelManager.h"
#include "ModelTypes.h"
#include "PrefsManager.h"
#include "RageDisplay.h"
#include "RageException.h"
#include "RageFile.h"
#include "RageLog.h"
#include "RageMath.h"
#include "RageTexture.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "StdString.h"
#include "XmlFile.h"
#include "global.h"

REGISTER_ACTOR_CLASS(Model);

static const float FRAMES_PER_SECOND = 30;
static const std::string DEFAULT_ANIMATION_NAME = "default";

namespace {
constexpr int kMaxMaterials = 4096;
constexpr float kMaxAnimationRate = 1000.0f;

bool IsFiniteVector(const RageVector4& v) {
  return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]) &&
         std::isfinite(v[3]);
}

bool IsValidMaterialIndex(const msMesh& mesh, size_t materialCount) {
  return mesh.nMaterialIndex >= 0 &&
         static_cast<size_t>(mesh.nMaterialIndex) < materialCount;
}

bool IsValidBoneIndex(int bone, size_t boneCount) {
  return bone >= 0 && static_cast<size_t>(bone) < boneCount;
}

float ClampFinite(float value, float fallback, float minValue, float maxValue) {
  if (!std::isfinite(value)) {
    return fallback;
  }
  return std::clamp(value, minValue, maxValue);
}

RageColor ClampColor(const RageVector4& value) {
  return RageColor(
      ClampFinite(value[0], 0.0f, 0.0f, 1.0f),
      ClampFinite(value[1], 0.0f, 0.0f, 1.0f),
      ClampFinite(value[2], 0.0f, 0.0f, 1.0f),
      ClampFinite(value[3], 1.0f, 0.0f, 1.0f));
}

std::string ResolveMaterialTexturePath(
    const std::string& baseDir, const std::string& textureName,
    const std::string& materialPath, int lineNum, const std::string& line) {
  std::string normalizedBase = baseDir;
  FixSlashesInPlace(normalizedBase);
  CollapsePath(normalizedBase);
  if (!normalizedBase.empty() && normalizedBase.back() != '/') {
    normalizedBase += '/';
  }

  std::string normalizedTextureName = textureName;
  FixSlashesInPlace(normalizedTextureName);
  std::vector<std::string> textureParts;
  split(normalizedTextureName, "/", textureParts, false);
  const bool absolute = !normalizedTextureName.empty() &&
                        (normalizedTextureName.front() == '/' ||
                         (normalizedTextureName.size() > 1 &&
                          normalizedTextureName[1] == ':'));
  if (absolute || std::find(textureParts.begin(), textureParts.end(), "..") !=
                      textureParts.end()) {
    RageException::Throw(
        "Parse error in \"%s\" at line %d: texture path \"%s\" escapes the "
        "model directory in \"%s\".",
        materialPath.c_str(), lineNum, textureName.c_str(), line.c_str());
  }

  std::string texturePath = normalizedBase + normalizedTextureName;
  FixSlashesInPlace(texturePath);
  CollapsePath(texturePath);
  if (!normalizedBase.empty() && !BeginsWith(texturePath, normalizedBase)) {
    RageException::Throw(
        "Parse error in \"%s\" at line %d: texture path \"%s\" escapes the "
        "model directory in \"%s\".",
        materialPath.c_str(), lineNum, textureName.c_str(), line.c_str());
  }
  return texturePath;
}

bool ResolveBindPoseBone(
    size_t index, const msAnimation& animation, std::vector<myBone_t>& bones,
    std::vector<uint8_t>& states, std::vector<bool>& validHierarchy) {
  if (states[index] == 2) {
    return validHierarchy[index];
  }
  if (states[index] == 1) {
    validHierarchy[index] = false;
    return false;
  }

  states[index] = 1;
  const int parent =
      animation.FindBoneByName(animation.Bones[index].sParentName);
  bool valid = true;
  if (parent == -1) {
    bones[index].m_Absolute = bones[index].m_Relative;
  } else if (!IsValidBoneIndex(parent, bones.size()) ||
             static_cast<size_t>(parent) == index ||
             !ResolveBindPoseBone(
                 static_cast<size_t>(parent), animation, bones, states,
                 validHierarchy)) {
    bones[index].m_Absolute = bones[index].m_Relative;
    valid = false;
  } else {
    RageMatrixMultiply(
        &bones[index].m_Absolute, &bones[parent].m_Absolute,
        &bones[index].m_Relative);
  }
  states[index] = 2;
  validHierarchy[index] = valid;
  bones[index].m_Final = bones[index].m_Absolute;
  return valid;
}

bool ResolveFinalPoseBone(
    size_t index, const msAnimation& animation,
    const std::vector<RageMatrix>& relativePose, std::vector<myBone_t>& bones,
    std::vector<uint8_t>& states, std::vector<bool>& validHierarchy) {
  if (states[index] == 2) {
    return validHierarchy[index];
  }
  if (states[index] == 1) {
    validHierarchy[index] = false;
    return false;
  }

  states[index] = 1;
  const int parent =
      animation.FindBoneByName(animation.Bones[index].sParentName);
  bool valid = true;
  if (parent == -1) {
    bones[index].m_Final = relativePose[index];
  } else if (!IsValidBoneIndex(parent, bones.size()) ||
             static_cast<size_t>(parent) == index ||
             !ResolveFinalPoseBone(
                 static_cast<size_t>(parent), animation, relativePose, bones,
                 states, validHierarchy)) {
    bones[index].m_Final = relativePose[index];
    valid = false;
  } else {
    RageMatrixMultiply(
        &bones[index].m_Final, &bones[parent].m_Final, &relativePose[index]);
  }
  states[index] = 2;
  validHierarchy[index] = valid;
  return valid;
}
}  // namespace

Model::Model() {
  m_bTextureWrapping = true;
  SetUseZBuffer(true);
  SetCullMode(CULL_BACK);
  m_pGeometry = nullptr;
  m_pCurAnimation = nullptr;
  m_animation_length_seconds = 0.0f;
  m_fCurFrame = 0.0f;
  m_fDefaultAnimationRate = 1;
  m_fCurAnimationRate = 1;
  m_bLoop = true;
  m_pTempGeometry = nullptr;
  m_bBonesPreprocessed = false;
}

Model::Model(const Model& cpy) : Actor(cpy) {
  m_pGeometry = nullptr;
  m_pCurAnimation = nullptr;
  m_animation_length_seconds = 0.0f;
  m_fCurFrame = 0.0f;
  m_fDefaultAnimationRate = cpy.m_fDefaultAnimationRate;
  m_fCurAnimationRate = cpy.m_fCurAnimationRate;
  m_bLoop = cpy.m_bLoop;
  m_pTempGeometry = nullptr;
  m_bBonesPreprocessed = false;
  m_sDefaultAnimation = cpy.m_sDefaultAnimation;

  std::string currentAnimation;
  for (const auto& animation : cpy.m_mapNameToAnimation) {
    if (&animation.second == cpy.m_pCurAnimation) {
      currentAnimation = animation.first;
      break;
    }
  }

  if (!cpy.m_sMeshesPath.empty() && !cpy.m_sMaterialsPath.empty() &&
      !cpy.m_sBonesPath.empty()) {
    LoadPieces(
        cpy.m_sMeshesPath, cpy.m_sMaterialsPath, cpy.m_sBonesPath);
    m_mapNameToAnimation = cpy.m_mapNameToAnimation;
    m_pCurAnimation = nullptr;
    if (!currentAnimation.empty()) {
      PlayAnimation(currentAnimation, cpy.m_fCurAnimationRate);
      if (m_pCurAnimation != nullptr) {
        m_fCurFrame = std::clamp(
            cpy.m_fCurFrame, 0.0f,
            static_cast<float>(m_pCurAnimation->nTotalFrames));
        SetBones(m_pCurAnimation, m_fCurFrame, m_vpBones);
        UpdateTempGeometry();
      }
    }
  }
}

Model::~Model() { Clear(); }

void Model::Clear() {
  if (m_pGeometry) {
    if (MODELMAN != nullptr) {
      MODELMAN->UnloadModel(m_pGeometry);
    }
    m_pGeometry = nullptr;
  }
  m_vpBones.clear();
  m_Materials.clear();
  m_mapNameToAnimation.clear();
  m_pCurAnimation = nullptr;
  m_fCurFrame = 0.0f;
  RecalcAnimationLengthSeconds();

  if (m_pTempGeometry) {
    if (DISPLAY != nullptr) {
      DISPLAY->DeleteCompiledGeometry(m_pTempGeometry);
    }
    m_pTempGeometry = nullptr;
  }
  m_vTempMeshes.clear();
  m_vSourceMeshes.clear();
  m_bBonesPreprocessed = false;
  m_sMeshesPath.clear();
  m_sMaterialsPath.clear();
  m_sBonesPath.clear();
}

void Model::Load(const std::string& sFile) {
  if (sFile == "") {
    return;
  }

  std::string sExt = GetExtension(sFile);
  MakeLower(sExt);
  if (sExt == "txt") {
    LoadMilkshapeAscii(sFile);
  } else {
    RageException::Throw(
        "Model::Load does not support model extension \"%s\" for \"%s\".",
        sExt.c_str(), sFile.c_str());
  }
  RecalcAnimationLengthSeconds();
}

#define THROW                                                               \
  RageException::Throw(                                                     \
      "Parse error in \"%s\" at line %d: \"%s\".", sPath.c_str(), iLineNum, \
      sLine.c_str())

// TODO: Move MS3D loading into its own class. - Colby
void Model::LoadMilkshapeAscii(const std::string& sPath) {
  LoadPieces(sPath, sPath, sPath);
}

void Model::LoadPieces(
    const std::string& sMeshesPath, const std::string& sMaterialsPath,
    const std::string& sBonesPath) {
  if (MODELMAN == nullptr || DISPLAY == nullptr) {
    RageException::Throw(
        "Model::LoadPieces cannot load \"%s\" without model/display managers.",
        sMeshesPath.c_str());
  }
  if (sMeshesPath.empty() || sMaterialsPath.empty() || sBonesPath.empty()) {
    RageException::Throw(
        "Model::LoadPieces requires meshes, materials and bones paths.");
  }
  Model staged;
  staged.m_sDefaultAnimation = m_sDefaultAnimation;
  staged.m_fDefaultAnimationRate = m_fDefaultAnimationRate;
  staged.m_bLoop = m_bLoop;
  staged.LoadPiecesInPlace(sMeshesPath, sMaterialsPath, sBonesPath);
  SwapLoadedState(staged);
}

void Model::LoadPiecesInPlace(
    const std::string& sMeshesPath, const std::string& sMaterialsPath,
    const std::string& sBonesPath) {
  Clear();

  // TRICKY: Load materials before geometry so we can figure out whether the
  // materials require normals.
  LoadMaterialsFromMilkshapeAscii(sMaterialsPath);

  ASSERT(m_pGeometry == nullptr);
  m_pGeometry =
      MODELMAN->LoadMilkshapeAscii(sMeshesPath, this->MaterialsNeedNormals());
  if (m_pGeometry == nullptr) {
    RageException::Throw(
        "Model::LoadPieces failed to load geometry \"%s\".",
        sMeshesPath.c_str());
  }

  // Validate material indices.
  for (unsigned i = 0; i < m_pGeometry->m_Meshes.size(); ++i) {
    const msMesh* pMesh = &m_pGeometry->m_Meshes[i];

    if (pMesh->nMaterialIndex != -1 &&
        !IsValidMaterialIndex(*pMesh, m_Materials.size())) {
      RageException::Throw(
          "Model \"%s\" mesh \"%s\" references material index %i, but there "
          "are only %i materials.",
          sMeshesPath.c_str(), pMesh->sName.c_str(), pMesh->nMaterialIndex,
          (int)m_Materials.size());
    }
  }

  // Setup temp vertices (if necessary)
  if (m_pGeometry->HasAnyPerVertexBones()) {
    m_vSourceMeshes = m_pGeometry->m_Meshes;
    m_vTempMeshes = m_vSourceMeshes;
  }

  if (LoadMilkshapeAsciiBones(DEFAULT_ANIMATION_NAME, sBonesPath)) {
    PlayAnimation(DEFAULT_ANIMATION_NAME);
  }

  if (!m_vTempMeshes.empty()) {
    m_pTempGeometry = DISPLAY->CreateCompiledGeometry();
    if (m_pTempGeometry == nullptr) {
      RageException::Throw(
          "Model \"%s\" could not create temporary compiled geometry.",
          sMeshesPath.c_str());
    }
    m_pTempGeometry->Set(m_vTempMeshes, this->MaterialsNeedNormals());
  }
  m_sMeshesPath = sMeshesPath;
  m_sMaterialsPath = sMaterialsPath;
  m_sBonesPath = sBonesPath;
  RecalcAnimationLengthSeconds();
}

void Model::SwapLoadedState(Model& other) noexcept {
  using std::swap;
  swap(m_pGeometry, other.m_pGeometry);
  swap(m_animation_length_seconds, other.m_animation_length_seconds);
  swap(m_Materials, other.m_Materials);
  swap(m_mapNameToAnimation, other.m_mapNameToAnimation);
  swap(m_pCurAnimation, other.m_pCurAnimation);
  swap(m_vpBones, other.m_vpBones);
  swap(m_pTempGeometry, other.m_pTempGeometry);
  swap(m_vSourceMeshes, other.m_vSourceMeshes);
  swap(m_vTempMeshes, other.m_vTempMeshes);
  swap(m_bBonesPreprocessed, other.m_bBonesPreprocessed);
  swap(m_fCurFrame, other.m_fCurFrame);
  swap(m_sDefaultAnimation, other.m_sDefaultAnimation);
  swap(m_fDefaultAnimationRate, other.m_fDefaultAnimationRate);
  swap(m_fCurAnimationRate, other.m_fCurAnimationRate);
  swap(m_bLoop, other.m_bLoop);
  swap(m_sMeshesPath, other.m_sMeshesPath);
  swap(m_sMaterialsPath, other.m_sMaterialsPath);
  swap(m_sBonesPath, other.m_sBonesPath);
}

void Model::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    Actor::LoadFromNode(pNode);
    return;
  }
  std::string s1, s2, s3;
  ActorUtil::GetAttrPath(pNode, "Meshes", s1);
  ActorUtil::GetAttrPath(pNode, "Materials", s2);
  ActorUtil::GetAttrPath(pNode, "Bones", s3);
  if (!s1.empty() || !s2.empty() || !s3.empty()) {
    if (s1.empty() || s2.empty() || s3.empty()) {
      RageException::Throw(
          "Model actor requires Meshes, Materials and Bones when any model "
          "path is specified.");
    }
    LoadPieces(s1, s2, s3);
  }

  Actor::LoadFromNode(pNode);
  RecalcAnimationLengthSeconds();
}

void Model::LoadMaterialsFromMilkshapeAscii(const std::string& _sPath) {
  std::string sPath = _sPath;

  FixSlashesInPlace(sPath);
  const std::string sDir = Dirname(sPath);

  RageFile f;
  if (!f.Open(sPath)) {
    RageException::Throw(
        "Model::LoadMilkshapeAscii Could not open \"%s\": %s", sPath.c_str(),
        f.GetError().c_str());
  }

  std::string sLine;
  int iLineNum = 0;

  while (f.GetLine(sLine) > 0) {
    iLineNum++;

    if (!strncmp(sLine.c_str(), "//", 2)) {
      continue;
    }

    int nFrame;
    if (sscanf(sLine.c_str(), "Frames: %d", &nFrame) == 1) {
      // ignore
      // m_pModel->nTotalFrames = nFrame;
    }
    if (sscanf(sLine.c_str(), "Frame: %d", &nFrame) == 1) {
      // ignore
      // m_pModel->nFrame = nFrame;
    }

    // materials
    int nNumMaterials = 0;
    if (sscanf(sLine.c_str(), "Materials: %d", &nNumMaterials) == 1) {
      if (nNumMaterials < 0 || nNumMaterials > kMaxMaterials) {
        RageException::Throw(
            "Parse error in \"%s\" at line %d: invalid material count %d.",
            sPath.c_str(), iLineNum, nNumMaterials);
      }
      m_Materials.resize(nNumMaterials);

      char szName[256];

      for (int i = 0; i < nNumMaterials; i++) {
        msMaterial& Material = m_Materials[i];

        // name
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }
        if (sscanf(sLine.c_str(), "\"%255[^\"]\"", szName) != 1) {
          THROW;
        }
        Material.sName = szName;

        // ambient
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }
        RageVector4 Ambient;
        if (sscanf(
                sLine.c_str(), "%f %f %f %f", &Ambient[0], &Ambient[1],
                &Ambient[2], &Ambient[3]) != 4) {
          THROW;
        }
        if (!IsFiniteVector(Ambient)) {
          THROW;
        }
        Material.Ambient = ClampColor(Ambient);

        // diffuse
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }
        RageVector4 Diffuse;
        if (sscanf(
                sLine.c_str(), "%f %f %f %f", &Diffuse[0], &Diffuse[1],
                &Diffuse[2], &Diffuse[3]) != 4) {
          THROW;
        }
        if (!IsFiniteVector(Diffuse)) {
          THROW;
        }
        Material.Diffuse = ClampColor(Diffuse);

        // specular
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }
        RageVector4 Specular;
        if (sscanf(
                sLine.c_str(), "%f %f %f %f", &Specular[0], &Specular[1],
                &Specular[2], &Specular[3]) != 4) {
          THROW;
        }
        if (!IsFiniteVector(Specular)) {
          THROW;
        }
        Material.Specular = ClampColor(Specular);

        // emissive
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }
        RageVector4 Emissive;
        if (sscanf(
                sLine.c_str(), "%f %f %f %f", &Emissive[0], &Emissive[1],
                &Emissive[2], &Emissive[3]) != 4) {
          THROW;
        }
        if (!IsFiniteVector(Emissive)) {
          THROW;
        }
        Material.Emissive = ClampColor(Emissive);

        // shininess
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }
        float fShininess;
        if (!StringConversion::FromString(sLine, fShininess)) {
          THROW;
        }
        if (!std::isfinite(fShininess) || fShininess < 0.0f) {
          THROW;
        }
        Material.fShininess = std::min(fShininess, 128.0f);

        // transparency
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }
        float fTransparency;
        if (!StringConversion::FromString(sLine, fTransparency)) {
          THROW;
        }
        if (!std::isfinite(fTransparency)) {
          THROW;
        }
        Material.fTransparency = std::clamp(fTransparency, 0.0f, 1.0f);

        // diffuse texture
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }
        strcpy(szName, "");
        sscanf(sLine.c_str(), "\"%255[^\"]\"", szName);
        std::string sDiffuseTexture = szName;

        if (sDiffuseTexture == "") {
          Material.diffuse.LoadBlank();
        } else {
          std::string sTexturePath = ResolveMaterialTexturePath(
              sDir, sDiffuseTexture, sPath, iLineNum, sLine);
          if (!IsAFile(sTexturePath)) {
            if (LOG != nullptr) {
              LOG->Warn(
                  "\"%s\" references missing texture "
                  "\"%s\"; using blank diffuse texture.",
                  sPath.c_str(), sTexturePath.c_str());
            }
            Material.diffuse.LoadBlank();
          } else {
            Material.diffuse.Load(sTexturePath);
          }
        }

        // alpha texture
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }
        strcpy(szName, "");
        sscanf(sLine.c_str(), "\"%255[^\"]\"", szName);
        std::string sAlphaTexture = szName;

        if (sAlphaTexture == "") {
          Material.alpha.LoadBlank();
        } else {
          std::string sTexturePath = ResolveMaterialTexturePath(
              sDir, sAlphaTexture, sPath, iLineNum, sLine);
          if (!IsAFile(sTexturePath)) {
            if (LOG != nullptr) {
              LOG->Warn(
                  "\"%s\" references missing texture "
                  "\"%s\"; using blank alpha texture.",
                  sPath.c_str(), sTexturePath.c_str());
            }
            Material.alpha.LoadBlank();
          } else {
            Material.alpha.Load(sTexturePath);
          }
        }
      }
    }
  }
}

bool Model::LoadMilkshapeAsciiBones(
    const std::string& sAniName, const std::string& sPath) {
  if (sAniName.empty() || sPath.empty()) {
    return false;
  }
  msAnimation animation;
  if (animation.LoadMilkshapeAsciiBones(sAniName, sPath)) {
    return false;
  }

  const bool replacingCurrent =
      m_pCurAnimation != nullptr &&
      m_mapNameToAnimation.find(sAniName) != m_mapNameToAnimation.end() &&
      &m_mapNameToAnimation.find(sAniName)->second == m_pCurAnimation;
  m_mapNameToAnimation[sAniName] = std::move(animation);
  if (replacingCurrent) {
    m_pCurAnimation = &m_mapNameToAnimation.find(sAniName)->second;
  }

  return true;
}

bool Model::EarlyAbortDraw() const {
  return m_pGeometry == nullptr || m_pGeometry->m_Meshes.empty();
}

void Model::DrawCelShaded() {
  if (DISPLAY == nullptr) {
    return;
  }
  const bool originalZWrite = m_bZWrite;
  const CullMode originalCullMode = m_CullMode;

  // First pass: shell. We only want the backfaces for this.
  DISPLAY->SetCelShaded(1);
  DISPLAY->SetCullMode(CULL_FRONT);
  this->SetZWrite(false);
  this->Draw();

  // Second pass: cel shading
  DISPLAY->SetCelShaded(2);
  DISPLAY->SetCullMode(CULL_BACK);
  this->SetZWrite(true);
  this->Draw();

  DISPLAY->SetCelShaded(0);
  SetZWrite(originalZWrite);
  SetCullMode(originalCullMode);
  DISPLAY->SetZWrite(originalZWrite);
  DISPLAY->SetCullMode(originalCullMode);
}

void Model::DrawPrimitives() {
  if (DISPLAY == nullptr || PREFSMAN == nullptr || m_pTempState == nullptr ||
      m_pGeometry == nullptr) {
    return;
  }
  Actor::SetGlobalRenderStates();  // set Actor-specified render states

  // Don't if we're fully transparent
  if (m_pTempState->diffuse[0].a < 0.001f && m_pTempState->glow.a < 0.001f) {
    return;
  }

  DISPLAY->Scale(1, -1, 1);  // flip Y so positive is up

  //////////////////////
  // render the diffuse pass
  //////////////////////
  if (m_pTempState->diffuse[0].a > 0) {
    DISPLAY->SetTextureMode(TextureUnit_1, TextureMode_Modulate);

    for (unsigned i = 0; i < m_pGeometry->m_Meshes.size(); ++i) {
      const msMesh* pMesh = &m_pGeometry->m_Meshes[i];

      if (pMesh->nMaterialIndex != -1)  // has a material
      {
        // apply material
        if (!IsValidMaterialIndex(*pMesh, m_Materials.size())) {
          continue;
        }
        msMaterial& mat = m_Materials[pMesh->nMaterialIndex];

        RageColor Emissive = mat.Emissive;
        RageColor Ambient = mat.Ambient;
        RageColor Diffuse = mat.Diffuse;

        Emissive *= m_pTempState->diffuse[0];
        Ambient *= m_pTempState->diffuse[0];
        Diffuse *= m_pTempState->diffuse[0];

        DISPLAY->SetMaterial(
            Emissive, Ambient, Diffuse, mat.Specular, mat.fShininess);

        RageVector2 vTexTranslate = mat.diffuse.GetTextureTranslate();
        if (vTexTranslate.x != 0 || vTexTranslate.y != 0) {
          DISPLAY->TexturePushMatrix();
          DISPLAY->TextureTranslate(vTexTranslate.x, vTexTranslate.y);
        }

        /* There's some common code that could be folded out here, but
         * it seems clearer to keep it separate. */
        bool bUseMultitexture = PREFSMAN->m_bAllowMultitexture &&
                                DISPLAY->GetNumTextureUnits() >= 2;
        if (bUseMultitexture) {
          // render the diffuse texture with texture unit 1
          DISPLAY->SetTexture(
              TextureUnit_1,
              mat.diffuse.GetCurrentTexture()
                  ? mat.diffuse.GetCurrentTexture()->GetTexHandle()
                  : 0);
          Actor::SetTextureRenderStates();  // set Actor-specified render states
          DISPLAY->SetSphereEnvironmentMapping(
              TextureUnit_1, mat.diffuse.m_bSphereMapped);

          // render the additive texture with texture unit 2
          if (mat.alpha.GetCurrentTexture()) {
            DISPLAY->SetTexture(
                TextureUnit_2,
                mat.alpha.GetCurrentTexture()
                    ? mat.alpha.GetCurrentTexture()->GetTexHandle()
                    : 0);
            Actor::SetTextureRenderStates();  // set Actor-specified render
                                              // states
            DISPLAY->SetSphereEnvironmentMapping(
                TextureUnit_2, mat.alpha.m_bSphereMapped);
            DISPLAY->SetTextureMode(TextureUnit_2, TextureMode_Add);
            DISPLAY->SetTextureFiltering(TextureUnit_2, true);
          } else {
            DISPLAY->SetTexture(TextureUnit_2, 0);

            // set current texture back to 0 or else texture
            // transform applied above  isn't used. Why?!?
            DISPLAY->SetTexture(
                TextureUnit_1,
                mat.diffuse.GetCurrentTexture()
                    ? mat.diffuse.GetCurrentTexture()->GetTexHandle()
                    : 0);
          }

          // go
          DrawMesh(i);

          // Turn off environment mapping on tex unit 0.
          DISPLAY->SetSphereEnvironmentMapping(TextureUnit_1, false);
          DISPLAY->SetSphereEnvironmentMapping(TextureUnit_2, false);
          DISPLAY->SetTexture(TextureUnit_2, 0);
          DISPLAY->SetTextureMode(TextureUnit_2, TextureMode_Modulate);
        } else {
          // render the diffuse texture
          DISPLAY->SetTexture(
              TextureUnit_1,
              mat.diffuse.GetCurrentTexture()
                  ? mat.diffuse.GetCurrentTexture()->GetTexHandle()
                  : 0);
          Actor::SetTextureRenderStates();  // set Actor-specified render states
          DISPLAY->SetSphereEnvironmentMapping(
              TextureUnit_1, mat.diffuse.m_bSphereMapped);
          DrawMesh(i);

          // render the additive texture
          if (mat.alpha.GetCurrentTexture()) {
            DISPLAY->SetTexture(
                TextureUnit_1,
                mat.alpha.GetCurrentTexture()
                    ? mat.alpha.GetCurrentTexture()->GetTexHandle()
                    : 0);
            Actor::SetTextureRenderStates();  // set Actor-specified render
                                              // states

            DISPLAY->SetSphereEnvironmentMapping(
                TextureUnit_1, mat.alpha.m_bSphereMapped);
            // UGLY: This overrides the Actor's BlendMode.
            DISPLAY->SetBlendMode(BLEND_ADD);
            DISPLAY->SetTextureFiltering(TextureUnit_1, true);
            DrawMesh(i);
          }
        }

        if (vTexTranslate.x != 0 || vTexTranslate.y != 0) {
          DISPLAY->TexturePopMatrix();
        }
      } else {
        static const RageColor emissive(0, 0, 0, 0);
        static const RageColor ambient(0.2f, 0.2f, 0.2f, 1);
        static const RageColor diffuse(0.7f, 0.7f, 0.7f, 1);
        static const RageColor specular(0.2f, 0.2f, 0.2f, 1);
        static const float shininess = 1;
        DISPLAY->SetMaterial(emissive, ambient, diffuse, specular, shininess);
        DISPLAY->ClearAllTextures();
        DISPLAY->SetSphereEnvironmentMapping(TextureUnit_1, false);
        DrawMesh(i);
      }

      DISPLAY->SetSphereEnvironmentMapping(TextureUnit_1, false);
      DISPLAY->SetBlendMode(BLEND_NORMAL);
    }
  }

  // render the glow pass
  if (m_pTempState->glow.a > 0.0001f) {
    DISPLAY->SetTextureMode(TextureUnit_1, TextureMode_Glow);

    for (unsigned i = 0; i < m_pGeometry->m_Meshes.size(); ++i) {
      const msMesh* pMesh = &m_pGeometry->m_Meshes[i];

      // apply material
      RageColor emissive = RageColor(0, 0, 0, 0);
      RageColor ambient = RageColor(0, 0, 0, 0);
      RageColor diffuse = m_pTempState->glow;
      RageColor specular = RageColor(0, 0, 0, 0);
      float shininess = 1;

      DISPLAY->SetMaterial(emissive, ambient, diffuse, specular, shininess);
      DISPLAY->ClearAllTextures();

      if (pMesh->nMaterialIndex != -1 &&
          IsValidMaterialIndex(*pMesh, m_Materials.size())) {
        msMaterial& mat = m_Materials[pMesh->nMaterialIndex];
        DISPLAY->SetTexture(
            TextureUnit_1, mat.diffuse.GetCurrentTexture()
                               ? mat.diffuse.GetCurrentTexture()->GetTexHandle()
                               : 0);
        Actor::SetTextureRenderStates();  // set Actor-specified render states
      } else {
        // hey why is this otherwise empty else block here? -aj
      }

      DrawMesh(i);
    }
  }
  DISPLAY->SetTextureMode(TextureUnit_1, TextureMode_Modulate);
  DISPLAY->SetSphereEnvironmentMapping(TextureUnit_1, false);
  DISPLAY->SetSphereEnvironmentMapping(TextureUnit_2, false);
  DISPLAY->SetTexture(TextureUnit_2, 0);
  DISPLAY->SetBlendMode(BLEND_NORMAL);
}

void Model::DrawMesh(int i) const {
  if (DISPLAY == nullptr || m_pGeometry == nullptr || i < 0 ||
      static_cast<size_t>(i) >= m_pGeometry->m_Meshes.size()) {
    return;
  }
  const msMesh* pMesh = &m_pGeometry->m_Meshes[i];

  // apply mesh-specific bone (if any)
  const bool hasValidMeshBone =
      IsValidBoneIndex(pMesh->m_iBoneIndex, m_vpBones.size());
  if (pMesh->m_iBoneIndex != -1 && hasValidMeshBone) {
    DISPLAY->PushMatrix();

    const RageMatrix& mat = m_vpBones[pMesh->m_iBoneIndex].m_Final;
    DISPLAY->PreMultMatrix(mat);
  }

  // Draw it
  const RageCompiledGeometry* TempGeometry =
      m_pTempGeometry ? m_pTempGeometry : m_pGeometry->m_pCompiledGeometry;
  if (TempGeometry == nullptr) {
    if (pMesh->m_iBoneIndex != -1 && hasValidMeshBone) {
      DISPLAY->PopMatrix();
    }
    return;
  }
  DISPLAY->DrawCompiledGeometry(TempGeometry, i, m_pGeometry->m_Meshes);

  if (pMesh->m_iBoneIndex != -1 && hasValidMeshBone) {
    DISPLAY->PopMatrix();
  }
}

void Model::SetDefaultAnimation(std::string sAnimation, float fPlayRate) {
  m_sDefaultAnimation = sAnimation;
  m_fDefaultAnimationRate = std::isfinite(fPlayRate) && fPlayRate > 0.0f
                                ? std::min(fPlayRate, kMaxAnimationRate)
                                : 1.0f;
}

void Model::SetRate(float fRate) {
  m_fCurAnimationRate = std::isfinite(fRate)
                            ? std::clamp(
                                  fRate, -kMaxAnimationRate, kMaxAnimationRate)
                            : 1.0f;
}

void Model::PlayAnimation(const std::string& sAniName, float fPlayRate) {
  if (m_mapNameToAnimation.find(sAniName) == m_mapNameToAnimation.end()) {
    return;
  }

  const msAnimation* pNewAnimation = &m_mapNameToAnimation.find(sAniName)->second;

  m_fCurFrame = 0;
  SetRate(fPlayRate);

  if (m_pCurAnimation != pNewAnimation) {
    m_pCurAnimation = pNewAnimation;
    m_vpBones.resize(m_pCurAnimation->Bones.size());

    for (size_t i = 0; i < m_pCurAnimation->Bones.size(); ++i) {
      const msBone& bone = m_pCurAnimation->Bones[i];
      RageMatrixAngles(&m_vpBones[i].m_Relative, bone.Rotation);
      m_vpBones[i].m_Relative.m[3][0] = bone.Position[0];
      m_vpBones[i].m_Relative.m[3][1] = bone.Position[1];
      m_vpBones[i].m_Relative.m[3][2] = bone.Position[2];
    }
    std::vector<uint8_t> states(m_vpBones.size(), 0);
    std::vector<bool> validHierarchy(m_vpBones.size(), true);
    for (size_t i = 0; i < m_vpBones.size(); ++i) {
      ResolveBindPoseBone(
          i, *m_pCurAnimation, m_vpBones, states, validHierarchy);
    }
  }

  // Convert the private bind-pose copy once.  Never mutate ModelManager's
  // shared geometry, and never apply this subtraction again on animation
  // switches.
  if (!m_bBonesPreprocessed && !m_vSourceMeshes.empty()) {
    for (unsigned i = 0; i < m_vSourceMeshes.size(); ++i) {
      msMesh* pMesh = &m_vSourceMeshes[i];
      std::vector<RageModelVertex>& Vertices = pMesh->Vertices;
      for (unsigned j = 0; j < Vertices.size(); j++) {
        RageVector3& pos = Vertices[j].p;
        int8_t bone = Vertices[j].bone;
        if (bone != -1 && IsValidBoneIndex(bone, m_vpBones.size())) {
          pos[0] -= m_vpBones[bone].m_Absolute.m[3][0];
          pos[1] -= m_vpBones[bone].m_Absolute.m[3][1];
          pos[2] -= m_vpBones[bone].m_Absolute.m[3][2];

          RageVector3 vTmp;
          RageMatrix inverse;
          RageMatrixTranspose(
              &inverse,
              &m_vpBones[bone]
                   .m_Absolute);  // transpose = inverse for rotation matrices
          RageVec3TransformNormal(&vTmp, &pos, &inverse);
          pos = vTmp;
        } else if (bone != -1) {
          Vertices[j].bone = -1;
        }
      }
    }
    m_bBonesPreprocessed = true;
    m_vTempMeshes = m_vSourceMeshes;
  }

  // Set up m_vpBones, just in case we're drawn without being Update()d.
  SetBones(m_pCurAnimation, m_fCurFrame, m_vpBones);
  UpdateTempGeometry();
}

void Model::SetPosition(float fSeconds) {
  if (m_pCurAnimation == nullptr || m_pCurAnimation->nTotalFrames <= 0 ||
      !std::isfinite(fSeconds)) {
    return;
  }
  const double frame = static_cast<double>(FRAMES_PER_SECOND) * fSeconds;
  m_fCurFrame = static_cast<float>(std::clamp(
      frame, 0.0, static_cast<double>(m_pCurAnimation->nTotalFrames)));
  SetBones(m_pCurAnimation, m_fCurFrame, m_vpBones);
  UpdateTempGeometry();
}

void Model::AdvanceFrame(float fDeltaTime) {
  if (m_pGeometry == nullptr || m_pGeometry->m_Meshes.empty() ||
      !m_pCurAnimation || m_pCurAnimation->nTotalFrames <= 0 ||
      !std::isfinite(fDeltaTime) || !std::isfinite(m_fCurAnimationRate)) {
    return;  // bail early
  }

  // LOG->Trace( "m_fCurFrame = %f", m_fCurFrame );

  const double nextFrame =
      static_cast<double>(m_fCurFrame) + FRAMES_PER_SECOND *
          static_cast<double>(fDeltaTime) * m_fCurAnimationRate;
  if (!std::isfinite(nextFrame)) {
    m_fCurFrame = 0.0f;
  } else if (
      std::abs(nextFrame) >
      static_cast<double>(std::numeric_limits<float>::max())) {
    if (m_bLoop && m_sDefaultAnimation.empty()) {
      double wrapped = std::fmod(
          nextFrame, static_cast<double>(m_pCurAnimation->nTotalFrames));
      if (wrapped < 0.0) {
        wrapped += m_pCurAnimation->nTotalFrames;
      }
      m_fCurFrame = static_cast<float>(wrapped);
    } else {
      m_fCurFrame = nextFrame < 0.0f
                        ? -static_cast<float>(m_pCurAnimation->nTotalFrames)
                        : static_cast<float>(m_pCurAnimation->nTotalFrames);
    }
  } else {
    m_fCurFrame = static_cast<float>(nextFrame);
  }
  if (m_fCurFrame < 0 || m_fCurFrame >= m_pCurAnimation->nTotalFrames) {
    if (m_sDefaultAnimation != "") {
      this->PlayAnimation(m_sDefaultAnimation, m_fDefaultAnimationRate);
      /* XXX: add to m_fCurFrame the wrapover from the previous
       * m_fCurFrame-m_pCurAnimation->nTotalFrames, so it doesn't skip */
    } else if (m_bLoop) {
      wrap(m_fCurFrame, (float)m_pCurAnimation->nTotalFrames);
    } else {
      m_fCurFrame = std::clamp(
          m_fCurFrame, (float)0, (float)m_pCurAnimation->nTotalFrames);
    }
  }

  SetBones(m_pCurAnimation, m_fCurFrame, m_vpBones);
  UpdateTempGeometry();
}

void Model::SetBones(
    const msAnimation* pAnimation, float fFrame,
    std::vector<myBone_t>& vpBones) {
  if (pAnimation == nullptr || vpBones.size() < pAnimation->Bones.size() ||
      !std::isfinite(fFrame)) {
    return;
  }
  std::vector<RageMatrix> relativePose(pAnimation->Bones.size());
  for (size_t i = 0; i < pAnimation->Bones.size(); ++i) {
    const msBone* pBone = &pAnimation->Bones[i];

    // search for the adjacent position keys
    const msPositionKey *pLastPositionKey = nullptr,
                        *pThisPositionKey = nullptr;
    for (size_t j = 0; j < pBone->PositionKeys.size(); ++j) {
      const msPositionKey* pPositionKey = &pBone->PositionKeys[j];
      if (pPositionKey->fTime >= fFrame) {
        pThisPositionKey = pPositionKey;
        break;
      }
      pLastPositionKey = pPositionKey;
    }

    RageVector3 vPos(0, 0, 0);
    if (pLastPositionKey != nullptr && pThisPositionKey != nullptr) {
      const float denom = pThisPositionKey->fTime - pLastPositionKey->fTime;
      const float s = denom != 0.0f
                          ? std::clamp(
                                (fFrame - pLastPositionKey->fTime) / denom,
                                0.0f, 1.0f)
                          : 0.0f;
      vPos = pLastPositionKey->Position +
             (pThisPositionKey->Position - pLastPositionKey->Position) * s;
    } else if (pLastPositionKey == nullptr && pThisPositionKey != nullptr) {
      vPos = pThisPositionKey->Position;
    } else if (pThisPositionKey == nullptr && pLastPositionKey != nullptr) {
      vPos = pLastPositionKey->Position;
    }

    // search for the adjacent rotation keys
    const msRotationKey *pLastRotationKey = nullptr,
                        *pThisRotationKey = nullptr;
    for (size_t j = 0; j < pBone->RotationKeys.size(); ++j) {
      const msRotationKey* pRotationKey = &pBone->RotationKeys[j];
      if (pRotationKey->fTime >= fFrame) {
        pThisRotationKey = pRotationKey;
        break;
      }
      pLastRotationKey = pRotationKey;
    }

    RageVector4 vRot(0, 0, 0, 1);
    if (pLastRotationKey != nullptr && pThisRotationKey != nullptr) {
      const float denom = pThisRotationKey->fTime - pLastRotationKey->fTime;
      const float s = denom != 0.0f
                          ? std::clamp(
                                (fFrame - pLastRotationKey->fTime) / denom,
                                0.0f, 1.0f)
                          : 0.0f;
      RageQuatSlerp(
          &vRot, pLastRotationKey->Rotation, pThisRotationKey->Rotation, s);
    } else if (pLastRotationKey == nullptr && pThisRotationKey != nullptr) {
      vRot = pThisRotationKey->Rotation;
    } else if (pThisRotationKey == nullptr && pLastRotationKey != nullptr) {
      vRot = pLastRotationKey->Rotation;
    }

    RageMatrix m;
    RageMatrixIdentity(&m);
    RageMatrixFromQuat(&m, vRot);
    m.m[3][0] = vPos[0];
    m.m[3][1] = vPos[1];
    m.m[3][2] = vPos[2];

    RageMatrixMultiply(&relativePose[i], &vpBones[i].m_Relative, &m);
  }

  std::vector<uint8_t> states(vpBones.size(), 0);
  std::vector<bool> validHierarchy(vpBones.size(), true);
  for (size_t i = 0; i < vpBones.size(); ++i) {
    ResolveFinalPoseBone(
        i, *pAnimation, relativePose, vpBones, states, validHierarchy);
  }
}

void Model::UpdateTempGeometry() {
  if (m_pGeometry == nullptr || m_pTempGeometry == nullptr) {
    return;
  }
  if (m_vSourceMeshes.size() != m_pGeometry->m_Meshes.size() ||
      m_vTempMeshes.size() != m_vSourceMeshes.size()) {
    return;
  }
  for (size_t i = 0; i < m_vSourceMeshes.size(); ++i) {
    if (m_vTempMeshes[i].Vertices.size() !=
        m_vSourceMeshes[i].Vertices.size()) {
      return;
    }
  }

  for (unsigned i = 0; i < m_pGeometry->m_Meshes.size(); ++i) {
    const msMesh& origMesh = m_vSourceMeshes[i];
    msMesh& tempMesh = m_vTempMeshes[i];
    const std::vector<RageModelVertex>& origVertices = origMesh.Vertices;
    std::vector<RageModelVertex>& tempVertices = tempMesh.Vertices;
    for (unsigned j = 0; j < origVertices.size(); j++) {
      RageVector3& tempPos = tempVertices[j].p;
      RageVector3& tempNormal = tempVertices[j].n;
      const RageVector3& originalPos = origVertices[j].p;
      const RageVector3& originalNormal = origVertices[j].n;
      int8_t bone = origVertices[j].bone;

      if (bone == -1) {
        tempNormal = originalNormal;
        tempPos = originalPos;
      } else if (IsValidBoneIndex(bone, m_vpBones.size())) {
        RageVec3TransformNormal(
            &tempNormal, &originalNormal, &m_vpBones[bone].m_Final);
        RageVec3TransformCoord(
            &tempPos, &originalPos, &m_vpBones[bone].m_Final);
      } else {
        tempNormal = originalNormal;
        tempPos = originalPos;
      }
    }
  }

  // send the new vertices to the graphics card
  m_pTempGeometry->Change(m_vTempMeshes);
}

void Model::Update(float fDelta) {
  if (!std::isfinite(fDelta)) {
    return;
  }
  Actor::Update(fDelta);
  AdvanceFrame(fDelta);

  for (unsigned i = 0; i < m_Materials.size(); ++i) {
    m_Materials[i].diffuse.Update(fDelta);
    m_Materials[i].alpha.Update(fDelta);
  }
}

int Model::GetNumStates() const {
  int iMaxStates = 0;
  for (const msMaterial& m : m_Materials) {
    iMaxStates = std::max(iMaxStates, m.diffuse.GetNumStates());
    iMaxStates = std::max(iMaxStates, m.alpha.GetNumStates());
  }
  return iMaxStates;
}

void Model::SetState(int iNewState) {
  for (msMaterial& m : m_Materials) {
    m.diffuse.SetState(iNewState);
    m.alpha.SetState(iNewState);
  }
}

void Model::RecalcAnimationLengthSeconds() {
  m_animation_length_seconds = 0;
  for (const msMaterial& m : m_Materials) {
    m_animation_length_seconds = std::max(
        m_animation_length_seconds, m.diffuse.GetAnimationLengthSeconds());
    m_animation_length_seconds =
        std::max(m_animation_length_seconds, m.alpha.GetAnimationLengthSeconds());
  }
  for (const auto& animation : m_mapNameToAnimation) {
    if (animation.second.nTotalFrames > 0) {
      m_animation_length_seconds = std::max(
          m_animation_length_seconds,
          animation.second.nTotalFrames / FRAMES_PER_SECOND);
    }
  }
}

void Model::SetSecondsIntoAnimation(float fSeconds) {
  if (!std::isfinite(fSeconds)) {
    return;
  }
  for (msMaterial& m : m_Materials) {
    m.diffuse.SetSecondsIntoAnimation(fSeconds);
    m.alpha.SetSecondsIntoAnimation(fSeconds);
  }
  SetPosition(fSeconds);
}

bool Model::MaterialsNeedNormals() const {
  return std::any_of(
      m_Materials.begin(), m_Materials.end(),
      [](const msMaterial& m) { return m.NeedsNormals(); });
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the Model. */
class LunaModel : public Luna<Model> {
 public:
  static int position(T* p, lua_State* L) {
    p->SetPosition(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int playanimation(T* p, lua_State* L) {
    p->PlayAnimation(SArg(1), FArg(2));
    COMMON_RETURN_SELF;
  }
  static int SetDefaultAnimation(T* p, lua_State* L) {
    p->SetDefaultAnimation(SArg(1), FArg(2));
    COMMON_RETURN_SELF;
  }
  static int GetDefaultAnimation(T* p, lua_State* L) {
    lua_pushstring(L, p->GetDefaultAnimation().c_str());
    return 1;
  }
  static int loop(T* p, lua_State* L) {
    p->SetLoop(BArg(1));
    COMMON_RETURN_SELF;
  }
  static int rate(T* p, lua_State* L) {
    p->SetRate(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int GetNumStates(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetNumStates());
    return 1;
  }
  // static int CelShading( T* p, lua_State *L )		{
  // p->SetCelShading(BArg(1)); COMMON_RETURN_SELF; }

  LunaModel() {
    ADD_METHOD(position);
    ADD_METHOD(playanimation);
    ADD_METHOD(SetDefaultAnimation);
    ADD_METHOD(GetDefaultAnimation);
    ADD_METHOD(loop);
    ADD_METHOD(rate);
    // sm-ssc adds:
    ADD_METHOD(GetNumStates);
    // ADD_METHOD( CelShading );
    //  LoadMilkshapeAsciiBones?
  }
};

LUA_REGISTER_DERIVED_CLASS(Model, Actor)
// lua end

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
