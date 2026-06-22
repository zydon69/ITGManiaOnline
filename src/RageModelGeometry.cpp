#include "RageModelGeometry.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "ModelTypes.h"
#include "RageDisplay.h"
#include "RageException.h"
#include "RageFile.h"
#include "RageMath.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "global.h"

#define MS_MAX_NAME 32

namespace {
constexpr int kMaxMeshes = 4096;
constexpr int kMaxVertices = std::numeric_limits<uint16_t>::max();
constexpr int kMaxNormals = std::numeric_limits<uint16_t>::max();
constexpr int kMaxTriangles = 1000000;

bool IsFiniteVector(const RageVector3& v) {
  return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]);
}

bool IsFiniteVector(const RageVector2& v) {
  return std::isfinite(v[0]) && std::isfinite(v[1]);
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

void ValidateInt8Index(
    int value, const char* label, const std::string& sPath, int iLineNum,
    const std::string& sLine) {
  if (value < -1 || value > std::numeric_limits<int8_t>::max()) {
    RageException::Throw(
        "Parse error in \"%s\" at line %d: invalid %s index %d in \"%s\".",
        sPath.c_str(), iLineNum, label, value, sLine.c_str());
  }
}
}  // namespace

RageModelGeometry::RageModelGeometry() {
  m_iRefCount = 1;
  m_pCompiledGeometry =
      DISPLAY != nullptr ? DISPLAY->CreateCompiledGeometry() : nullptr;
}

RageModelGeometry::~RageModelGeometry() {
  if (DISPLAY != nullptr && m_pCompiledGeometry != nullptr) {
    DISPLAY->DeleteCompiledGeometry(m_pCompiledGeometry);
  }
  m_pCompiledGeometry = nullptr;
}

void RageModelGeometry::OptimizeBones() {
  for (unsigned i = 0; i < m_Meshes.size(); i++) {
    msMesh& mesh = m_Meshes[i];

    if (mesh.Vertices.empty()) {
      continue;  // nothing to optimize
    }

    // check to see if all vertices have the same bone index
    bool bAllVertsUseSameBone = true;

    char iBoneIndex = mesh.Vertices[0].bone;

    for (unsigned j = 1; j < mesh.Vertices.size(); j++) {
      if (mesh.Vertices[j].bone != iBoneIndex) {
        bAllVertsUseSameBone = false;
        break;
      }
    }

    if (bAllVertsUseSameBone) {
      mesh.m_iBoneIndex = iBoneIndex;

      // clear all vertex/bone associations;
      for (unsigned j = 0; j < mesh.Vertices.size(); j++) {
        mesh.Vertices[j].bone = -1;
      }
    }
  }
}

void RageModelGeometry::MergeMeshes(int iFromIndex, int iToIndex) {
  msMesh& meshFrom = m_Meshes[iFromIndex];
  msMesh& meshTo = m_Meshes[iToIndex];

  int iShiftTriangleVertexIndicesBy = meshTo.Vertices.size();
  int iStartShiftingAtTriangleIndex = meshTo.Triangles.size();

  meshTo.Vertices.insert(
      meshTo.Vertices.end(), meshFrom.Vertices.begin(),
      meshFrom.Vertices.end());
  meshTo.Triangles.insert(
      meshTo.Triangles.end(), meshFrom.Triangles.begin(),
      meshFrom.Triangles.end());

  for (unsigned i = iStartShiftingAtTriangleIndex; i < meshTo.Triangles.size();
       i++) {
    for (int j = 0; j < 3; j++) {
      uint16_t& iIndex = meshTo.Triangles[i].nVertexIndices[j];
      iIndex = uint16_t(iIndex + iShiftTriangleVertexIndicesBy);
    }
  }
}

bool RageModelGeometry::HasAnyPerVertexBones() const {
  for (unsigned i = 0; i < m_Meshes.size(); ++i) {
    const msMesh& mesh = m_Meshes[i];
    for (unsigned j = 0; j < mesh.Vertices.size(); ++j) {
      if (mesh.Vertices[j].bone != -1) {
        return true;
      }
    }
  }

  return false;
}

