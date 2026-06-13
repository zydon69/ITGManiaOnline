#include "NotesWriterSM.h"

#include <cerrno>
#include <cmath>
#include <cstring>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "BackgroundUtil.h"
#include "Difficulty.h"
#include "GameConstantsAndTypes.h"
#include "LocalizedString.h"
#include "NoteTypes.h"
#include "PlayerNumber.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RadarValues.h"
#include "RageFile.h"
#include "RageFileManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Song.h"
#include "Steps.h"
#include "ThemeMetric.h"
#include "TimingData.h"
#include "TimingSegments.h"
#include "global.h"

ThemeMetric<bool> USE_CREDIT("NotesWriterSM", "DescriptionUsesCreditField");

namespace {
class CheckedFileWriter {
 public:
  CheckedFileWriter(RageFileBasic& file, const char* context)
    : m_file(file), m_context(context), m_failed(false) {}

  int Write(const std::string& s) {
    if (m_failed) {
      return -1;
    }
    const int ret = m_file.Write(s);
    Record(ret);
    return ret;
  }

  int PutLine(const std::string& s) {
    if (m_failed) {
      return -1;
    }
    const int ret = m_file.PutLine(s);
    Record(ret);
    return ret;
  }

  int Flush() {
    if (m_failed) {
      return -1;
    }
    const int ret = m_file.Flush();
    Record(ret);
    return ret;
  }

  bool Failed() const { return m_failed; }
  std::string GetError() const { return m_file.GetError(); }

 private:
  void Record(int ret) {
    if (ret != -1) {
      return;
    }
    m_failed = true;
    LOG->Warn(
        "SRC_AUDIT_FIX: %s write failed: %s", m_context,
        m_file.GetError().c_str());
  }

  RageFileBasic& m_file;
  const char* m_context;
  bool m_failed;
};

static std::string SanitizeKeysoundForWrite(
    const std::string& file, const char* format) {
  std::string sanitized = file;
  bool changed = false;
  for (char& c : sanitized) {
    if (c == ',' || c == ';' || c == ':' || c == '\r' || c == '\n') {
      c = ' ';
      changed = true;
    }
  }
  if (!sanitized.empty() && sanitized[0] == '#') {
    sanitized.insert(sanitized.begin(), '\\');
    changed = true;
  }
  if (changed) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-584 SRC-593: sanitized %s keysound filename "
        "containing MSD delimiters.",
        format);
  }
  return SmEscape(sanitized);
}

static std::string SanitizeAttackStringForWrite(
    const std::string& attacks, const char* format) {
  std::string sanitized = attacks;
  bool changed = false;
  for (char& c : sanitized) {
    if (c == ';' || c == '\r' || c == '\n') {
      c = ' ';
      changed = true;
    }
  }
  if (changed) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-585 SRC-594: sanitized %s attack string "
        "containing MSD tag delimiters.",
        format);
  }
  return sanitized;
}

static std::string SanitizeStepMetadataForWrite(
    const std::string& value, const char* format) {
  std::string sanitized = value;
  bool changed = false;
  for (char& c : sanitized) {
    if (c == ':' || c == ';' || c == '\r' || c == '\n') {
      c = ' ';
      changed = true;
    }
  }
  if (changed) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-586 SRC-595: sanitized %s step metadata "
        "containing MSD delimiters.",
        format);
  }
  return SmEscape(sanitized);
}

static DisplayBPM SanitizeDisplayBPMForWrite(
    const Song& song, float& minBPM, float& maxBPM, const char* format) {
  minBPM = song.m_fSpecifiedBPMMin;
  maxBPM = song.m_fSpecifiedBPMMax;
  switch (song.m_DisplayBPMType) {
    case DISPLAY_BPM_ACTUAL:
    case DISPLAY_BPM_RANDOM:
      return song.m_DisplayBPMType;
    case DISPLAY_BPM_SPECIFIED:
      break;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-587 SRC-596: invalid %s DisplayBPM type %i for "
          "'%s'; falling back to actual.",
          format, song.m_DisplayBPMType, song.GetSongDir().c_str());
      return DISPLAY_BPM_ACTUAL;
  }

  if (!std::isfinite(minBPM) || !std::isfinite(maxBPM) || minBPM <= 0.0f ||
      maxBPM <= 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-587 SRC-596: invalid %s specified DisplayBPM "
        "%.6f:%.6f for '%s'; falling back to actual.",
        format, minBPM, maxBPM, song.GetSongDir().c_str());
    return DISPLAY_BPM_ACTUAL;
  }

  if (minBPM > maxBPM) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-587 SRC-596: swapped inverted %s DisplayBPM range "
        "%.6f:%.6f for '%s'.",
        format, minBPM, maxBPM, song.GetSongDir().c_str());
    std::swap(minBPM, maxBPM);
  }
  return DISPLAY_BPM_SPECIFIED;
}
}  // namespace

