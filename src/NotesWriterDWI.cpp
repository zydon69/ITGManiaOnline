#include "NotesWriterDWI.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "Difficulty.h"
#include "GameConstantsAndTypes.h"
#include "NoteData.h"
#include "NoteDataUtil.h"
#include "NoteTypes.h"
#include "RageFile.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Song.h"
#include "Steps.h"
#include "TimingSegments.h"
#include "global.h"

std::string OptimizeDWIString(std::string holds, std::string taps);

/**
 * @brief Optimize an individual pair of characters whenever possible.
 * @param c1 the first character.
 * @param c2 the second character.
 * @return the one singular character. */
static bool OptimizeDWIPair(char c1, char c2, char& out) {
  typedef std::pair<char, char> cpair;
  static std::map<cpair, char> joins;
  static bool Initialized = false;
  if (!Initialized) {
    Initialized = true;
    /* The first character in the pair is always the lowest. */
    joins[cpair('2', '4')] = '1';
    joins[cpair('2', '6')] = '3';
    joins[cpair('4', '8')] = '7';
    joins[cpair('6', '8')] = '9';
    joins[cpair('2', '8')] = 'A';
    joins[cpair('4', '6')] = 'B';
    joins[cpair('C', 'D')] = 'M';
    joins[cpair('4', 'C')] = 'E';
    joins[cpair('2', 'C')] = 'F';
    joins[cpair('8', 'C')] = 'G';
    joins[cpair('6', 'C')] = 'H';
    joins[cpair('4', 'D')] = 'I';
    joins[cpair('2', 'D')] = 'J';
    joins[cpair('8', 'D')] = 'K';
    joins[cpair('6', 'D')] = 'L';
  }

  if (c1 > c2) {
    std::swap(c1, c2);
  }

  std::map<cpair, char>::const_iterator it = joins.find(cpair(c1, c2));
  if (it == joins.end()) {
    return false;
  }

  out = it->second;
  return true;
}

static bool WriteChecked(RageFile& f, const std::string& s) {
  return f.Write(s) == static_cast<int>(s.size());
}

static bool PutLineChecked(RageFile& f, const std::string& s) {
  return f.PutLine(s) != -1;
}

static bool FinishWrite(RageFile& f, const std::string& sPath) {
  if (f.Flush() == -1) {
    LOG->UserLog(
        "Song file", sPath, "couldn't be fully written: %s",
        f.GetError().c_str());
    return false;
  }
  return true;
}

/**
 * @brief Shrink the file contents as best as possible.
 * @param holds the holds in the file.
 * @param taps the taps in the file.
 * @return the optimized string. */
std::string OptimizeDWIString(std::string holds, std::string taps) {
  /* First, sort the holds and taps in ASCII order.  This puts 2468 first.
   * This way 1379 combinations will always be found first, so we'll always
   * do eg. 1D, not 2I. */
  sort(holds.begin(), holds.end());
  sort(taps.begin(), taps.end());

  /* Combine characters as much as possible. */
  std::string comb_taps, comb_holds;

  /* 24 -> 1 */
  while (taps.size() > 1) {
    char optimized = 0;
    if (!OptimizeDWIPair(taps[0], taps[1], optimized)) {
      break;
    }
    comb_taps += optimized;
    taps.erase(0, 2);
  }

  /* 2!24!4 -> 1!1 */
  while (holds.size() > 1) {
    char to = 0;
    if (!OptimizeDWIPair(holds[0], holds[1], to)) {
      break;
    }
    holds.erase(0, 2);
    comb_holds += ssprintf("%c!%c", to, to);
  }

  /* 24!4 -> 1!4 */
  while (holds.size() == 1 && taps.size() == 1) {
    char to = 0;
    if (OptimizeDWIPair(taps[0], holds[0], to)) {
      comb_holds += ssprintf("%c!%c", to, holds[0]);
      taps.erase(0, 1);
      holds.erase(0, 1);
    } else {
      break;
    }
  }

  /* Now we have at most one single tap and one hold remaining, and any
   * number of taps and holds in comb_taps and comb_holds. */
  std::string ret;
  ret += taps;
  ret += comb_taps;
  for (size_t i = 0; i < holds.size(); ++i) {
    ret += ssprintf("%c!%c", holds[i], holds[i]);
  }
  ret += comb_holds;

  if (ret.size() == 1 || (ret.size() == 3 && ret[1] == '!')) {
    return ret;
  } else {
    return ssprintf("<%s>", ret.c_str());
  }
}