#define THROW                                                               \
  RageException::Throw(                                                     \
      "Parse error in \"%s\" at line %d: \"%s\".", sPath.c_str(), iLineNum, \
      sLine.c_str())

void RageModelGeometry::LoadMilkshapeAscii(
    const std::string& _sPath, bool bNeedsNormals) {
  std::string sPath = _sPath;
  FixSlashesInPlace(sPath);
  const std::string sDir = Dirname(sPath);

  RageFile f;
  if (!f.Open(sPath)) {
    RageException::Throw(
        "RageModelGeometry::LoadMilkshapeAscii Could not open \"%s\": %s",
        sPath.c_str(), f.GetError().c_str());
  }

  std::string sLine;
  int iLineNum = 0;
  char szName[MS_MAX_NAME];
  int nFlags, nIndex;

  RageVec3ClearBounds(m_vMins, m_vMaxs);

  while (f.GetLine(sLine) > 0) {
    iLineNum++;

    if (!strncmp(sLine.c_str(), "//", 2)) {
      continue;
    }

    int nFrame;
    if (sscanf(sLine.c_str(), "Frames: %d", &nFrame) == 1) {
      // ignore
      // m_pRageModelGeometry->nTotalFrames = nFrame;
    }
    if (sscanf(sLine.c_str(), "Frame: %d", &nFrame) == 1) {
      // ignore
      // m_pRageModelGeometry->nFrame = nFrame;
    }

    int nNumMeshes = 0;
    if (sscanf(sLine.c_str(), "Meshes: %d", &nNumMeshes) == 1) {
      ASSERT(m_Meshes.empty());
      ValidateCount(nNumMeshes, kMaxMeshes, "mesh", sPath, iLineNum, sLine);
      m_Meshes.resize(nNumMeshes);

      for (int i = 0; i < nNumMeshes; i++) {
        msMesh& mesh = m_Meshes[i];
        std::vector<RageModelVertex>& Vertices = mesh.Vertices;
        std::vector<msTriangle>& Triangles = mesh.Triangles;

        if (f.GetLine(sLine) <= 0) {
          THROW;
        }

        // mesh: name, flags, material index
        if (sscanf(
                sLine.c_str(), "\"%31[^\"]\" %d %d", szName, &nFlags,
                &nIndex) != 3) {
          THROW;
        }

        ValidateInt8Index(nIndex, "material", sPath, iLineNum, sLine);

        mesh.sName = szName;
        // mesh.nFlags = nFlags;
        mesh.nMaterialIndex = static_cast<int8_t>(nIndex);

        mesh.m_iBoneIndex = -1;

        //
        // vertices
        //
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }

        int nNumVertices = 0;
        if (sscanf(sLine.c_str(), "%d", &nNumVertices) != 1) {
          THROW;
        }
        ValidateCount(nNumVertices, kMaxVertices, "vertex", sPath, iLineNum, sLine);

        Vertices.resize(nNumVertices);

        for (int j = 0; j < nNumVertices; j++) {
          RageModelVertex& v = Vertices[j];

          if (f.GetLine(sLine) <= 0) {
            THROW;
          }

          if (sscanf(
                  sLine.c_str(), "%d %f %f %f %f %f %d", &nFlags, &v.p[0],
                  &v.p[1], &v.p[2], &v.t[0], &v.t[1], &nIndex) != 7) {
            THROW;
          }
          ValidateInt8Index(nIndex, "bone", sPath, iLineNum, sLine);
          if (!IsFiniteVector(v.p) || !IsFiniteVector(v.t)) {
            THROW;
          }

          // vertex.nFlags = nFlags;
          if (nFlags & 1) {
            v.TextureMatrixScale.x = 0;
          }
          if (nFlags & 2) {
            v.TextureMatrixScale.y = 0;
          }
          if (nFlags & 4) {
            if (v.t[0] == 0.0f || v.t[1] == 0.0f) {
              THROW;
            }
            v.t[0] = v.p[0] / v.t[0];
            v.t[1] = v.p[1] / v.t[1];
          }
          v.bone = static_cast<int8_t>(nIndex);
          RageVec3AddToBounds(v.p, m_vMins, m_vMaxs);
        }

        //
        // normals
        //
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }

        int nNumNormals = 0;
        if (sscanf(sLine.c_str(), "%d", &nNumNormals) != 1) {
          THROW;
        }
        ValidateCount(nNumNormals, kMaxNormals, "normal", sPath, iLineNum, sLine);

        std::vector<RageVector3> Normals;
        Normals.resize(nNumNormals);
        for (int j = 0; j < nNumNormals; j++) {
          if (f.GetLine(sLine) <= 0) {
            THROW;
          }

          RageVector3 Normal;
          if (sscanf(
                  sLine.c_str(), "%f %f %f", &Normal[0], &Normal[1],
                  &Normal[2]) != 3) {
            THROW;
          }
          if (!IsFiniteVector(Normal)) {
            THROW;
          }

          const float normalLengthSq =
              Normal[0] * Normal[0] + Normal[1] * Normal[1] +
              Normal[2] * Normal[2];
          if (!std::isfinite(normalLengthSq) || normalLengthSq <= 0.0f) {
            THROW;
          }

          RageVec3Normalize((RageVector3*)&Normal, (RageVector3*)&Normal);
          Normals[j] = Normal;
        }

        //
        // triangles
        //
        if (f.GetLine(sLine) <= 0) {
          THROW;
        }

        int nNumTriangles = 0;
        if (sscanf(sLine.c_str(), "%d", &nNumTriangles) != 1) {
          THROW;
        }
        ValidateCount(
            nNumTriangles, kMaxTriangles, "triangle", sPath, iLineNum, sLine);

        Triangles.resize(nNumTriangles);

        for (int j = 0; j < nNumTriangles; j++) {
          if (f.GetLine(sLine) <= 0) {
            THROW;
          }

          int nIndices[3];
          int nNormalIndices[3];
          if (sscanf(
                  sLine.c_str(), "%d %d %d %d %d %d %d %d", &nFlags,
                  &nIndices[0], &nIndices[1], &nIndices[2], &nNormalIndices[0],
                  &nNormalIndices[1], &nNormalIndices[2], &nIndex) != 8) {
            THROW;
          }

          // deflate the normals into vertices
          for (int k = 0; k < 3; k++) {
            if (nIndices[k] < 0 ||
                static_cast<size_t>(nIndices[k]) >= Vertices.size() ||
                nNormalIndices[k] < 0 ||
                static_cast<size_t>(nNormalIndices[k]) >= Normals.size()) {
              RageException::Throw(
                  "Parse error in \"%s\" at line %d: mesh \"%s\" tri #%i "
                  "uses vertex %i/%zu or normal %i/%zu.",
                  sPath.c_str(), iLineNum, szName, j, nIndices[k],
                  Vertices.size(), nNormalIndices[k], Normals.size());
            }
            RageModelVertex& vertex = Vertices[nIndices[k]];
            RageVector3& normal = Normals[nNormalIndices[k]];
            vertex.n = normal;
            // mesh.Vertices[nIndices[k]].n = Normals[ nNormalIndices[k] ];
          }

          msTriangle& Triangle = Triangles[j];
          // Triangle.nFlags = nFlags;
          for (int k = 0; k < 3; ++k) {
            Triangle.nVertexIndices[k] = static_cast<uint16_t>(nIndices[k]);
          }
          // Triangle.nSmoothingGroup = nIndex;
        }
      }
    }
  }

  OptimizeBones();

  if (DISPLAY != nullptr && DISPLAY->SupportsPerVertexMatrixScale()) {
    if (m_Meshes.size() == 2 && m_Meshes[0].sName == m_Meshes[1].sName) {
      MergeMeshes(1, 0);
    }
  }

  // send the finalized vertices to the graphics card
  if (m_pCompiledGeometry == nullptr) {
    RageException::Throw(
        "RageModelGeometry::LoadMilkshapeAscii cannot compile \"%s\" without a "
        "display backend.",
        sPath.c_str());
  }
  m_pCompiledGeometry->Set(m_Meshes, bNeedsNormals);
}

/*
 * Copyright (c) 2001-2002 Chris Danford
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