/**
 * @brief Write out the common tags for .SM files.
 * @param f the file in question.
 * @param out the Song in question. */
static bool WriteGlobalTags(CheckedFileWriter& f, Song& out) {
  TimingData& timing = out.m_SongTiming;
  f.PutLine(ssprintf("#TITLE:%s;", SmEscape(out.m_sMainTitle).c_str()));
  f.PutLine(ssprintf("#SUBTITLE:%s;", SmEscape(out.m_sSubTitle).c_str()));
  f.PutLine(ssprintf("#ARTIST:%s;", SmEscape(out.m_sArtist).c_str()));
  f.PutLine(ssprintf(
      "#TITLETRANSLIT:%s;", SmEscape(out.m_sMainTitleTranslit).c_str()));
  f.PutLine(ssprintf(
      "#SUBTITLETRANSLIT:%s;", SmEscape(out.m_sSubTitleTranslit).c_str()));
  f.PutLine(
      ssprintf("#ARTISTTRANSLIT:%s;", SmEscape(out.m_sArtistTranslit).c_str()));
  f.PutLine(ssprintf("#GENRE:%s;", SmEscape(out.m_sGenre).c_str()));
  f.PutLine(ssprintf("#CREDIT:%s;", SmEscape(out.m_sCredit).c_str()));
  f.PutLine(ssprintf("#BANNER:%s;", SmEscape(out.m_sBannerFile).c_str()));
  f.PutLine(
      ssprintf("#BACKGROUND:%s;", SmEscape(out.m_sBackgroundFile).c_str()));
  f.PutLine(ssprintf("#LYRICSPATH:%s;", SmEscape(out.m_sLyricsFile).c_str()));
  f.PutLine(ssprintf("#CDTITLE:%s;", SmEscape(out.m_sCDTitleFile).c_str()));
  f.PutLine(ssprintf("#MUSIC:%s;", SmEscape(out.m_sMusicFile).c_str()));
  f.PutLine(
      ssprintf("#OFFSET:%.6f;", out.m_SongTiming.m_fBeat0OffsetInSeconds));
  f.PutLine(ssprintf("#SAMPLESTART:%.6f;", out.m_fMusicSampleStartSeconds));
  f.PutLine(ssprintf("#SAMPLELENGTH:%.6f;", out.m_fMusicSampleLengthSeconds));
  float specBeat = out.GetSpecifiedLastBeat();
  if (specBeat > 0) {
    f.PutLine(ssprintf("#LASTBEATHINT:%.6f;", specBeat));
  }

  f.Write("#SELECTABLE:");
  switch (out.m_SelectionDisplay) {
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX: Invalid SM selection display %i while writing '%s'; "
          "falling back to YES.",
          out.m_SelectionDisplay, out.GetSongDir().c_str());
      f.Write("YES");
      break;
    case Song::SHOW_ALWAYS:
      f.Write("YES");
      break;
      // case Song::SHOW_NONSTOP:	f.Write( "NONSTOP" );	break;
    case Song::SHOW_NEVER:
      f.Write("NO");
      break;
  }
  f.PutLine(";");

  float displayBPMMin = 0.0f;
  float displayBPMMax = 0.0f;
  switch (SanitizeDisplayBPMForWrite(
      out, displayBPMMin, displayBPMMax, "SM")) {
    case DISPLAY_BPM_ACTUAL:
      // write nothing
      break;
    case DISPLAY_BPM_SPECIFIED:
      if (displayBPMMin == displayBPMMax) {
        f.PutLine(ssprintf("#DISPLAYBPM:%.6f;", displayBPMMin));
      } else {
        f.PutLine(ssprintf(
            "#DISPLAYBPM:%.6f:%.6f;", displayBPMMin, displayBPMMax));
      }
      break;
    case DISPLAY_BPM_RANDOM:
      f.PutLine(ssprintf("#DISPLAYBPM:*;"));
      break;
    default:
      break;
  }

  f.Write("#BPMS:");
  const std::vector<TimingSegment*>& bpms =
      timing.GetTimingSegments(SEGMENT_BPM);
  for (unsigned i = 0; i < bpms.size(); i++) {
    const BPMSegment* bs = ToBPM(bpms[i]);

    f.PutLine(ssprintf("%.6f=%.6f", bs->GetBeat(), bs->GetBPM()));
    if (i != bpms.size() - 1) {
      f.Write(",");
    }
  }
  if (bpms.empty()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SM writer provided fallback BPM for '%s' because "
        "TimingData had no BPM segments.",
        out.GetSongDir().c_str());
    f.PutLine("0.000000=60.000000");
  }
  f.PutLine(";");

  const std::vector<TimingSegment*>& stops =
      timing.GetTimingSegments(SEGMENT_STOP);
  const std::vector<TimingSegment*>& delays =
      timing.GetTimingSegments(SEGMENT_DELAY);

  std::map<float, float> allPauses;
  const std::vector<TimingSegment*>& warps =
      timing.GetTimingSegments(SEGMENT_WARP);
  unsigned wSize = warps.size();
  if (wSize > 0) {
    for (unsigned i = 0; i < wSize; i++) {
      const WarpSegment* ws = static_cast<WarpSegment*>(warps[i]);
      int iRow = ws->GetRow();
      float fBPM = out.m_SongTiming.GetBPMAtRow(iRow);
      if (!std::isfinite(fBPM) || fBPM <= 0.0f) {
        LOG->Warn(
            "SRC_AUDIT_FIX: SM writer skipped warp-to-stop conversion at beat "
            "%.6f for '%s' because BPM %.6f is invalid.",
            ws->GetBeat(), out.GetSongDir().c_str(), fBPM);
        continue;
      }
      float fBPS = 60.0f / fBPM;
      float fSkip = fBPS * ws->GetLength();
      allPauses.insert(std::pair<float, float>(ws->GetBeat(), -fSkip));
    }
  }

  for (unsigned i = 0; i < stops.size(); i++) {
    const StopSegment* fs = ToStop(stops[i]);
    // Handle warps on the same row by summing the values.  Not sure this
    // plays out the same. -Kyz
    std::map<float, float>::iterator already_exists =
        allPauses.find(fs->GetBeat());
    if (already_exists != allPauses.end()) {
      already_exists->second += fs->GetPause();
    } else {
      allPauses.insert(std::pair<float, float>(fs->GetBeat(), fs->GetPause()));
    }
  }
  // Delays can't be negative: thus, no effect.
  for (const TimingSegment* ss : delays) {
    int iRow = ss->GetRow();
    if (iRow <= 0) {
      LOG->Warn(
          "SRC_AUDIT_FIX: SM writer clamped delay at row %i to beat 0 for '%s' "
          "to avoid serializing a negative stop beat.",
          iRow, out.GetSongDir().c_str());
      iRow = 1;
    }
    float fBeat = NoteRowToBeat(iRow - 1);
    float fPause = ToDelay(ss)->GetPause();
    std::map<float, float>::iterator already_exists = allPauses.find(fBeat);
    if (already_exists != allPauses.end()) {
      already_exists->second += fPause;
    } else {
      allPauses.insert(std::pair<float, float>(fBeat, fPause));
    }
  }

  f.Write("#STOPS:");
  std::vector<std::string> stopLines;
  for (std::pair<const float&, const float&> ap : allPauses) {
    stopLines.push_back(ssprintf("%.6f=%.6f", ap.first, ap.second));
  }
  f.PutLine(join(",\n", stopLines));

  f.PutLine(";");

  FOREACH_BackgroundLayer(b) {
    if (b == 0) {
      f.Write("#BGCHANGES:");
    } else if (out.GetBackgroundChanges(b).empty()) {
      continue;  // skip
    } else {
      f.Write(ssprintf("#BGCHANGES%d:", b + 1));
    }

    for (const BackgroundChange& bgc : out.GetBackgroundChanges(b)) {
      f.PutLine(bgc.ToString() + ",");
    }

    /* If there's an animation plan at all, add a dummy "-nosongbg-" tag to
     * indicate that this file doesn't want a song BG entry added at the end.
     * See SMLoader::TidyUpData. This tag will be removed on load.  Add it at a
     * very high beat, so it won't cause problems if loaded in older versions.
     */
    if (b == 0 && !out.GetBackgroundChanges(b).empty()) {
      f.PutLine(
          "99999=-nosongbg-=1.000=0=0=0 // don't automatically add "
          "-songbackground-");
    }
    f.PutLine(";");
  }

  if (out.GetForegroundChanges().size()) {
    f.Write("#FGCHANGES:");
    for (const BackgroundChange& bgc : out.GetForegroundChanges()) {
      f.PutLine(bgc.ToString() + ",");
    }
    f.PutLine(";");
  }

  f.Write("#KEYSOUNDS:");
  for (unsigned i = 0; i < out.m_vsKeysoundFile.size(); i++) {
    f.Write(SanitizeKeysoundForWrite(out.m_vsKeysoundFile[i], "SM"));
    if (i != out.m_vsKeysoundFile.size() - 1) {
      f.Write(",");
    }
  }
  f.PutLine(";");

  f.PutLine(ssprintf(
      "#ATTACKS:%s;",
      SanitizeAttackStringForWrite(out.GetAttackString(), "SM song").c_str()));
  return !f.Failed();
}