/**
 * @brief Turn the Notes into a DWI string without angle brackets whenever
 * possible.
 * @param tnCols the columns of TapNotes in question.
 * @return the DWI'ed string. */
static std::string NotesToDWIString(const TapNote tnCols[6]) {
  const char dirs[] = {'4', 'C', '2', '8', 'D', '6'};
  std::string taps, holds, ret;
  for (int col = 0; col < 6; ++col) {
    switch (tnCols[col].type) {
      case TapNoteType_Empty:
      case TapNoteType_Mine:
        continue;
      default:
        break;
    }

    if (tnCols[col].type == TapNoteType_HoldHead) {
      holds += dirs[col];
    } else {
      taps += dirs[col];
    }
  }

  if (holds.size() + taps.size() == 0) {
    return "0";
  }

  /* More than one. */
  return OptimizeDWIString(holds, taps);
}

/**
 * @brief Turn the Notes into a DWI string without angle brackets whenever
 * possible.
 * @param tnCol1 the first column.
 * @param tnCol2 the second column.
 * @param tnCol3 the third column.
 * @param tnCol4 the fourth column.
 * @param tnCol5 the fifth column.
 * @param tnCol6 the sisth column.
 * @return the DWI'ed string. */
static std::string NotesToDWIString(
    TapNote tnCol1, TapNote tnCol2, TapNote tnCol3, TapNote tnCol4,
    TapNote tnCol5, TapNote tnCol6) {
  TapNote tnCols[6];
  tnCols[0] = tnCol1;
  tnCols[1] = tnCol2;
  tnCols[2] = tnCol3;
  tnCols[3] = tnCol4;
  tnCols[4] = tnCol5;
  tnCols[5] = tnCol6;
  return NotesToDWIString(tnCols);
}

/**
 * @brief Turn the Notes into a DWI string without angle brackets whenever
 * possible.
 * @param tnCol1 the first column.
 * @param tnCol2 the second column.
 * @param tnCol3 the third column.
 * @param tnCol4 the fourth column.
 * @return the DWI'ed string. */
static std::string NotesToDWIString(
    TapNote tnCol1, TapNote tnCol2, TapNote tnCol3, TapNote tnCol4) {
  return NotesToDWIString(tnCol1, TAP_EMPTY, tnCol2, tnCol3, TAP_EMPTY, tnCol4);
}

/** @brief The number of beats per measure for a DWI file. */
static const int BEATS_PER_MEASURE = 4;

/**
 * @brief Write out the notes for a DWI file.
 * @param f the file to write out to.
 * @param out the Steps in question.
 * @param start the starting position. */
