#include "BGAnimationLayer.h"

#include <algorithm>
#include <cmath>
#include <string>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "AutoActor.h"
#include "GameState.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageMath.h"
#include "RageTextureID.h"
#include "RageTimer.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "ScreenDimensions.h"
#include "Song.h"
#include "Sprite.h"
#include "StdString.h"
#include "ThemeManager.h"
#include "XmlFile.h"
#include "arch/ArchHooks/ArchHooks.h"
#include "global.h"

const float PARTICLE_SPEED = 300;

const float SPIRAL_MAX_ZOOM = 2;
const float SPIRAL_MIN_ZOOM = 0.3f;

#define MAX_TILES_WIDE int(SCREEN_WIDTH / 32 + 2)
#define MAX_TILES_HIGH int(SCREEN_HEIGHT / 32 + 2)
#define MAX_SPRITES (MAX_TILES_WIDE * MAX_TILES_HIGH)

inline float GetOffScreenLeft(Actor* pActor) {
  return SCREEN_LEFT - pActor->GetZoomedWidth() / 2;
}
inline float GetOffScreenRight(Actor* pActor) {
  return SCREEN_RIGHT + pActor->GetZoomedWidth() / 2;
}
inline float GetOffScreenTop(Actor* pActor) {
  return SCREEN_TOP - pActor->GetZoomedHeight() / 2;
}
inline float GetOffScreenBottom(Actor* pActor) {
  return SCREEN_BOTTOM + pActor->GetZoomedHeight() / 2;
}

inline bool IsOffScreenLeft(Actor* pActor) {
  return pActor->GetX() < GetOffScreenLeft(pActor);
}
inline bool IsOffScreenRight(Actor* pActor) {
  return pActor->GetX() > GetOffScreenRight(pActor);
}
inline bool IsOffScreenTop(Actor* pActor) {
  return pActor->GetY() < GetOffScreenTop(pActor);
}
inline bool IsOffScreenBottom(Actor* pActor) {
  return pActor->GetY() > GetOffScreenBottom(pActor);
}
inline bool IsOffScreen(Actor* pActor) {
  return IsOffScreenLeft(pActor) || IsOffScreenRight(pActor) ||
         IsOffScreenTop(pActor) || IsOffScreenBottom(pActor);
}

namespace {
float SafeFinite(float value, float fallback, const char* context) {
  if (!std::isfinite(value)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-710: BGAnimationLayer replaced non-finite %s with "
        "%.3f.",
        context, fallback);
    return fallback;
  }
  return value;
}

float SafePositive(float value, float fallback, const char* context) {
  value = SafeFinite(value, fallback, context);
  if (value <= 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-710: BGAnimationLayer replaced non-positive %s "
        "%.3f with %.3f.",
        context, value, fallback);
    return fallback;
  }
  return value;
}

void SetRandomStateIfPossible(Actor* actor, const char* context) {
  if (actor == nullptr) {
    return;
  }
  const int states = actor->GetNumStates();
  if (states <= 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-709: BGAnimationLayer skipped random state for %s "
        "because it has %d states.",
        context, states);
    return;
  }
  actor->SetState(RandomInt(states));
}

RageVector3 SafeRandomUnitVector() {
  RageVector3 velocity(randomf(), randomf(), 0);
  const float lenSq = velocity.x * velocity.x + velocity.y * velocity.y;
  if (lenSq <= 0.000001f || !std::isfinite(lenSq)) {
    velocity.x = 1.0f;
    velocity.y = 0.0f;
  } else {
    RageVec3Normalize(&velocity, &velocity);
  }
  return velocity;
}
}  // namespace

// guard rail is the area that keeps particles from going off screen
inline float GetGuardRailLeft(Actor* pActor) {
  return SCREEN_LEFT + pActor->GetZoomedWidth() / 2;
}
inline float GetGuardRailRight(Actor* pActor) {
  return SCREEN_RIGHT - pActor->GetZoomedWidth() / 2;
}
inline float GetGuardRailTop(Actor* pActor) {
  return SCREEN_TOP + pActor->GetZoomedHeight() / 2;
}
inline float GetGuardRailBottom(Actor* pActor) {
  return SCREEN_BOTTOM - pActor->GetZoomedHeight() / 2;
}

inline bool HitGuardRailLeft(Actor* pActor) {
  return pActor->GetX() < GetGuardRailLeft(pActor);
}
inline bool HitGuardRailRight(Actor* pActor) {
  return pActor->GetX() > GetGuardRailRight(pActor);
}
inline bool HitGuardRailTop(Actor* pActor) {
  return pActor->GetY() < GetGuardRailTop(pActor);
}
inline bool HitGuardRailBottom(Actor* pActor) {
  return pActor->GetY() > GetGuardRailBottom(pActor);
}