/**
 * @brief Turn a vector of lines into a single line joined by newline
 * characters.
 * @param lines the list of lines to join.
 * @return the joined lines. */
static std::string JoinLineList(std::vector<std::string>& lines) {
  for (unsigned i = 0; i < lines.size(); ++i) {
    TrimRight(lines[i]);
  }

  /* Skip leading blanks. */
  unsigned j = 0;
  while (j < lines.size() && lines[j].empty()) {
    ++j;
  }
  if (j > 0) {
    LOG->Trace(
        "SRC_AUDIT_FIX: NotesWriterSM stripped %u leading blank note lines.",
        j);
  }

  return join("\r\n", lines.begin() + j, lines.end());
}

/**
 * @brief Retrieve the notes from the #NOTES tag.
 * @param song the Song in question.
 * @param in the Steps in question.
 * @return the #NOTES tag. */
static std::string GetSMNotesTag(const Song& song, const Steps& in) {
  std::vector<std::string> lines;

  lines.push_back("");
  // Escape to prevent some clown from making a comment of "\r\n;"
  lines.push_back(ssprintf(
      "//---------------%s - %s----------------",
      SanitizeStepMetadataForWrite(in.m_StepsTypeStr, "SM comment").c_str(),
      SmEscape(in.GetDescription()).c_str()));
  lines.push_back(song.m_vsKeysoundFile.empty() ? "#NOTES:" : "#NOTES2:");
  lines.push_back(ssprintf(
      "     %s:",
      SanitizeStepMetadataForWrite(in.m_StepsTypeStr, "SM NOTES").c_str()));
  std::string desc = (USE_CREDIT ? in.GetCredit() : in.GetChartName());
  lines.push_back(ssprintf("     %s:", SmEscape(desc).c_str()));
  lines.push_back(
      ssprintf("     %s:", DifficultyToString(in.GetDifficulty()).c_str()));
  lines.push_back(ssprintf("     %d:", in.GetMeter()));

  std::vector<std::string> asRadarValues;
  // OpenITG simfiles use 11 radar categories.
  int categories = 11;
  FOREACH_PlayerNumber(pn) {
    const RadarValues& rv = in.GetRadarValues(pn);
    // Can't use the foreach anymore due to flexible radar lines.
    for (RadarCategory rc = (RadarCategory)0; rc < categories;
         enum_add<RadarCategory>(rc, 1)) {
      asRadarValues.push_back(ssprintf("%.6f", rv[rc]));
    }
  }
  lines.push_back(ssprintf("     %s:", join(",", asRadarValues).c_str()));

  std::string sNoteData;
  in.GetSMNoteData(sNoteData);

  split(sNoteData, "\n", lines, true);
  lines.push_back(";");

  return JoinLineList(lines);
}