static bool WriteDWINotesField(
    RageFile& f, const Steps& out, int start, const std::string& sPath) {
  NoteData notedata;
  out.GetNoteData(notedata);
  NoteDataUtil::InsertHoldTails(notedata);

  const int iLastMeasure = int(notedata.GetLastBeat() / BEATS_PER_MEASURE);
  for (int m = 0; m <= iLastMeasure; m++)  // foreach measure
  {
    NoteType nt = NoteDataUtil::GetSmallestNoteTypeForMeasure(notedata, m);

    double fCurrentIncrementer = 0;
    switch (nt) {
      case NOTE_TYPE_4TH:
      case NOTE_TYPE_8TH:
        fCurrentIncrementer = 1.0 / 8 * BEATS_PER_MEASURE;
        break;
      case NOTE_TYPE_12TH:
      case NOTE_TYPE_24TH:
        fCurrentIncrementer = 1.0 / 24 * BEATS_PER_MEASURE;
        break;
      case NOTE_TYPE_16TH:
        fCurrentIncrementer = 1.0 / 16 * BEATS_PER_MEASURE;
        break;
      case NOTE_TYPE_32ND:
      case NOTE_TYPE_64TH:
        fCurrentIncrementer = 1.0 / 64 * BEATS_PER_MEASURE;
        break;
      case NOTE_TYPE_48TH:
      case NOTE_TYPE_192ND:
      case NoteType_Invalid:
        // since, for whatever reason, the only way to do
        // 48ths is through a block of 192nds...
        if (!WriteChecked(f, "`")) {
          return false;
        }
        fCurrentIncrementer = 1.0 / 192 * BEATS_PER_MEASURE;
        break;
      default:
        LOG->UserLog(
            "Song file", sPath,
            "cannot export DWI chart with unsupported note type "
            "%d.",
            nt);
        return false;
    }

    switch (nt) {
      case NOTE_TYPE_12TH:
      case NOTE_TYPE_24TH:
        if (!WriteChecked(f, "[")) {
          return false;
        }
        break;
      case NOTE_TYPE_16TH:
        if (!WriteChecked(f, "(")) {
          return false;
        }
        break;
      case NOTE_TYPE_32ND:
      case NOTE_TYPE_64TH:
        if (!WriteChecked(f, "{")) {
          return false;
        }
        break;
      default:
        break;
    }

    double fFirstBeatInMeasure = m * BEATS_PER_MEASURE;
    double fLastBeatInMeasure = (m + 1) * BEATS_PER_MEASURE;

    for (double b = fFirstBeatInMeasure; b <= fLastBeatInMeasure - 1 / 64.0f;
         b += fCurrentIncrementer)  // need the -0.0001 to account for rounding
                                    // errors
    {
      int row = BeatToNoteRow((float)b);

      std::string str;
      switch (out.m_StepsType) {
        case StepsType_dance_single:
        case StepsType_dance_couple:
        case StepsType_dance_double:
          str = NotesToDWIString(
              notedata.GetTapNote(start + 0, row),
              notedata.GetTapNote(start + 1, row),
              notedata.GetTapNote(start + 2, row),
              notedata.GetTapNote(start + 3, row));

          // Blank out the notes so we don't write them again if the incrementer
          // is small
          notedata.SetTapNote(start + 0, row, TAP_EMPTY);
          notedata.SetTapNote(start + 1, row, TAP_EMPTY);
          notedata.SetTapNote(start + 2, row, TAP_EMPTY);
          notedata.SetTapNote(start + 3, row, TAP_EMPTY);
          break;
        case StepsType_dance_solo:
          str = NotesToDWIString(
              notedata.GetTapNote(0, row), notedata.GetTapNote(1, row),
              notedata.GetTapNote(2, row), notedata.GetTapNote(3, row),
              notedata.GetTapNote(4, row), notedata.GetTapNote(5, row));

          // Blank out the notes so we don't write them again if the incrementer
          // is small
          notedata.SetTapNote(start + 0, row, TAP_EMPTY);
          notedata.SetTapNote(start + 1, row, TAP_EMPTY);
          notedata.SetTapNote(start + 2, row, TAP_EMPTY);
          notedata.SetTapNote(start + 3, row, TAP_EMPTY);
          notedata.SetTapNote(start + 4, row, TAP_EMPTY);
          notedata.SetTapNote(start + 5, row, TAP_EMPTY);
          break;
        default:
          LOG->UserLog(
              "Song file", sPath,
              "cannot export unsupported DWI StepsType %i.",
              out.m_StepsType);
          return false;
      }
      if (!WriteChecked(f, str)) {
        return false;
      }
    }

    switch (nt) {
      case NOTE_TYPE_4TH:
      case NOTE_TYPE_8TH:
        break;
      case NOTE_TYPE_12TH:
      case NOTE_TYPE_24TH:
        if (!WriteChecked(f, "]")) {
          return false;
        }
        break;
      case NOTE_TYPE_16TH:
        if (!WriteChecked(f, ")")) {
          return false;
        }
        break;
      case NOTE_TYPE_32ND:
      case NOTE_TYPE_64TH:
        if (!WriteChecked(f, "}")) {
          return false;
        }
        break;
      case NOTE_TYPE_48TH:
      case NOTE_TYPE_192ND:
      case NoteType_Invalid:
        if (!WriteChecked(f, "'")) {
          return false;
        }
        break;
      default:
        LOG->UserLog(
            "Song file", sPath,
            "cannot close DWI chart block with unsupported note "
            "type %i.",
            nt);
        return false;
    }
    if (!PutLineChecked(f, "")) {
      return false;
    }
  }
  return true;
}

/**
 * @brief Attempt to write a DWI's #NOTES tag.
 * @param f the file to write out to.
 * @param out the Steps in question.
 * @return its success or failure. */
