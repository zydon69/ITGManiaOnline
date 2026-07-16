#include "MovieTexture.h"

#include <algorithm>
#include <array>
#include <string>
#include <vector>

#include "LocalizedString.h"
#include "Preference.h"
#include "RageFile.h"
#include "RageLog.h"
#include "RageTextureID.h"
#include "RageUtil.h"
#include "StdString.h"
#include "arch/RageDriver.h"
#include "arch/arch_default.h"
#include "global.h"

void ForceToAscii(std::string& str) {
  for (unsigned i = 0; i < str.size(); ++i) {
    const unsigned char c = static_cast<unsigned char>(str[i]);
    if (c < 0x20 || c > 0x7E) {
      str[i] = '?';
    }
  }
}

bool RageMovieTexture::GetFourCC(
    std::string fn, std::string& handler, std::string& type) {
  std::string ignore, ext;
  splitpath(fn, ignore, ignore, ext);
  if (!CompareNoCase(ext, ".mpg") || !CompareNoCase(ext, ".mpeg") ||
      !CompareNoCase(ext, ".mpv") || !CompareNoCase(ext, ".mpe")) {
    handler = type = "MPEG";
    return true;
  }
  if (!CompareNoCase(ext, ".ogv")) {
    handler = type = "Ogg";
    return true;
  }

  // Not very pretty but should do all the same error checking without iostream
#define HANDLE_ERROR(x)                                      \
  {                                                          \
    if (LOG != nullptr) {                                    \
      LOG->Warn("Error reading %s: %s", fn.c_str(), x);      \
    }                                                        \
    handler = type = "";                                     \
    return false;                                            \
  }

  RageFile file;
  if (!file.Open(fn)) {
    HANDLE_ERROR("Could not open file.");
  }
  if (file.Seek(0x70) != 0x70) {
    HANDLE_ERROR("Could not seek.");
  }
  std::array<char, 4> typeBytes;
  if (file.Read(typeBytes.data(), typeBytes.size()) !=
      static_cast<int>(typeBytes.size())) {
    HANDLE_ERROR("Could not read.");
  }
  type.assign(typeBytes.data(), typeBytes.size());
  ForceToAscii(type);

  if (file.Seek(0xBC) != 0xBC) {
    HANDLE_ERROR("Could not seek.");
  }
  std::array<char, 4> handlerBytes;
  if (file.Read(handlerBytes.data(), handlerBytes.size()) !=
      static_cast<int>(handlerBytes.size())) {
    HANDLE_ERROR("Could not read.");
  }
  handler.assign(handlerBytes.data(), handlerBytes.size());
  ForceToAscii(handler);

  return true;
#undef HANDLE_ERROR
}

DriverList RageMovieTextureDriver::m_pDriverList;

// Helper for MakeRageMovieTexture()
static void DumpAVIDebugInfo(const std::string& fn) {
  std::string type, handler;
  if (!RageMovieTexture::GetFourCC(fn, handler, type)) {
    return;
  }

  if (LOG != nullptr) {
    LOG->Trace(
        "Movie %s has handler '%s', type '%s'", fn.c_str(), handler.c_str(),
        type.c_str());
  }
}

static Preference<std::string> g_sMovieDrivers(
    "MovieDrivers", "");  // "" == default
/* Try drivers in order of preference until we find one that works. */
static LocalizedString MOVIE_DRIVERS_EMPTY(
    "Arch", "Movie Drivers cannot be empty.");
static LocalizedString COULDNT_CREATE_MOVIE_DRIVER(
    "Arch", "Couldn't create a movie driver.");
RageMovieTexture* RageMovieTexture::Create(RageTextureID ID) {
  DumpAVIDebugInfo(ID.filename);

  std::string sDrivers = g_sMovieDrivers;
  std::vector<std::string> DriversToTry;

  if (sDrivers.empty()) {
    DriversToTry = GetDefaultMovieDriverList();
  } else {
    DriversToTry = split(sDrivers, ',');
  }
  DriversToTry.erase(
      std::remove_if(
          DriversToTry.begin(), DriversToTry.end(),
          [](std::string& driver) {
            Trim(driver);
            return driver.empty();
          }),
      DriversToTry.end());

  if (DriversToTry.empty()) {
    if (LOG != nullptr) {
      LOG->Warn("%s", MOVIE_DRIVERS_EMPTY.GetValue().c_str());
    }
    return nullptr;
  }

  RageMovieTexture* ret = nullptr;

  for (const std::string& Driver : DriversToTry) {
    const char* driverString = Driver.c_str();
    if (LOG != nullptr) {
      LOG->Trace("Initializing driver: %s", driverString);
    }
    RageDriver* pDriverBase =
        RageMovieTextureDriver::m_pDriverList.Create(Driver);

    if (pDriverBase == nullptr) {
      if (LOG != nullptr) {
        LOG->Trace("Unknown movie driver name: %s", driverString);
      }
      continue;
    }

    RageMovieTextureDriver* pDriver =
        dynamic_cast<RageMovieTextureDriver*>(pDriverBase);
    if (pDriver == nullptr) {
      delete pDriverBase;
      continue;
    }

    std::string sError;
    ret = pDriver->Create(ID, sError);
    delete pDriver;

    if (ret == nullptr) {
      if (LOG != nullptr) {
        LOG->Trace("Couldn't load driver %s: %s", driverString, sError.c_str());
      }
      continue;
    }
    if (LOG != nullptr) {
      LOG->Trace(
          "Created movie texture \"%s\" with driver \"%s\"",
          ID.filename.c_str(), driverString);
    }
    break;
  }
  if (!ret) {
    if (LOG != nullptr) {
      LOG->Warn(
          "%s File: %s", COULDNT_CREATE_MOVIE_DRIVER.GetValue().c_str(),
          ID.filename.c_str());
    }
  }

  return ret;
}

/*
 * (c) 2003-2004 Glenn Maynard
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