bool NotesWriterSM::Write(
    std::string sPath, Song& out, const std::vector<Steps*>& vpStepsToSave) {
  int flags = RageFile::WRITE;

  flags |= RageFile::SLOW_FLUSH;

  RageFile f;
  if (!f.Open(sPath, flags)) {
    LOG->UserLog(
        "Song file", sPath, "couldn't be opened for writing: %s",
        f.GetError().c_str());
    return false;
  }

  return Write(f, out, vpStepsToSave);
}

bool NotesWriterSM::Write(
    RageFileBasic& f, Song& out, const std::vector<Steps*>& vpStepsToSave) {
  CheckedFileWriter writer(f, "NotesWriterSM");
  if (!WriteGlobalTags(writer, out)) {
    return false;
  }

  for (const Steps* pSteps : vpStepsToSave) {
    std::string sTag = GetSMNotesTag(out, *pSteps);
    writer.PutLine(sTag);
  }
  if (writer.Flush() == -1) {
    return false;
  }

  return true;
}

void NotesWriterSM::GetEditFileContents(
    const Song* pSong, const Steps* pSteps, std::string& sOut) {
  sOut = "";
  std::string sDir = pSong->GetSongDir();

  // "Songs/foo/bar"; strip off "Songs/".
  std::vector<std::string> asParts;
  split(sDir, "/", asParts);
  if (asParts.size()) {
    sDir = join("/", asParts.begin() + 1, asParts.end());
  }
  sOut += ssprintf("#SONG:%s;\r\n", SmEscape(sDir).c_str());
  sOut += GetSMNotesTag(*pSong, *pSteps);
}