static bool WriteDWINotesTag(
    RageFile& f, const Steps& out, const std::string& sPath) {
  if (out.GetDifficulty() == Difficulty_Edit) {
    return false;  // not supported by DWI
  }

  LOG->Trace("Steps::WriteDWINotesTag");

  switch (out.m_StepsType) {
    case StepsType_dance_single:
      if (!WriteChecked(f, "#SINGLE:")) {
        return false;
      }
      break;
    case StepsType_dance_couple:
      if (!WriteChecked(f, "#COUPLE:")) {
        return false;
      }
      break;
    case StepsType_dance_double:
      if (!WriteChecked(f, "#DOUBLE:")) {
        return false;
      }
      break;
    case StepsType_dance_solo:
      break;
    default:
      return false;
  }

  Difficulty d = out.GetDifficulty();
  switch (d) {
    case Difficulty_Beginner:
      if (!WriteChecked(f, "BEGINNER:")) {
        return false;
      }
      break;
    case Difficulty_Easy:
      if (!WriteChecked(f, "BASIC:")) {
        return false;
      }
      break;
    case Difficulty_Medium:
      if (!WriteChecked(f, "ANOTHER:")) {
        return false;
      }
      break;
    case Difficulty_Hard:
      if (!WriteChecked(f, "MANIAC:")) {
        return false;
      }
      break;
    case Difficulty_Challenge:
      if (!WriteChecked(f, "SMANIAC:")) {
        return false;
      }
      break;
    default:
      LOG->UserLog(
          "Song file", sPath,
          "cannot export DWI chart with invalid difficulty %i.",
          d);
      return false;
  }

  return PutLineChecked(f, ssprintf("%d:", out.GetMeter()));
}