BGAnimationLayer::BGAnimationLayer() {
  m_vParticleVelocity.clear();

  m_Type = TYPE_SPRITE;

  m_fTexCoordVelocityX = 0;
  m_fTexCoordVelocityY = 0;
  m_bParticlesBounce = false;
  m_iNumTilesWide = -1;
  m_iNumTilesHigh = -1;
  m_fTilesStartX = 0;
  m_fTilesStartY = 0;
  m_fTilesSpacingX = -1;
  m_fTilesSpacingY = -1;
  m_fTileVelocityX = 0;
  m_fTileVelocityY = 0;
}

BGAnimationLayer::~BGAnimationLayer() { ActorFrame::DeleteAllChildren(); }

void BGAnimationLayer::LoadFromAniLayerFile(const std::string& sPath) {
  /* Generic BGAs are new.  Animation directories with no INI are old and
   * obsolete. Don't combine them. */
  std::string lcPath = sPath;
  MakeLower(lcPath);

  if (lcPath.find("usesongbg") != std::string::npos) {
    const Song* pSong = GAMESTATE != nullptr ? GAMESTATE->m_pCurSong : nullptr;
    std::string sSongBGPath;
    if (pSong && pSong->HasBackground()) {
      sSongBGPath = pSong->GetBackgroundPath();
    } else if (THEME != nullptr) {
      sSongBGPath = THEME->GetPathG("Common", "fallback background");
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-706: BGAnimationLayer could not resolve "
          "usesongbg fallback.");
      return;
    }

    Sprite* pSprite = new Sprite;
    pSprite->Load(Sprite::SongBGTexture(sSongBGPath));
    pSprite->StretchTo(FullScreenRectF);
    this->AddChild(pSprite);

    return;  // this will ignore other effects in the file name
  }

  enum Effect {
    EFFECT_CENTER,
    EFFECT_STRETCH_STILL,
    EFFECT_STRETCH_SCROLL_LEFT,
    EFFECT_STRETCH_SCROLL_RIGHT,
    EFFECT_STRETCH_SCROLL_UP,
    EFFECT_STRETCH_SCROLL_DOWN,
    EFFECT_STRETCH_WATER,
    EFFECT_STRETCH_BUBBLE,
    EFFECT_STRETCH_TWIST,
    EFFECT_STRETCH_SPIN,
    EFFECT_PARTICLES_SPIRAL_OUT,
    EFFECT_PARTICLES_SPIRAL_IN,
    EFFECT_PARTICLES_FLOAT_UP,
    EFFECT_PARTICLES_FLOAT_DOWN,
    EFFECT_PARTICLES_FLOAT_LEFT,
    EFFECT_PARTICLES_FLOAT_RIGHT,
    EFFECT_PARTICLES_BOUNCE,
    EFFECT_TILE_STILL,
    EFFECT_TILE_SCROLL_LEFT,
    EFFECT_TILE_SCROLL_RIGHT,
    EFFECT_TILE_SCROLL_UP,
    EFFECT_TILE_SCROLL_DOWN,
    EFFECT_TILE_FLIP_X,
    EFFECT_TILE_FLIP_Y,
    EFFECT_TILE_PULSE,
    NUM_EFFECTS,  // leave this at the end
    EFFECT_INVALID
  };

  const std::string EFFECT_STRING[NUM_EFFECTS] = {
      "center",
      "stretchstill",
      "stretchscrollleft",
      "stretchscrollright",
      "stretchscrollup",
      "stretchscrolldown",
      "stretchwater",
      "stretchbubble",
      "stretchtwist",
      "stretchspin",
      "particlesspiralout",
      "particlesspiralin",
      "particlesfloatup",
      "particlesfloatdown",
      "particlesfloatleft",
      "particlesfloatright",
      "particlesbounce",
      "tilestill",
      "tilescrollleft",
      "tilescrollright",
      "tilescrollup",
      "tilescrolldown",
      "tileflipx",
      "tileflipy",
      "tilepulse",
  };

  Effect effect = EFFECT_CENTER;

  for (int i = 0; i < NUM_EFFECTS; i++) {
    if (lcPath.find(EFFECT_STRING[i]) != std::string::npos) {
      effect = (Effect)i;
    }
  }

  switch (effect) {
    case EFFECT_CENTER: {
      m_Type = TYPE_SPRITE;
      Sprite* pSprite = new Sprite;
      this->AddChild(pSprite);
      pSprite->Load(sPath);
      pSprite->SetXY(SCREEN_CENTER_X, SCREEN_CENTER_Y);
    } break;
    case EFFECT_STRETCH_STILL:
    case EFFECT_STRETCH_SCROLL_LEFT:
    case EFFECT_STRETCH_SCROLL_RIGHT:
    case EFFECT_STRETCH_SCROLL_UP:
    case EFFECT_STRETCH_SCROLL_DOWN:
    case EFFECT_STRETCH_WATER:
    case EFFECT_STRETCH_BUBBLE:
    case EFFECT_STRETCH_TWIST: {
      m_Type = TYPE_SPRITE;
      Sprite* pSprite = new Sprite;
      this->AddChild(pSprite);
      RageTextureID ID(sPath);
      ID.bStretch = true;
      pSprite->Load(Sprite::SongBGTexture(ID));
      pSprite->StretchTo(FullScreenRectF);
      pSprite->SetCustomTextureRect(RectF(0, 0, 1, 1));

      switch (effect) {
        case EFFECT_STRETCH_SCROLL_LEFT:
          m_fTexCoordVelocityX = +0.5f;
          m_fTexCoordVelocityY = 0;
          break;
        case EFFECT_STRETCH_SCROLL_RIGHT:
          m_fTexCoordVelocityX = -0.5f;
          m_fTexCoordVelocityY = 0;
          break;
        case EFFECT_STRETCH_SCROLL_UP:
          m_fTexCoordVelocityX = 0;
          m_fTexCoordVelocityY = +0.5f;
          break;
        case EFFECT_STRETCH_SCROLL_DOWN:
          m_fTexCoordVelocityX = 0;
          m_fTexCoordVelocityY = -0.5f;
          break;
        default:
          break;
      }
    } break;
    case EFFECT_STRETCH_SPIN: {
      m_Type = TYPE_SPRITE;
      Sprite* pSprite = new Sprite;
      this->AddChild(pSprite);
      pSprite->Load(Sprite::SongBGTexture(sPath));
      const RectF StretchedFullScreenRectF(
          FullScreenRectF.left - 200, FullScreenRectF.top - 200,
          FullScreenRectF.right + 200, FullScreenRectF.bottom + 200);

      pSprite->ScaleToCover(StretchedFullScreenRectF);
      pSprite->SetEffectSpin(RageVector3(0, 0, 60));
    } break;
    case EFFECT_PARTICLES_SPIRAL_OUT:
    case EFFECT_PARTICLES_SPIRAL_IN:
    case EFFECT_PARTICLES_FLOAT_UP:
    case EFFECT_PARTICLES_FLOAT_DOWN:
    case EFFECT_PARTICLES_FLOAT_LEFT:
    case EFFECT_PARTICLES_FLOAT_RIGHT:
    case EFFECT_PARTICLES_BOUNCE: {
      m_Type = TYPE_PARTICLES;
      Sprite s;
      s.Load(sPath);
      const float fSpriteWidth = s.GetUnzoomedWidth();
      const float fSpriteHeight = s.GetUnzoomedHeight();
      if (!std::isfinite(fSpriteWidth) || !std::isfinite(fSpriteHeight) ||
          fSpriteWidth <= 0.0f || fSpriteHeight <= 0.0f) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-707: BGAnimationLayer skipped particles for "
            "'%s' because the source sprite has invalid size %.3fx%.3f.",
            sPath.c_str(), fSpriteWidth, fSpriteHeight);
        return;
      }
      int iSpriteArea = int(fSpriteWidth * fSpriteHeight);
      const int iMaxArea = int(SCREEN_WIDTH * SCREEN_HEIGHT);
      int iNumParticles = iMaxArea / iSpriteArea;
      iNumParticles = std::max(1, std::min(iNumParticles, MAX_SPRITES));

      for (int i = 0; i < iNumParticles; i++) {
        Sprite* pSprite = new Sprite;
        this->AddChild(pSprite);
        pSprite->Load(sPath);
        pSprite->SetZoom(0.7f + 0.6f * i / (float)iNumParticles);
        switch (effect) {
          case EFFECT_PARTICLES_BOUNCE:
            pSprite->SetX(
                randomf(GetGuardRailLeft(pSprite), GetGuardRailRight(pSprite)));
            pSprite->SetY(
                randomf(GetGuardRailTop(pSprite), GetGuardRailBottom(pSprite)));
            break;
          default:
            pSprite->SetX(
                randomf(GetOffScreenLeft(pSprite), GetOffScreenRight(pSprite)));
            pSprite->SetY(
                randomf(GetOffScreenTop(pSprite), GetOffScreenBottom(pSprite)));
            break;
        }

        switch (effect) {
          case EFFECT_PARTICLES_FLOAT_UP:
          case EFFECT_PARTICLES_SPIRAL_OUT:
            m_vParticleVelocity.push_back(
                RageVector3(0, -PARTICLE_SPEED * pSprite->GetZoom(), 0));
            break;
          case EFFECT_PARTICLES_FLOAT_DOWN:
          case EFFECT_PARTICLES_SPIRAL_IN:
            m_vParticleVelocity.push_back(
                RageVector3(0, PARTICLE_SPEED * pSprite->GetZoom(), 0));
            break;
          case EFFECT_PARTICLES_FLOAT_LEFT:
            m_vParticleVelocity.push_back(
                RageVector3(-PARTICLE_SPEED * pSprite->GetZoom(), 0, 0));
            break;
          case EFFECT_PARTICLES_FLOAT_RIGHT:
            m_vParticleVelocity.push_back(
                RageVector3(+PARTICLE_SPEED * pSprite->GetZoom(), 0, 0));
            break;
          case EFFECT_PARTICLES_BOUNCE:
            m_bParticlesBounce = true;
            pSprite->SetZoom(1);
            m_vParticleVelocity.push_back(SafeRandomUnitVector());
            m_vParticleVelocity.back().x *= PARTICLE_SPEED;
            m_vParticleVelocity.back().y *= PARTICLE_SPEED;
            break;
          default:
            LOG->Warn(
                "SRC_AUDIT_FIX SRC-714: BGAnimationLayer ignored "
                "unrecognized particle effect %i.",
                effect);
            return;
        }
      }
    } break;
    case EFFECT_TILE_STILL:
    case EFFECT_TILE_SCROLL_LEFT:
    case EFFECT_TILE_SCROLL_RIGHT:
    case EFFECT_TILE_SCROLL_UP:
    case EFFECT_TILE_SCROLL_DOWN:
    case EFFECT_TILE_FLIP_X:
    case EFFECT_TILE_FLIP_Y:
    case EFFECT_TILE_PULSE: {
      m_Type = TYPE_TILES;
      RageTextureID ID(sPath);
      ID.bStretch = true;
      Sprite s;
      s.Load(ID);
      const float fTileWidth = s.GetUnzoomedWidth();
      const float fTileHeight = s.GetUnzoomedHeight();
      if (!std::isfinite(fTileWidth) || !std::isfinite(fTileHeight) ||
          fTileWidth <= 0.0f || fTileHeight <= 0.0f) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-708: BGAnimationLayer skipped tiles for '%s' "
            "because the source sprite has invalid size %.3fx%.3f.",
            sPath.c_str(), fTileWidth, fTileHeight);
        return;
      }
      m_iNumTilesWide = 2 + int(SCREEN_WIDTH / fTileWidth);
      m_iNumTilesWide = std::min(m_iNumTilesWide, MAX_TILES_WIDE);
      m_iNumTilesWide = std::max(1, m_iNumTilesWide);
      m_iNumTilesHigh = 2 + int(SCREEN_HEIGHT / fTileHeight);
      m_iNumTilesHigh = std::min(m_iNumTilesHigh, MAX_TILES_HIGH);
      m_iNumTilesHigh = std::max(1, m_iNumTilesHigh);
      m_fTilesStartX = fTileWidth / 2;
      m_fTilesStartY = fTileHeight / 2;
      m_fTilesSpacingX = fTileWidth;
      m_fTilesSpacingY = fTileHeight;
      for (int x = 0; x < m_iNumTilesWide; x++) {
        for (int y = 0; y < m_iNumTilesHigh; y++) {
          Sprite* pSprite = new Sprite;
          this->AddChild(pSprite);
          pSprite->Load(ID);
          pSprite->SetTextureWrapping(true);  // gets rid of some "cracks"

          switch (effect) {
            case EFFECT_TILE_STILL:
              break;
            case EFFECT_TILE_SCROLL_LEFT:
              m_fTileVelocityX = -PARTICLE_SPEED;
              break;
            case EFFECT_TILE_SCROLL_RIGHT:
              m_fTileVelocityX = +PARTICLE_SPEED;
              break;
            case EFFECT_TILE_SCROLL_UP:
              m_fTileVelocityY = -PARTICLE_SPEED;
              break;
            case EFFECT_TILE_SCROLL_DOWN:
              m_fTileVelocityY = +PARTICLE_SPEED;
              break;
            case EFFECT_TILE_FLIP_X:
              pSprite->SetEffectSpin(RageVector3(180, 0, 0));
              break;
            case EFFECT_TILE_FLIP_Y:
              pSprite->SetEffectSpin(RageVector3(0, 180, 0));
              break;
            case EFFECT_TILE_PULSE:
              pSprite->SetEffectPulse(1, 0.3f, 1.f);
              break;
            default:
              LOG->Warn(
                  "SRC_AUDIT_FIX SRC-714: BGAnimationLayer ignored "
                  "unrecognized tile effect %i.",
                  effect);
              return;
          }
        }
      }
    } break;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-714: BGAnimationLayer ignored unrecognized layer "
          "effect %i.",
          effect);
      return;
  }

  std::string sHint = sPath;
  MakeLower(sHint);

  if (sHint.find("cyclecolor") != std::string::npos) {
    for (unsigned i = 0; i < m_SubActors.size(); i++) {
      m_SubActors[i]->SetEffectRainbow(5);
    }
  }

  if (sHint.find("cyclealpha") != std::string::npos) {
    for (unsigned i = 0; i < m_SubActors.size(); i++) {
      m_SubActors[i]->SetEffectDiffuseShift(
          2, RageColor(1, 1, 1, 1), RageColor(1, 1, 1, 0));
    }
  }

  if (sHint.find("startonrandomframe") != std::string::npos) {
    for (unsigned i = 0; i < m_SubActors.size(); i++) {
      SetRandomStateIfPossible(m_SubActors[i], sPath.c_str());
    }
  }

  if (sHint.find("dontanimate") != std::string::npos) {
    for (unsigned i = 0; i < m_SubActors.size(); i++) {
      m_SubActors[i]->StopAnimating();
    }
  }

  if (sHint.find("add") != std::string::npos) {
    for (unsigned i = 0; i < m_SubActors.size(); i++) {
      m_SubActors[i]->SetBlendMode(BLEND_ADD);
    }
  }
}