std::string NotesWriterSM::GetEditFileName(
    const Song* pSong, const Steps* pSteps) {
  /* Try to make a unique name. This isn't guaranteed. Edit descriptions are
   * case-sensitive, filenames on disk are usually not, and we decimate certain
   * characters for FAT filesystems. */
  std::string sFile =
      pSong->GetTranslitFullTitle() + " - " + pSteps->GetDescription();

  // HACK:
  if (pSteps->m_StepsType == StepsType_dance_double) {
    sFile += " (doubles)";
  }

  sFile += ".edit";

  MakeValidFilename(sFile);
  return sFile;
}

static LocalizedString DESTINATION_ALREADY_EXISTS(
    "NotesWriterSM",
    "Error renaming file.  Destination file '%s' already exists.");
static LocalizedString ERROR_WRITING_FILE(
    "NotesWriterSM", "Error writing file '%s'.");
bool NotesWriterSM::WriteEditFileToMachine(
    const Song* pSong, Steps* pSteps, std::string& sErrorOut) {
  std::string sDir =
      PROFILEMAN->GetProfileDir(ProfileSlot_Machine) + EDIT_STEPS_SUBDIR;

  std::string sPath = sDir + GetEditFileName(pSong, pSteps);

  // Check to make sure that we're not clobering an existing file before
  // opening.
  bool bFileNameChanging =
      pSteps->GetSavedToDisk() && pSteps->GetFilename() != sPath;
  if (bFileNameChanging && DoesFileExist(sPath)) {
    sErrorOut =
        ssprintf(DESTINATION_ALREADY_EXISTS.GetValue().c_str(), sPath.c_str());
    return false;
  }

  RageFile f;
  if (!f.Open(sPath, RageFile::WRITE | RageFile::SLOW_FLUSH)) {
    sErrorOut = ssprintf(ERROR_WRITING_FILE.GetValue().c_str(), sPath.c_str());
    return false;
  }

  std::string sTag;
  GetEditFileContents(pSong, pSteps, sTag);
  if (f.PutLine(sTag) == -1 || f.Flush() == -1) {
    sErrorOut = ssprintf(ERROR_WRITING_FILE.GetValue().c_str(), sPath.c_str());
    return false;
  }

  /* If the file name of the edit has changed since the last save, then delete
   * the old file after saving the new one. If we delete it first, then we'll
   * lose data on error. */

  if (bFileNameChanging) {
    if (!FILEMAN->Remove(pSteps->GetFilename()) &&
        DoesFileExist(pSteps->GetFilename())) {
      sErrorOut = ssprintf(
          "Error removing old edit file '%s'.",
          pSteps->GetFilename().c_str());
      LOG->Warn(
          "SRC_AUDIT_FIX: Failed to remove old SM edit file '%s' after writing "
          "'%s'.",
          pSteps->GetFilename().c_str(), sPath.c_str());
      return false;
    }
  }
  pSteps->SetFilename(sPath);

  return true;
}

/*
 * (c) 2001-2004 Chris Danford, Glenn Maynard
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