bool NotesWriterDWI::Write(std::string sPath, const Song& out) {
  RageFile f;
  if (!f.Open(sPath, RageFile::WRITE)) {
    LOG->UserLog(
        "Song file", sPath, "couldn't be opened for writing: %s",
        f.GetError().c_str());
    return false;
  }

  /* Write transliterations, if we have them, since DWI doesn't support UTF-8.
   */
  if (!PutLineChecked(
          f,
          ssprintf("#TITLE:%s;", DwiEscape(out.GetTranslitFullTitle()).c_str())) ||
      !PutLineChecked(
          f,
          ssprintf("#ARTIST:%s;", DwiEscape(out.GetTranslitArtist()).c_str()))) {
    LOG->UserLog(
        "Song file", sPath, "couldn't be written: %s", f.GetError().c_str());
    return false;
  }

  const std::vector<TimingSegment*>& bpms =
      out.m_SongTiming.GetTimingSegments(SEGMENT_BPM);
  if (bpms.empty()) {
    LOG->UserLog(
        "Song file", sPath,
        "cannot export DWI without a BPM segment.");
    return false;
  }

  const BPMSegment* firstBPM = static_cast<BPMSegment*>(bpms[0]);
  if (firstBPM->GetRow() != 0 || !std::isfinite(firstBPM->GetBPM()) ||
      firstBPM->GetBPM() <= 0.0f) {
    LOG->UserLog(
        "Song file", sPath,
        "cannot export DWI with invalid initial BPM row %i, BPM "
        "%f.",
        firstBPM->GetRow(), firstBPM->GetBPM());
    return false;
  }

  if (!PutLineChecked(f, ssprintf("#FILE:%s;", DwiEscape(out.m_sMusicFile).c_str())) ||
      !PutLineChecked(f, ssprintf("#BPM:%.3f;", firstBPM->GetBPM())) ||
      !PutLineChecked(
          f, ssprintf(
                 "#GAP:%ld;",
                 -std::lrint(
                     out.m_SongTiming.m_fBeat0OffsetInSeconds * 1000))) ||
      !PutLineChecked(
          f, ssprintf("#SAMPLESTART:%.3f;", out.m_fMusicSampleStartSeconds)) ||
      !PutLineChecked(
          f, ssprintf("#SAMPLELENGTH:%.3f;", out.m_fMusicSampleLengthSeconds))) {
    LOG->UserLog(
        "Song file", sPath, "couldn't be written: %s", f.GetError().c_str());
    return false;
  }
  if (out.m_sCDTitleFile.size()) {
    if (!PutLineChecked(
            f,
            ssprintf("#CDTITLE:%s;", DwiEscape(out.m_sCDTitleFile).c_str()))) {
      LOG->UserLog(
          "Song file", sPath, "couldn't be written: %s", f.GetError().c_str());
      return false;
    }
  }
  switch (out.m_DisplayBPMType) {
    case DISPLAY_BPM_ACTUAL:
      // write nothing
      break;
    case DISPLAY_BPM_SPECIFIED:
      if (out.m_fSpecifiedBPMMin == out.m_fSpecifiedBPMMax) {
        if (!PutLineChecked(
                f,
                ssprintf("#DISPLAYBPM:%i;", (int)out.m_fSpecifiedBPMMin))) {
          return false;
        }
      } else {
        if (!PutLineChecked(
                f,
                ssprintf(
                    "#DISPLAYBPM:%i..%i;", (int)out.m_fSpecifiedBPMMin,
                    (int)out.m_fSpecifiedBPMMax))) {
          return false;
        }
      }
      break;
    case DISPLAY_BPM_RANDOM:
      if (!PutLineChecked(f, "#DISPLAYBPM:*;")) {
        return false;
      }
      break;
    default:
      break;
  }

  // TODO: Also check for delays, add them as stops minus one row?
  const std::vector<TimingSegment*>& stops =
      out.m_SongTiming.GetTimingSegments(SEGMENT_STOP);
  if (!stops.empty()) {
    bool wroteFreeze = false;

    for (unsigned i = 0; i < stops.size(); i++) {
      const StopSegment* fs = static_cast<StopSegment*>(stops[i]);
      if (fs->GetRow() < 0 || !std::isfinite(fs->GetPause()) ||
          fs->GetPause() <= 0.0f) {
        LOG->UserLog(
            "Song file", sPath,
            "skipped invalid DWI stop at row %i, seconds %f.",
            fs->GetRow(), fs->GetPause());
        continue;
      }
      if (!wroteFreeze && !WriteChecked(f, "#FREEZE:")) {
        return false;
      }
      if (wroteFreeze && !WriteChecked(f, ",")) {
        return false;
      }
      if (!WriteChecked(
              f, ssprintf(
                     "%.3f=%.3f", fs->GetRow() * 4.0f / ROWS_PER_BEAT,
                     std::round(fs->GetPause() * 1000)))) {
        return false;
      }
      wroteFreeze = true;
    }
    if (wroteFreeze && !PutLineChecked(f, ";")) {
      return false;
    }
  }

  if (bpms.size() > 1) {
    bool wroteBPMChange = false;
    for (unsigned i = 1; i < bpms.size(); i++) {
      const BPMSegment* bs = static_cast<BPMSegment*>(bpms[i]);
      if (bs->GetRow() < 0 || !std::isfinite(bs->GetBPM()) ||
          bs->GetBPM() <= 0.0f) {
        LOG->UserLog(
            "Song file", sPath,
            "skipped invalid DWI BPM change at row %i, BPM %f.",
            bs->GetRow(), bs->GetBPM());
        continue;
      }
      if (!wroteBPMChange && !WriteChecked(f, "#CHANGEBPM:")) {
        return false;
      }
      if (wroteBPMChange && !WriteChecked(f, ",")) {
        return false;
      }
      if (!WriteChecked(
              f, ssprintf(
                     "%.3f=%.3f", bs->GetRow() * 4.0f / ROWS_PER_BEAT,
                     bs->GetBPM()))) {
        return false;
      }
      wroteBPMChange = true;
    }
    if (wroteBPMChange && !PutLineChecked(f, ";")) {
      return false;
    }
  }

  const std::vector<Steps*>& vpSteps = out.GetAllSteps();
  for (unsigned i = 0; i < vpSteps.size(); i++) {
    const Steps* pSteps = vpSteps[i];
    if (pSteps->IsAutogen()) {
      continue;  // don't save autogen notes
    }

    if (!WriteDWINotesTag(f, *pSteps, sPath)) {
      continue;
    }

    if (!WriteDWINotesField(f, *pSteps, 0, sPath)) {
      return false;
    }
    if (pSteps->m_StepsType == StepsType_dance_double ||
        pSteps->m_StepsType == StepsType_dance_couple) {
      if (!PutLineChecked(f, ":") ||
          !WriteDWINotesField(f, *pSteps, 4, sPath)) {
        return false;
      }
    }

    if (!PutLineChecked(f, ";")) {
      return false;
    }
  }

  if (f.GetError() != "") {
    LOG->UserLog(
        "Song file", sPath, "couldn't be written: %s", f.GetError().c_str());
    return false;
  }

  return FinishWrite(f, sPath);
}

/*
 * (c) 2001-2006 Chris Danford, Glenn Maynard
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
