#include "RageFileDriverMemory.h"

#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

#include "RageFile.h"
#include "RageFileBasic.h"
#include "RageFileDriver.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "RageUtil_FileDB.h"
#include "global.h"

struct RageFileObjMemFile {
  RageFileObjMemFile() : m_iRefs(0), m_Mutex("RageFileObjMemFile") {}
  std::string m_sBuf;
  int m_iRefs;
  RageMutex m_Mutex;

  static void AddReference(RageFileObjMemFile* pFile) {
    pFile->m_Mutex.Lock();
    ++pFile->m_iRefs;
    pFile->m_Mutex.Unlock();
  }

  static void ReleaseReference(RageFileObjMemFile* pFile) {
    pFile->m_Mutex.Lock();
    const int iRefs = --pFile->m_iRefs;
    const bool bShouldDelete = (pFile->m_iRefs == 0);
    pFile->m_Mutex.Unlock();
    ASSERT(iRefs >= 0);

    if (bShouldDelete) {
      delete pFile;
    }
  }
};

RageFileObjMem::RageFileObjMem(RageFileObjMemFile* pFile) {
  if (pFile == nullptr) {
    pFile = new RageFileObjMemFile;
  }

  m_pFile = pFile;
  m_iFilePos = 0;
  RageFileObjMemFile::AddReference(m_pFile);
}

RageFileObjMem::~RageFileObjMem() {
  RageFileObjMemFile::ReleaseReference(m_pFile);
}

int RageFileObjMem::ReadInternal(void* buffer, size_t bytes) {
  LockMut(m_pFile->m_Mutex);

  const size_t fileSize = m_pFile->m_sBuf.size();
  const size_t filePos = std::min(static_cast<size_t>(m_iFilePos), fileSize);
  m_iFilePos = static_cast<int>(filePos);
  bytes = std::min(bytes, fileSize - filePos);
  if (bytes == 0) {
    return 0;
  }
  memcpy(buffer, m_pFile->m_sBuf.data() + filePos, bytes);
  m_iFilePos += static_cast<int>(bytes);

  return static_cast<int>(bytes);
}

int RageFileObjMem::WriteInternal(const void* buffer, size_t bytes) {
  if (m_iFilePos < 0 ||
      bytes > static_cast<size_t>(std::numeric_limits<int>::max() - m_iFilePos)) {
    SetError("Memory file exceeds the supported size");
    return -1;
  }

  LockMut(m_pFile->m_Mutex);
  try {
    m_pFile->m_sBuf.replace(
        static_cast<size_t>(m_iFilePos), bytes,
        static_cast<const char*>(buffer), bytes);
  } catch (const std::exception& error) {
    SetError(std::string("Could not write memory file: ") + error.what());
    return -1;
  }

  m_iFilePos += static_cast<int>(bytes);
  return static_cast<int>(bytes);
}

int RageFileObjMem::SeekInternal(int offset) {
  m_iFilePos = std::clamp(offset, 0, GetFileSize());
  return m_iFilePos;
}

int RageFileObjMem::GetFileSize() const {
  LockMut(m_pFile->m_Mutex);
  return static_cast<int>(m_pFile->m_sBuf.size());
}

RageFileObjMem::RageFileObjMem(const RageFileObjMem& cpy) : RageFileObj(cpy) {
  m_pFile = cpy.m_pFile;
  m_iFilePos = cpy.m_iFilePos;
  RageFileObjMemFile::AddReference(m_pFile);
}

RageFileObjMem* RageFileObjMem::Copy() const {
  RageFileObjMem* pRet = new RageFileObjMem(*this);
  return pRet;
}

std::string RageFileObjMem::GetString() const {
  LockMut(m_pFile->m_Mutex);
  return m_pFile->m_sBuf;
}

bool RageFileObjMem::PutString(const std::string& sBuf) {
  if (sBuf.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    SetError("Memory file exceeds the supported size");
    return false;
  }

  int newPos = -1;
  {
    LockMut(m_pFile->m_Mutex);
    try {
      m_pFile->m_sBuf = sBuf;
      newPos = std::min(RageFileObj::Tell(), static_cast<int>(sBuf.size()));
    } catch (const std::exception& error) {
      SetError(std::string("Could not replace memory file: ") + error.what());
      return false;
    }
  }
  if (RageFileObj::Seek(newPos) != newPos) {
    SetError("Could not synchronize memory file position");
    return false;
  }
  return true;
}

RageFileDriverMem::RageFileDriverMem()
    : RageFileDriver(new NullFilenameDB), m_Mutex("RageFileDriverMem") {}

RageFileDriverMem::~RageFileDriverMem() {
  for (unsigned i = 0; i < m_Files.size(); ++i) {
    RageFileObjMemFile* pFile = m_Files[i];
    RageFileObjMemFile::ReleaseReference(pFile);
  }
}

RageFileBasic* RageFileDriverMem::Open(
    const std::string& sPath, int mode, int& err) {
  LockMut(m_Mutex);

  if ((mode & RageFile::WRITE) != 0) {
    /* If the file exists, delete it. */
    Remove(sPath);

    RageFileObjMemFile* pFile = new RageFileObjMemFile;

    /* Add one reference, representing the file in the filesystem. */
    RageFileObjMemFile::AddReference(pFile);

    m_Files.push_back(pFile);
    FDB->AddFile(sPath, 0, 0, pFile);

    return new RageFileObjMem(pFile);
  }

  RageFileObjMemFile* pFile = (RageFileObjMemFile*)FDB->GetFilePriv(sPath);
  if (pFile == nullptr) {
    err = ENOENT;
    return nullptr;
  }

  return new RageFileObjMem(pFile);
}

bool RageFileDriverMem::Remove(const std::string& sPath) {
  LockMut(m_Mutex);

  RageFileObjMemFile* pFile = (RageFileObjMemFile*)FDB->GetFilePriv(sPath);
  if (pFile == nullptr) {
    return false;
  }

  /* Unregister the file. */
  FDB->DelFile(sPath);
  std::vector<RageFileObjMemFile*>::iterator it =
      find(m_Files.begin(), m_Files.end(), pFile);
  ASSERT(it != m_Files.end());
  m_Files.erase(it);

  RageFileObjMemFile::ReleaseReference(pFile);

  return true;
}

static struct FileDriverEntry_MEM : public FileDriverEntry {
  FileDriverEntry_MEM() : FileDriverEntry("MEM") {}
  RageFileDriver* Create(const std::string& sRoot) const {
    return new RageFileDriverMem();
  }
} const g_RegisterDriver;

/*
 * (c) 2004 Glenn Maynard
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