void BGAnimationLayer::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-710: BGAnimationLayer ignored null node.");
    return;
  }
  {
    bool bCond;
    if (pNode->GetAttrValue("Condition", bCond) && !bCond) {
      return;
    }
  }

  bool bStretch = false;
  {
    std::string type = "sprite";
    pNode->GetAttrValue("Type", type);
    MakeLower(type);

    /* The preferred way of stretching a sprite to fit the screen is
     * "Type=sprite" and "stretch=1".  "type=1" is for backwards-compatibility.
     */
    pNode->GetAttrValue("Stretch", bStretch);

    // Check for string match first, then do integer match.
    // "if(StringType(type)==0)" was matching against all string matches.
    // -Chris
    if (EqualsNoCase(type, "sprite")) {
      m_Type = TYPE_SPRITE;
    } else if (EqualsNoCase(type, "particles")) {
      m_Type = TYPE_PARTICLES;
    } else if (EqualsNoCase(type, "tiles")) {
      m_Type = TYPE_TILES;
    } else if (StringToInt(type) == 1) {
      m_Type = TYPE_SPRITE;
      bStretch = true;
    } else if (StringToInt(type) == 2) {
      m_Type = TYPE_PARTICLES;
    } else if (StringToInt(type) == 3) {
      m_Type = TYPE_TILES;
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-710: BGAnimationLayer type '%s' is invalid; "
          "using sprite.",
          type.c_str());
      m_Type = TYPE_SPRITE;
    }
  }

  pNode->GetAttrValue("FOV", m_fFOV);
  m_fFOV = SafeFinite(m_fFOV, 0.0f, "FOV");
  pNode->GetAttrValue("Lighting", m_bLighting);

  pNode->GetAttrValue("TexCoordVelocityX", m_fTexCoordVelocityX);
  pNode->GetAttrValue("TexCoordVelocityY", m_fTexCoordVelocityY);

  // compat:
  pNode->GetAttrValue("StretchTexCoordVelocityX", m_fTexCoordVelocityX);
  pNode->GetAttrValue("StretchTexCoordVelocityY", m_fTexCoordVelocityY);
  m_fTexCoordVelocityX =
      SafeFinite(m_fTexCoordVelocityX, 0.0f, "TexCoordVelocityX");
  m_fTexCoordVelocityY =
      SafeFinite(m_fTexCoordVelocityY, 0.0f, "TexCoordVelocityY");

  // particle and tile stuff
  float fZoomMin = 1;
  float fZoomMax = 1;
  pNode->GetAttrValue("ZoomMin", fZoomMin);
  pNode->GetAttrValue("ZoomMax", fZoomMax);
  fZoomMin = SafePositive(fZoomMin, 1.0f, "ZoomMin");
  fZoomMax = SafePositive(fZoomMax, fZoomMin, "ZoomMax");
  if (fZoomMin > fZoomMax) {
    std::swap(fZoomMin, fZoomMax);
  }

  float fVelocityXMin = 10, fVelocityXMax = 10;
  float fVelocityYMin = 0, fVelocityYMax = 0;
  float fVelocityZMin = 0, fVelocityZMax = 0;
  float fOverrideSpeed = 0;  // 0 means don't override speed
  pNode->GetAttrValue("VelocityXMin", fVelocityXMin);
  pNode->GetAttrValue("VelocityXMax", fVelocityXMax);
  pNode->GetAttrValue("VelocityYMin", fVelocityYMin);
  pNode->GetAttrValue("VelocityYMax", fVelocityYMax);
  pNode->GetAttrValue("VelocityZMin", fVelocityZMin);
  pNode->GetAttrValue("VelocityZMax", fVelocityZMax);
  pNode->GetAttrValue("OverrideSpeed", fOverrideSpeed);
  fVelocityXMin = SafeFinite(fVelocityXMin, 0.0f, "VelocityXMin");
  fVelocityXMax = SafeFinite(fVelocityXMax, fVelocityXMin, "VelocityXMax");
  fVelocityYMin = SafeFinite(fVelocityYMin, 0.0f, "VelocityYMin");
  fVelocityYMax = SafeFinite(fVelocityYMax, fVelocityYMin, "VelocityYMax");
  fVelocityZMin = SafeFinite(fVelocityZMin, 0.0f, "VelocityZMin");
  fVelocityZMax = SafeFinite(fVelocityZMax, fVelocityZMin, "VelocityZMax");
  if (fVelocityXMin > fVelocityXMax) {
    std::swap(fVelocityXMin, fVelocityXMax);
  }
  if (fVelocityYMin > fVelocityYMax) {
    std::swap(fVelocityYMin, fVelocityYMax);
  }
  if (fVelocityZMin > fVelocityZMax) {
    std::swap(fVelocityZMin, fVelocityZMax);
  }
  fOverrideSpeed = SafeFinite(fOverrideSpeed, 0.0f, "OverrideSpeed");
  if (fOverrideSpeed < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-710: BGAnimationLayer converted negative "
        "OverrideSpeed %.3f to positive.",
        fOverrideSpeed);
    fOverrideSpeed = -fOverrideSpeed;
  }

  int iNumParticles = 10;
  pNode->GetAttrValue("NumParticles", iNumParticles);
  if (iNumParticles < 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-710: BGAnimationLayer clamped negative "
        "NumParticles %d.",
        iNumParticles);
    iNumParticles = 0;
  }
  iNumParticles = std::min(iNumParticles, MAX_SPRITES);

  pNode->GetAttrValue("ParticlesBounce", m_bParticlesBounce);
  pNode->GetAttrValue("TilesStartX", m_fTilesStartX);
  pNode->GetAttrValue("TilesStartY", m_fTilesStartY);
  pNode->GetAttrValue("TilesSpacingX", m_fTilesSpacingX);
  pNode->GetAttrValue("TilesSpacingY", m_fTilesSpacingY);
  pNode->GetAttrValue("TileVelocityX", m_fTileVelocityX);
  pNode->GetAttrValue("TileVelocityY", m_fTileVelocityY);
  m_fTilesStartX = SafeFinite(m_fTilesStartX, 0.0f, "TilesStartX");
  m_fTilesStartY = SafeFinite(m_fTilesStartY, 0.0f, "TilesStartY");
  m_fTilesSpacingX = SafeFinite(m_fTilesSpacingX, -1.0f, "TilesSpacingX");
  m_fTilesSpacingY = SafeFinite(m_fTilesSpacingY, -1.0f, "TilesSpacingY");
  m_fTileVelocityX = SafeFinite(m_fTileVelocityX, 0.0f, "TileVelocityX");
  m_fTileVelocityY = SafeFinite(m_fTileVelocityY, 0.0f, "TileVelocityY");

  switch (m_Type) {
    case TYPE_SPRITE: {
      Actor* pActor = ActorUtil::LoadFromNode(pNode, this);
      if (pActor == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-711: BGAnimationLayer sprite actor failed to "
            "load.");
        return;
      }
      this->AddChild(pActor);
      if (bStretch) {
        pActor->StretchTo(FullScreenRectF);
      }
    } break;
    case TYPE_PARTICLES: {
      std::string sFile;
      ActorUtil::GetAttrPath(pNode, "File", sFile);
      FixSlashesInPlace(sFile);

      CollapsePath(sFile);
      if (sFile.empty()) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-712: BGAnimationLayer particles missing File "
            "attribute.");
        return;
      }

      for (int i = 0; i < iNumParticles; i++) {
        Actor* pActor = ActorUtil::MakeActor(sFile, this);
        if (pActor == nullptr) {
          continue;
        }
        this->AddChild(pActor);
        pActor->SetXY(
            randomf(float(FullScreenRectF.left), float(FullScreenRectF.right)),
            randomf(float(FullScreenRectF.top), float(FullScreenRectF.bottom)));
        pActor->SetZoom(randomf(fZoomMin, fZoomMax));
        m_vParticleVelocity.push_back(RageVector3(
            randomf(fVelocityXMin, fVelocityXMax),
            randomf(fVelocityYMin, fVelocityYMax),
            randomf(fVelocityZMin, fVelocityZMax)));
        if (fOverrideSpeed != 0) {
          RageVector3& velocity = m_vParticleVelocity.back();
          const float lenSq =
              velocity.x * velocity.x + velocity.y * velocity.y +
              velocity.z * velocity.z;
          if (lenSq <= 0.000001f || !std::isfinite(lenSq)) {
            velocity = RageVector3(1, 0, 0);
          } else {
            RageVec3Normalize(&velocity, &velocity);
          }
          velocity *= fOverrideSpeed;
        }
      }
    } break;
    case TYPE_TILES: {
      std::string sFile;
      ActorUtil::GetAttrPath(pNode, "File", sFile);
      FixSlashesInPlace(sFile);

      CollapsePath(sFile);
      if (sFile.empty()) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-708: BGAnimationLayer tiles missing File "
            "attribute.");
        return;
      }

      AutoActor s;
      s.Load(sFile);
      if (!s.IsLoaded()) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-708: BGAnimationLayer could not load tile "
            "source '%s'.",
            sFile.c_str());
        return;
      }
      if (m_fTilesSpacingX == -1) {
        m_fTilesSpacingX = s->GetUnzoomedWidth();
      }
      if (m_fTilesSpacingY == -1) {
        m_fTilesSpacingY = s->GetUnzoomedHeight();
      }
      m_fTilesSpacingX = SafePositive(m_fTilesSpacingX, 64.0f, "TilesSpacingX");
      m_fTilesSpacingY = SafePositive(m_fTilesSpacingY, 64.0f, "TilesSpacingY");
      m_iNumTilesWide = 2 + (int)(SCREEN_WIDTH / m_fTilesSpacingX);
      m_iNumTilesHigh = 2 + (int)(SCREEN_HEIGHT / m_fTilesSpacingY);
      m_iNumTilesWide =
          std::max(1, std::min(m_iNumTilesWide, MAX_TILES_WIDE));
      m_iNumTilesHigh =
          std::max(1, std::min(m_iNumTilesHigh, MAX_TILES_HIGH));
      unsigned NumSprites = m_iNumTilesWide * m_iNumTilesHigh;
      NumSprites = std::min<unsigned>(NumSprites, MAX_SPRITES);
      for (unsigned i = 0; i < NumSprites; i++) {
        Actor* pSprite = ActorUtil::MakeActor(sFile, this);
        if (pSprite == nullptr) {
          continue;
        }
        this->AddChild(pSprite);
        pSprite->SetTextureWrapping(true);  // gets rid of some "cracks"
        pSprite->SetZoom(randomf(fZoomMin, fZoomMax));
      }
    } break;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-714: BGAnimationLayer ignored unrecognized type "
          "%i.",
          m_Type);
      return;
  }

  bool bStartOnRandomFrame = false;
  pNode->GetAttrValue("StartOnRandomFrame", bStartOnRandomFrame);
  if (bStartOnRandomFrame) {
    for (unsigned i = 0; i < m_SubActors.size(); i++) {
      SetRandomStateIfPossible(m_SubActors[i], "LoadFromNode");
    }
  }
}

void BGAnimationLayer::UpdateInternal(float fDeltaTime) {
  if (!std::isfinite(fDeltaTime)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-710: BGAnimationLayer ignored non-finite delta.");
    return;
  }
  ActorFrame::UpdateInternal(fDeltaTime);

  fDeltaTime *= m_fUpdateRate;
  if (!std::isfinite(fDeltaTime)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-710: BGAnimationLayer ignored non-finite scaled "
        "delta.");
    return;
  }

  switch (m_Type) {
    case TYPE_SPRITE:
      if (m_fTexCoordVelocityX || m_fTexCoordVelocityY) {
        for (unsigned i = 0; i < m_SubActors.size(); i++) {
          Sprite* pSprite = dynamic_cast<Sprite*>(m_SubActors[i]);
          if (pSprite == nullptr) {
            LOG->Warn(
                "SRC_AUDIT_FIX SRC-711: BGAnimationLayer skipped texcoord "
                "scroll on non-sprite actor.");
            continue;
          }
          pSprite->StretchTexCoords(
              fDeltaTime * m_fTexCoordVelocityX,
              fDeltaTime * m_fTexCoordVelocityY);
        }
      }
      break;
    case TYPE_PARTICLES:
      for (unsigned i = 0; i < m_SubActors.size(); i++) {
        if (i >= m_vParticleVelocity.size()) {
          LOG->Warn(
              "SRC_AUDIT_FIX SRC-712: BGAnimationLayer particle actor/vector "
              "count mismatch; stopping particle update.");
          break;
        }
        Actor* pActor = m_SubActors[i];
        if (pActor == nullptr) {
          continue;
        }
        RageVector3& vel = m_vParticleVelocity[i];

        m_SubActors[i]->SetX(pActor->GetX() + fDeltaTime * vel.x);
        m_SubActors[i]->SetY(pActor->GetY() + fDeltaTime * vel.y);
        pActor->SetZ(pActor->GetZ() + fDeltaTime * vel.z);
        if (m_bParticlesBounce) {
          if (HitGuardRailLeft(pActor)) {
            vel.x *= -1;
            pActor->SetX(GetGuardRailLeft(pActor));
          }
          if (HitGuardRailRight(pActor)) {
            vel.x *= -1;
            pActor->SetX(GetGuardRailRight(pActor));
          }
          if (HitGuardRailTop(pActor)) {
            vel.y *= -1;
            pActor->SetY(GetGuardRailTop(pActor));
          }
          if (HitGuardRailBottom(pActor)) {
            vel.y *= -1;
            pActor->SetY(GetGuardRailBottom(pActor));
          }
        } else  // !m_bParticlesBounce
        {
          if (vel.x < 0 && IsOffScreenLeft(pActor)) {
            pActor->SetX(GetOffScreenRight(pActor));
          }
          if (vel.x > 0 && IsOffScreenRight(pActor)) {
            pActor->SetX(GetOffScreenLeft(pActor));
          }
          if (vel.y < 0 && IsOffScreenTop(pActor)) {
            pActor->SetY(GetOffScreenBottom(pActor));
          }
          if (vel.y > 0 && IsOffScreenBottom(pActor)) {
            pActor->SetY(GetOffScreenTop(pActor));
          }
        }
      }
      break;
    case TYPE_TILES: {
      if (m_iNumTilesWide <= 0 || m_iNumTilesHigh <= 0 ||
          m_fTilesSpacingX <= 0.0f || m_fTilesSpacingY <= 0.0f ||
          !std::isfinite(m_fTilesSpacingX) ||
          !std::isfinite(m_fTilesSpacingY)) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-713: BGAnimationLayer skipped tile update "
            "because grid dimensions are invalid.");
        return;
      }
      double fSecs = RageTimer::GetTimeSinceStart();
      double fTotalWidth =
          static_cast<double>(m_iNumTilesWide) * m_fTilesSpacingX;
      double fTotalHeight =
          static_cast<double>(m_iNumTilesHigh) * m_fTilesSpacingY;
      if (fTotalWidth <= 0.0 || fTotalHeight <= 0.0 ||
          !std::isfinite(fTotalWidth) || !std::isfinite(fTotalHeight)) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-713: BGAnimationLayer skipped tile update "
            "because total dimensions are invalid.");
        return;
      }

      const int expectedTiles = m_iNumTilesWide * m_iNumTilesHigh;
      if (static_cast<int>(m_SubActors.size()) < expectedTiles) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-713: BGAnimationLayer has %zu tile actors but "
            "expected %d.",
            m_SubActors.size(), expectedTiles);
      }

      for (int x = 0; x < m_iNumTilesWide; x++) {
        for (int y = 0; y < m_iNumTilesHigh; y++) {
          int i = y * m_iNumTilesWide + x;
          if (i < 0 || i >= static_cast<int>(m_SubActors.size()) ||
              m_SubActors[i] == nullptr) {
            continue;
          }

          double fX =
              m_fTilesStartX + m_fTilesSpacingX * x + fSecs * m_fTileVelocityX;
          double fY =
              m_fTilesStartY + m_fTilesSpacingY * y + fSecs * m_fTileVelocityY;

          fX += m_fTilesSpacingX / 2;
          fY += m_fTilesSpacingY / 2;

          fX = std::fmod(fX, fTotalWidth);
          fY = std::fmod(fY, fTotalHeight);

          if (fX < 0) {
            fX += fTotalWidth;
          }
          if (fY < 0) {
            fY += fTotalHeight;
          }

          fX -= m_fTilesSpacingX / 2;
          fY -= m_fTilesSpacingY / 2;

          m_SubActors[i]->SetX(static_cast<float>(fX));
          m_SubActors[i]->SetY(static_cast<float>(fY));
        }
      }
    } break;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-714: BGAnimationLayer skipped update for "
          "unrecognized type %i.",
          m_Type);
      return;
  }
}

/*
 * (c) 2001-2004 Ben Nordstrom, Chris Danford, Glenn Maynard
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
