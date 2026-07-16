#include "NotesWriterSSC.h"

#include <cerrno>
#include <cmath>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "Attack.h"
#include "BackgroundUtil.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "LocalizedString.h"
#include "NoteAnnotation.h"
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
#include "StdString.h"
#include "Steps.h"
#include "TechCounts.h"
#include "TimingData.h"
#include "TimingSegments.h"
#include "global.h"

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

static std::string SanitizeSSCLabelForWrite(const std::string& label) {
  std::string sanitized = label;
  bool changed = false;
  for (char& c : sanitized) {
    if (c == ',' || c == '=' || c == '\r' || c == '\n') {
      c = ' ';
      changed = true;
    }
  }
  if (changed) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SSC writer sanitized a timing label containing a "
        "#LABELS delimiter.");
  }
  return SmEscape(sanitized);
}

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

static std::string SanitizeAttackModifiersForWrite(
    const std::string& modifiers, const char* format) {
  std::string sanitized = modifiers;
  bool changed = false;
  for (char& c : sanitized) {
    if (c == ':' || c == ';' || c == '\r' || c == '\n') {
      c = ' ';
      changed = true;
    }
  }
  if (changed) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-585 SRC-594: sanitized %s attack modifiers "
        "containing MSD delimiters.",
        format);
  }
  return sanitized;
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

static bool IsValidTimingRowForWrite(
    int row, const char* format, const char* segment) {
  if (row >= 0) {
    return true;
  }
  LOG->Warn(
      "SRC_AUDIT_FIX SRC-588 SRC-597: skipped %s %s timing segment at "
      "negative row %i.",
      format, segment, row);
  return false;
}

static bool IsFiniteTimingValueForWrite(
    float value, const char* format, const char* segment,
    const char* valueName) {
  if (std::isfinite(value)) {
    return true;
  }
  LOG->Warn(
      "SRC_AUDIT_FIX SRC-588 SRC-597: skipped %s %s timing segment with "
      "non-finite %s %.6f.",
      format, segment, valueName, value);
  return false;
}

static bool IsPositiveTimingValueForWrite(
    float value, const char* format, const char* segment,
    const char* valueName) {
  if (IsFiniteTimingValueForWrite(value, format, segment, valueName) &&
      value > 0.0f) {
    return true;
  }
  LOG->Warn(
      "SRC_AUDIT_FIX SRC-588 SRC-597: skipped %s %s timing segment with "
      "non-positive %s %.6f.",
      format, segment, valueName, value);
  return false;
}

static bool ShouldWriteTimingSegment(
    const TimingSegment* seg, TimingSegmentType type, const char* format) {
  if (seg == nullptr ||
      !IsValidTimingRowForWrite(
          seg->GetRow(), format, TimingSegmentTypeToString(type).c_str())) {
    return false;
  }

  switch (type) {
    case SEGMENT_BPM:
      return IsPositiveTimingValueForWrite(
          ToBPM(seg)->GetBPM(), format, "BPM", "bpm");
    case SEGMENT_STOP:
      return IsPositiveTimingValueForWrite(
          ToStop(seg)->GetPause(), format, "STOP", "pause");
    case SEGMENT_DELAY:
      return IsPositiveTimingValueForWrite(
          ToDelay(seg)->GetPause(), format, "DELAY", "pause");
    case SEGMENT_WARP:
      return IsPositiveTimingValueForWrite(
          ToWarp(seg)->GetLength(), format, "WARP", "length");
    case SEGMENT_FAKE:
      return IsPositiveTimingValueForWrite(
          ToFake(seg)->GetLength(), format, "FAKE", "length");
    case SEGMENT_SPEED:
      return IsFiniteTimingValueForWrite(
                 ToSpeed(seg)->GetRatio(), format, "SPEED", "ratio") &&
             IsFiniteTimingValueForWrite(
                 ToSpeed(seg)->GetDelay(), format, "SPEED", "delay");
    case SEGMENT_SCROLL:
      return IsFiniteTimingValueForWrite(
          ToScroll(seg)->GetRatio(), format, "SCROLL", "ratio");
    case SEGMENT_TIME_SIG:
      if (ToTimeSignature(seg)->GetNum() > 0 &&
          ToTimeSignature(seg)->GetDen() > 0) {
        return true;
      }
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-588 SRC-597: skipped %s TIMESIGNATURES timing "
          "segment with invalid %i/%i.",
          format, ToTimeSignature(seg)->GetNum(), ToTimeSignature(seg)->GetDen());
      return false;
    case SEGMENT_TICKCOUNT:
      if (ToTickcount(seg)->GetTicks() > 0) {
        return true;
      }
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-588 SRC-597: skipped %s TICKCOUNTS timing "
          "segment with invalid tickcount %i.",
          format, ToTickcount(seg)->GetTicks());
      return false;
    case SEGMENT_COMBO:
      if (ToCombo(seg)->GetCombo() > 0 && ToCombo(seg)->GetMissCombo() > 0) {
        return true;
      }
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-588 SRC-597: skipped %s COMBOS timing segment "
          "with invalid combo %i/%i.",
          format, ToCombo(seg)->GetCombo(), ToCombo(seg)->GetMissCombo());
      return false;
    default:
      return true;
  }
}

static std::vector<std::string> GetTimingVectorForWrite(
    const TimingData& timing, TimingSegmentType type, int dec) {
  const std::vector<TimingSegment*>& segs = timing.GetTimingSegments(type);
  std::vector<std::string> out;
  if (type == SEGMENT_LABEL) {
    for (TimingSegment* seg : segs) {
      const LabelSegment* label = ToLabel(seg);
      if (!label->GetLabel().empty() &&
          ShouldWriteTimingSegment(label, SEGMENT_LABEL, "SSC")) {
        out.push_back(ssprintf(
            "%.6f=%s", label->GetBeat(),
            SanitizeSSCLabelForWrite(label->GetLabel()).c_str()));
      }
    }
    if (out.empty()) {
      out.push_back("0.000000=Song Start");
    }
    return out;
  }

  for (TimingSegment* seg : segs) {
    if (ShouldWriteTimingSegment(seg, type, "SSC")) {
      out.push_back(seg->ToString(dec));
    }
  }

  if (!out.empty()) {
    return out;
  }

  switch (type) {
    case SEGMENT_BPM:
      LOG->Warn(
          "SRC_AUDIT_FIX: SSC writer provided fallback BPM because TimingData "
          "had no BPM segments.");
      out.push_back(BPMSegment(0, 60).ToString(dec));
      break;
    case SEGMENT_TIME_SIG:
      LOG->Warn(
          "SRC_AUDIT_FIX: SSC writer provided fallback time signature because "
          "TimingData had none.");
      out.push_back(TimeSignatureSegment(0).ToString(dec));
      break;
    case SEGMENT_TICKCOUNT:
      LOG->Warn(
          "SRC_AUDIT_FIX: SSC writer provided fallback tickcount because "
          "TimingData had none.");
      out.push_back(TickcountSegment(0).ToString(dec));
      break;
    case SEGMENT_COMBO:
      LOG->Warn(
          "SRC_AUDIT_FIX: SSC writer provided fallback combo because TimingData "
          "had none.");
      out.push_back(ComboSegment(0).ToString(dec));
      break;
    case SEGMENT_SPEED:
      out.push_back(SpeedSegment(0).ToString(dec));
      break;
    case SEGMENT_SCROLL:
      out.push_back(ScrollSegment(0).ToString(dec));
      break;
    default:
      break;
  }
  return out;
}
}  // namespace

/**
 * @brief Turn a vector of lines into a single line joined by newline
 * characters.
 * @param lines the list of lines to join.
 * @return the joined lines. */
static std::string JoinLineList(std::vector<std::string>& lines) {
  for (unsigned i = 0; i < lines.size(); ++i) {
    TrimRight(lines[i]);
  }

  // Skip leading blanks.
  unsigned j = 0;
  while (j < lines.size() && lines[j].empty()) {
    ++j;
  }

  return join("\r\n", lines.begin() + j, lines.end());
}

// A utility class to write timing tags more easily!
struct TimingTagWriter {
  std::vector<std::string>* m_pvsLines;
  std::string m_sNext;

  TimingTagWriter(std::vector<std::string>* pvsLines) : m_pvsLines(pvsLines) {}

  void Write(const int row, const char* value) {
    m_pvsLines->push_back(
        m_sNext + ssprintf("%.6f=%s", NoteRowToBeat(row), value));
    m_sNext = ",";
  }

  void Write(const int row, const float value) {
    Write(row, ssprintf("%.6f", value).c_str());
  }
  void Write(const int row, const int value) {
    Write(row, ssprintf("%d", value).c_str());
  }
  void Write(const int row, const int a, const int b) {
    Write(row, ssprintf("%d=%d", a, b).c_str());
  }
  void Write(const int row, const float a, const float b) {
    Write(row, ssprintf("%.6f=%.6f", a, b).c_str());
  }
  void Write(
      const int row, const float a, const float b, const unsigned short c) {
    Write(row, ssprintf("%.6f=%.6f=%hd", a, b, c).c_str());
  }
  void WriteLabel(const int row, const std::string& value) {
    Write(row, SanitizeSSCLabelForWrite(value).c_str());
  }

  void Init(const std::string sTag) { m_sNext = "#" + sTag + ":"; }
  void Finish() {
    m_pvsLines->push_back((m_sNext != "," ? m_sNext : std::string("")) + ";");
  }
};

static void GetTimingTags(
    std::vector<std::string>& lines, const TimingData& timing,
    bool bIsSong = false) {
  TimingTagWriter w(&lines);

  // timing.TidyUpData(); // UGLY: done via const_cast. do we really -need- this
  // here?
  unsigned i = 0;

  w.Init("BPMS");
  const std::vector<TimingSegment*>& bpms =
      timing.GetTimingSegments(SEGMENT_BPM);
  if (bpms.empty()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SSC step timing writer provided fallback BPM because "
        "TimingData had no BPM segments.");
    BPMSegment bs(0, 60);
    w.Write(bs.GetRow(), bs.GetBPM());
  }
  for (; i < bpms.size(); i++) {
    const BPMSegment* bs = ToBPM(bpms[i]);
    if (!ShouldWriteTimingSegment(bs, SEGMENT_BPM, "SSC step")) {
      continue;
    }
    w.Write(bs->GetRow(), bs->GetBPM());
  }
  w.Finish();

  w.Init("STOPS");
  const std::vector<TimingSegment*>& stops =
      timing.GetTimingSegments(SEGMENT_STOP);
  for (i = 0; i < stops.size(); i++) {
    const StopSegment* ss = ToStop(stops[i]);
    if (!ShouldWriteTimingSegment(ss, SEGMENT_STOP, "SSC step")) {
      continue;
    }
    w.Write(ss->GetRow(), ss->GetPause());
  }
  w.Finish();

  w.Init("DELAYS");
  const std::vector<TimingSegment*>& delays =
      timing.GetTimingSegments(SEGMENT_DELAY);
  for (i = 0; i < delays.size(); i++) {
    const DelaySegment* ss = ToDelay(delays[i]);
    if (!ShouldWriteTimingSegment(ss, SEGMENT_DELAY, "SSC step")) {
      continue;
    }
    w.Write(ss->GetRow(), ss->GetPause());
  }
  w.Finish();

  w.Init("WARPS");
  const std::vector<TimingSegment*>& warps =
      timing.GetTimingSegments(SEGMENT_WARP);
  for (i = 0; i < warps.size(); i++) {
    const WarpSegment* ws = ToWarp(warps[i]);
    if (!ShouldWriteTimingSegment(ws, SEGMENT_WARP, "SSC step")) {
      continue;
    }
    w.Write(ws->GetRow(), ws->GetLength());
  }
  w.Finish();

  const std::vector<TimingSegment*>& tSigs =
      timing.GetTimingSegments(SEGMENT_TIME_SIG);
  w.Init("TIMESIGNATURES");
  if (tSigs.empty()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SSC step timing writer provided fallback time "
        "signature because TimingData had none.");
    TimeSignatureSegment ts(0);
    w.Write(ts.GetRow(), ts.GetNum(), ts.GetDen());
  }
  for (i = 0; i < tSigs.size(); i++) {
    const TimeSignatureSegment* ts = ToTimeSignature(tSigs[i]);
    if (!ShouldWriteTimingSegment(ts, SEGMENT_TIME_SIG, "SSC step")) {
      continue;
    }
    w.Write(ts->GetRow(), ts->GetNum(), ts->GetDen());
  }
  w.Finish();

  const std::vector<TimingSegment*>& ticks =
      timing.GetTimingSegments(SEGMENT_TICKCOUNT);
  w.Init("TICKCOUNTS");
  if (ticks.empty()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SSC step timing writer provided fallback tickcount "
        "because TimingData had none.");
    TickcountSegment ts(0);
    w.Write(ts.GetRow(), ts.GetTicks());
  }
  for (i = 0; i < ticks.size(); i++) {
    const TickcountSegment* ts = ToTickcount(ticks[i]);
    if (!ShouldWriteTimingSegment(ts, SEGMENT_TICKCOUNT, "SSC step")) {
      continue;
    }
    w.Write(ts->GetRow(), ts->GetTicks());
  }
  w.Finish();

  const std::vector<TimingSegment*>& combos =
      timing.GetTimingSegments(SEGMENT_COMBO);
  w.Init("COMBOS");
  if (combos.empty()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SSC step timing writer provided fallback combo because "
        "TimingData had none.");
    ComboSegment cs(0);
    w.Write(cs.GetRow(), cs.GetCombo());
  }
  for (i = 0; i < combos.size(); i++) {
    const ComboSegment* cs = ToCombo(combos[i]);
    if (!ShouldWriteTimingSegment(cs, SEGMENT_COMBO, "SSC step")) {
      continue;
    }
    if (cs->GetCombo() == cs->GetMissCombo()) {
      w.Write(cs->GetRow(), cs->GetCombo());
    } else {
      w.Write(cs->GetRow(), cs->GetCombo(), cs->GetMissCombo());
    }
  }
  w.Finish();

  // Song Timing should only have the initial value.
  const std::vector<TimingSegment*>& speeds =
      timing.GetTimingSegments(SEGMENT_SPEED);
  w.Init("SPEEDS");
  for (i = 0; i < speeds.size(); i++) {
    SpeedSegment* ss = ToSpeed(speeds[i]);
    if (!ShouldWriteTimingSegment(ss, SEGMENT_SPEED, "SSC step")) {
      continue;
    }
    w.Write(ss->GetRow(), ss->GetRatio(), ss->GetDelay(), ss->GetUnit());
  }
  w.Finish();

  w.Init("SCROLLS");
  const std::vector<TimingSegment*>& scrolls =
      timing.GetTimingSegments(SEGMENT_SCROLL);
  for (i = 0; i < scrolls.size(); i++) {
    ScrollSegment* ss = ToScroll(scrolls[i]);
    if (!ShouldWriteTimingSegment(ss, SEGMENT_SCROLL, "SSC step")) {
      continue;
    }
    w.Write(ss->GetRow(), ss->GetRatio());
  }
  w.Finish();

  if (!bIsSong) {
    const std::vector<TimingSegment*>& fakes =
        timing.GetTimingSegments(SEGMENT_FAKE);
    w.Init("FAKES");
    for (i = 0; i < fakes.size(); i++) {
      FakeSegment* fs = ToFake(fakes[i]);
      if (!ShouldWriteTimingSegment(fs, SEGMENT_FAKE, "SSC step")) {
        continue;
      }
      w.Write(fs->GetRow(), fs->GetLength());
    }
    w.Finish();
  }

  w.Init("LABELS");
  const std::vector<TimingSegment*>& labels =
      timing.GetTimingSegments(SEGMENT_LABEL);
  for (i = 0; i < labels.size(); i++) {
    LabelSegment* ls = static_cast<LabelSegment*>(labels[i]);
    if (!ls->GetLabel().empty() &&
        ShouldWriteTimingSegment(ls, SEGMENT_LABEL, "SSC step")) {
      w.WriteLabel(ls->GetRow(), ls->GetLabel());
    }
  }
  w.Finish();
}

static void WriteTimingTags(
    CheckedFileWriter& f, const TimingData& timing, bool bIsSong = false) {
  f.PutLine(ssprintf(
      "#BPMS:%s;",
      join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_BPM, 6)).c_str()));
  f.PutLine(ssprintf(
      "#STOPS:%s;",
      join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_STOP, 6))
          .c_str()));
  f.PutLine(ssprintf(
      "#DELAYS:%s;",
      join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_DELAY, 6))
          .c_str()));
  f.PutLine(ssprintf(
      "#WARPS:%s;",
      join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_WARP, 6))
          .c_str()));
  f.PutLine(ssprintf(
      "#TIMESIGNATURES:%s;",
      join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_TIME_SIG, 6))
          .c_str()));
  f.PutLine(ssprintf(
      "#TICKCOUNTS:%s;",
      join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_TICKCOUNT, 6))
          .c_str()));
  f.PutLine(ssprintf(
      "#COMBOS:%s;",
      join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_COMBO, 6)).c_str()));
  f.PutLine(ssprintf(
      "#SPEEDS:%s;",
      join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_SPEED, 6)).c_str()));
  f.PutLine(ssprintf(
      "#SCROLLS:%s;",
      join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_SCROLL, 6))
          .c_str()));
  if (!bIsSong) {
    f.PutLine(ssprintf(
        "#FAKES:%s;",
        join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_FAKE, 6))
            .c_str()));
  }
  f.PutLine(ssprintf(
      "#LABELS:%s;",
      join(",\r\n", GetTimingVectorForWrite(timing, SEGMENT_LABEL, 6)).c_str()));
}

/**
 * @brief Write out the common tags for .SSC files.
 * @param f the file in question.
 * @param out the Song in question. */
static bool WriteGlobalTags(CheckedFileWriter& f, const Song& out) {
  f.PutLine(ssprintf("#VERSION:%.2f;", STEPFILE_VERSION_NUMBER));
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
  f.PutLine(ssprintf("#ORIGIN:%s;", SmEscape(out.m_sOrigin).c_str()));
  f.PutLine(ssprintf("#CREDIT:%s;", SmEscape(out.m_sCredit).c_str()));
  f.PutLine(ssprintf("#BANNER:%s;", SmEscape(out.m_sBannerFile).c_str()));
  f.PutLine(
      ssprintf("#BACKGROUND:%s;", SmEscape(out.m_sBackgroundFile).c_str()));
  f.PutLine(
      ssprintf("#PREVIEWVID:%s;", SmEscape(out.m_sPreviewVidFile).c_str()));
  f.PutLine(ssprintf("#JACKET:%s;", SmEscape(out.m_sJacketFile).c_str()));
  f.PutLine(ssprintf("#CDIMAGE:%s;", SmEscape(out.m_sCDFile).c_str()));
  f.PutLine(ssprintf("#DISCIMAGE:%s;", SmEscape(out.m_sDiscFile).c_str()));
  f.PutLine(ssprintf("#LYRICSPATH:%s;", SmEscape(out.m_sLyricsFile).c_str()));
  f.PutLine(ssprintf("#CDTITLE:%s;", SmEscape(out.m_sCDTitleFile).c_str()));
  f.PutLine(ssprintf("#MUSIC:%s;", SmEscape(out.m_sMusicFile).c_str()));
  if (!out.m_PreviewFile.empty()) {
    f.PutLine(ssprintf("#PREVIEW:%s;", SmEscape(out.m_PreviewFile).c_str()));
  }

  {
    std::vector<std::string> vs = out.GetInstrumentTracksToVectorString();
    if (!vs.empty()) {
      std::string s = join(",", vs);
      f.PutLine("#INSTRUMENTTRACK:" + s + ";\n");
    }
  }
  f.PutLine(
      ssprintf("#OFFSET:%.6f;", out.m_SongTiming.m_fBeat0OffsetInSeconds));
  f.PutLine(ssprintf("#SAMPLESTART:%.6f;", out.m_fMusicSampleStartSeconds));
  f.PutLine(ssprintf("#SAMPLELENGTH:%.6f;", out.m_fMusicSampleLengthSeconds));

  f.Write("#SELECTABLE:");
  switch (out.m_SelectionDisplay) {
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX: Invalid SSC selection display %i while writing '%s'; "
          "falling back to YES.",
          out.m_SelectionDisplay, out.GetSongDir().c_str());
      f.Write("YES");
      break;
    case Song::SHOW_ALWAYS:
      f.Write("YES");
      break;
#if 0
		case Song::SHOW_NONSTOP:
			f.Write( "NONSTOP" );
			break;
#endif
    case Song::SHOW_NEVER:
      f.Write("NO");
      break;
  }
  f.PutLine(";");

  float displayBPMMin = 0.0f;
  float displayBPMMax = 0.0f;
  switch (SanitizeDisplayBPMForWrite(
      out, displayBPMMin, displayBPMMax, "SSC")) {
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

  WriteTimingTags(f, out.m_SongTiming, true);

  if (out.GetSpecifiedLastSecond() > 0) {
    f.PutLine(ssprintf("#LASTSECONDHINT:%.6f;", out.GetSpecifiedLastSecond()));
  }

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
     * See SSCLoader::TidyUpData. This tag will be removed on load. Add it
     * at a very high beat, so it won't cause problems if loaded in older
     * versions. */
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
    f.Write(SanitizeKeysoundForWrite(out.m_vsKeysoundFile[i], "SSC"));
    if (i != out.m_vsKeysoundFile.size() - 1) {
      f.Write(",");
    }
  }
  f.PutLine(";");

  // attacks section
  // f.PutLine( ssprintf("#ATTACKS:%s;", out.GetAttackString().c_str()) );
  f.PutLine("#ATTACKS:");
  for (unsigned j = 0; j < out.m_Attacks.size(); j++) {
    const Attack& a = out.m_Attacks[j];
    f.Write(ssprintf(
        "  TIME=%.2f:LEN=%.2f:MODS=%s", a.fStartSecond, a.fSecsRemaining,
        SanitizeAttackModifiersForWrite(a.sModifiers, "SSC song").c_str()));

    if (j + 1 < out.m_Attacks.size()) {
      f.Write(":");
    }
  }
  f.Write(";");
  f.PutLine("");
  return !f.Failed();
}

/**
 * @brief Retrieve the individual batches of NoteData.
 * @param song the Song in question.
 * @param in the Steps in question.
 * @param bSavingCache a flag to see if we're saving certain cache data.
 * @return the NoteData in std::string form. */
static std::string GetSSCNoteData(
    const Song& song, const Steps& in, bool bSavingCache) {
  std::vector<std::string> lines;

  lines.push_back("");
  // Escape to prevent some clown from making a comment of "\r\n;"
  lines.push_back(ssprintf(
      "//---------------%s - %s----------------",
      SanitizeStepMetadataForWrite(in.m_StepsTypeStr, "SSC comment").c_str(),
      SmEscape(in.GetDescription()).c_str()));
  lines.push_back("#NOTEDATA:;");  // our new separator.
  lines.push_back(
      ssprintf("#CHARTNAME:%s;", SmEscape(in.GetChartName()).c_str()));
  lines.push_back(ssprintf(
      "#STEPSTYPE:%s;",
      SanitizeStepMetadataForWrite(in.m_StepsTypeStr, "SSC STEPSTYPE")
          .c_str()));
  lines.push_back(
      ssprintf("#DESCRIPTION:%s;", SmEscape(in.GetDescription()).c_str()));
  lines.push_back(
      ssprintf("#CHARTSTYLE:%s;", SmEscape(in.GetChartStyle()).c_str()));
  lines.push_back(ssprintf(
      "#DIFFICULTY:%s;", DifficultyToString(in.GetDifficulty()).c_str()));
  lines.push_back(ssprintf("#METER:%d;", in.GetMeter()));

  const std::string& music = in.GetMusicFile();
  if (!music.empty()) {
    lines.push_back(ssprintf("#MUSIC:%s;", SmEscape(music).c_str()));
  }

  std::vector<std::string> asRadarValues;
  FOREACH_PlayerNumber(pn) {
    const RadarValues& rv = in.GetRadarValues(pn);
    FOREACH_ENUM(RadarCategory, rc)
    asRadarValues.push_back(ssprintf("%.6f", rv[rc]));
  }
  lines.push_back(
      ssprintf("#RADARVALUES:%s;", join(",", asRadarValues).c_str()));

  lines.push_back(ssprintf("#CREDIT:%s;", SmEscape(in.GetCredit()).c_str()));

  // If the Steps TimingData is not empty, then they have their own
  // timing.  Write out the corresponding tags.
  if (!in.m_Timing.empty()) {
    lines.push_back(
        ssprintf("#OFFSET:%.6f;", in.m_Timing.m_fBeat0OffsetInSeconds));
    GetTimingTags(lines, in.m_Timing);
  }

  // todo: get this to output similar to course mods -aj
  std::string songAttacks = song.GetAttackString();
  std::string stepAttacks = in.GetAttackString();
  if (stepAttacks != songAttacks) {
    // When loading, Steps::m_Attacks are set to the song attacks followed
    // by the step attacks. We need to omit the song attacks when saving.
    // Otherwise, a second copy of the song attacks would be added on the
    // next load.
    if (Left(stepAttacks, songAttacks.size() + 1) == songAttacks + ":") {
      stepAttacks =
          Right(stepAttacks, stepAttacks.size() - songAttacks.size() - 1);
    }
    lines.push_back(ssprintf(
        "#ATTACKS:%s;",
        SanitizeAttackStringForWrite(stepAttacks, "SSC steps").c_str()));
  }

  switch (in.GetDisplayBPM()) {
    case DISPLAY_BPM_ACTUAL:
      // write nothing
      break;
    case DISPLAY_BPM_SPECIFIED: {
      float small = in.GetMinBPM();
      float big = in.GetMaxBPM();
      if (small == big) {
        lines.push_back(ssprintf("#DISPLAYBPM:%.6f;", small));
      } else {
        lines.push_back(ssprintf("#DISPLAYBPM:%.6f:%.6f;", small, big));
      }
      break;
    }
    case DISPLAY_BPM_RANDOM:
      lines.push_back(ssprintf("#DISPLAYBPM:*;"));
      break;
    default:
      break;
  }
  if (bSavingCache) {
    lines.push_back(ssprintf("// step cache tags:"));

    std::vector<std::string> asTechCounts;
    FOREACH_PlayerNumber(pn) {
      const TechCounts& ts = in.GetTechCounts(pn);
      FOREACH_ENUM(TechCountsCategory, tc) {
        asTechCounts.push_back(ssprintf("%.6f", ts[tc]));
      }
    }
    lines.push_back(
        ssprintf("#TECHCOUNTS:%s;", join(",", asTechCounts).c_str()));

    // NpsPerMeasure and NotesPerMeasure are stored differently from Radar
    // Values and Tech Counts, because the number of measures is variable. For
    // charts that have different steps per player, each set of values is
    // separated with pipes "|". The vast majority of charts don't, so there's
    // no reason to store duplicated data.
    const std::vector<std::vector<float>>& allNpsPerMeasures =
        in.GetAllNpsPerMeasures();
    std::vector<std::string> npsPerMeasureStrings;
    npsPerMeasureStrings.reserve(allNpsPerMeasures.size());
    for (const std::vector<float>& npsPerMeasure : allNpsPerMeasures) {
      npsPerMeasureStrings.push_back(serialize(npsPerMeasure, ",", 3));
    }
    lines.push_back(ssprintf(
        "#NPSPERMEASURE:%s;", join("|", npsPerMeasureStrings).c_str()));

    const std::vector<std::vector<int>>& allNotesPerMeasures =
        in.GetAllNotesPerMeasures();
    std::vector<std::string> notesPerMeasureStrings;
    notesPerMeasureStrings.reserve(allNotesPerMeasures.size());
    for (const std::vector<int>& notesPerMeasure : allNotesPerMeasures) {
      notesPerMeasureStrings.push_back(serialize(notesPerMeasure, ","));
    }

    lines.push_back(ssprintf(
        "#NOTESPERMEASURE:%s;", join("|", notesPerMeasureStrings).c_str()));

    const std::vector<float>& peakNps = in.GetAllPeakNps();
    lines.push_back("#PEAKNPS:" + serialize(peakNps, "|", 3) + ";");

    const std::vector<NoteAnnotationCache>& noteAnnotations =
        in.GetNoteAnnotationCaches();
    std::vector<std::string> serializedAnnotations;
    serializedAnnotations.reserve(noteAnnotations.size());
    for (const NoteAnnotationCache& annotationCache : noteAnnotations) {
      serializedAnnotations.push_back(annotationCache.GetCompressed());
    }
    lines.push_back(ssprintf(
        "#NOTEANNOTATIONS:%s;", join("|", serializedAnnotations).c_str()));

    std::string GrooveStatsHash = in.GetGrooveStatsHash();
    lines.push_back(ssprintf("#GROOVESTATSHASH:%s;", GrooveStatsHash.c_str()));

    int GrooveStatsHashVersion = in.GetGrooveStatsHashVersion();
    lines.push_back(
        ssprintf("#GROOVESTATSHASHVERSION:%d;", GrooveStatsHashVersion));

    // NOTE(MV): #STEPFILENAME has to be at the end of the cache tags,

    // MV: #STEPFILENAME has to be at the end of the cache tags,
    // because it's used in SSCLoader::LoadFromSimfile to determine when
    // to switch the state back to GETTING_SONG_INFO, which means any tags
    // after it will be ignored.
    lines.push_back(
        ssprintf("#STEPFILENAME:%s;", SmEscape(in.GetFilename()).c_str()));
    lines.push_back(ssprintf("// end step cache tags"));
  } else {
    std::string sNoteData;
    in.GetSMNoteData(sNoteData);

    lines.push_back(song.m_vsKeysoundFile.empty() ? "#NOTES:" : "#NOTES2:");

    TrimLeft(sNoteData);
    split(sNoteData, "\n", lines, true);
    lines.push_back(";");
  }
  return JoinLineList(lines);
}

bool NotesWriterSSC::Write(
    std::string sPath, const Song& out,
    const std::vector<Steps*>& vpStepsToSave, bool bSavingCache) {
  for (const Steps* pSteps : vpStepsToSave) {
    if (pSteps == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-582: refusing to write SSC '%s' with null steps.",
          sPath.c_str());
      return false;
    }
  }
  if (!bSavingCache && vpStepsToSave.empty()) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-590: refusing to write playable SSC '%s' without "
        "steps.",
        sPath.c_str());
    return false;
  }

  int flags = RageFile::WRITE;

  /* If we're not saving cache, we're saving real data, so enable SLOW_FLUSH
   * to prevent data loss. If we're saving cache, this will slow things down
   * too much. */
  if (!bSavingCache) {
    flags |= RageFile::SLOW_FLUSH;
  }

  RageFile f;
  if (!f.Open(sPath, flags)) {
    LOG->UserLog(
        "Song file", sPath, "couldn't be opened for writing: %s",
        f.GetError().c_str());
    return false;
  }

  CheckedFileWriter writer(f, "NotesWriterSSC");
  if (!WriteGlobalTags(writer, out)) {
    return false;
  }

  if (bSavingCache) {
    writer.PutLine(ssprintf("// cache tags:"));
    writer.PutLine(
        ssprintf("#FIRSTSECOND:%.6f;", out.GetFirstSecondNoOffset()));
    writer.PutLine(ssprintf("#LASTSECOND:%.6f;", out.GetLastSecondNoOffset()));
    writer.PutLine(
        ssprintf("#SONGFILENAME:%s;", SmEscape(out.m_sSongFileName).c_str()));
    writer.PutLine(ssprintf("#HASMUSIC:%i;", out.m_bHasMusic));
    writer.PutLine(ssprintf("#HASBANNER:%i;", out.m_bHasBanner));
    writer.PutLine(ssprintf("#MUSICLENGTH:%.6f;", out.m_fMusicLengthSeconds));
    writer.PutLine(ssprintf("// end cache tags"));
  }

  // Save specified Steps to this file
  for (const Steps* pSteps : vpStepsToSave) {
    std::string sTag = GetSSCNoteData(out, *pSteps, bSavingCache);
    writer.PutLine(sTag);
  }
  if (writer.Flush() == -1) {
    return false;
  }

  return true;
}

void NotesWriterSSC::GetEditFileContents(
    const Song* pSong, const Steps* pSteps, std::string& sOut) {
  sOut = "";
  if (pSong == nullptr || pSteps == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-582: refusing to build SSC edit contents with null "
        "song/steps.");
    return;
  }
  std::string sDir = pSong->GetSongDir();

  // "Songs/foo/bar"; strip off "Songs/".
  std::vector<std::string> asParts;
  split(sDir, "/", asParts);
  if (asParts.size()) {
    sDir = join("/", asParts.begin() + 1, asParts.end());
  }
  sOut += ssprintf("#SONG:%s;\r\n", SmEscape(sDir).c_str());
  sOut += GetSSCNoteData(*pSong, *pSteps, false);
}

std::string NotesWriterSSC::GetEditFileName(
    const Song* pSong, const Steps* pSteps) {
  if (pSong == nullptr || pSteps == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-582: refusing to build SSC edit filename with null "
        "song/steps.");
    return std::string();
  }

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
    "NotesWriterSSC",
    "Error renaming file.  Destination file '%s' already exists.");
static LocalizedString ERROR_WRITING_FILE(
    "NotesWriterSSC", "Error writing file '%s'.");
bool NotesWriterSSC::WriteEditFileToMachine(
    const Song* pSong, Steps* pSteps, std::string& sErrorOut) {
  if (pSong == nullptr || pSteps == nullptr || PROFILEMAN == nullptr ||
      FILEMAN == nullptr) {
    sErrorOut =
        "Invalid song, steps, profile manager, or file manager for SSC edit "
        "save.";
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-582: refusing to write SSC edit with null "
        "song/steps/profile manager/file manager.");
    return false;
  }

  std::string sDir =
      PROFILEMAN->GetProfileDir(ProfileSlot_Machine) + EDIT_STEPS_SUBDIR;
  FILEMAN->CreateDir(sDir);

  std::string sPath = sDir + GetEditFileName(pSong, pSteps);
  if (sPath == sDir) {
    sErrorOut = "Could not derive SSC edit filename.";
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-582: refusing to write SSC edit without filename.");
    return false;
  }

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
          "SRC_AUDIT_FIX: Failed to remove old SSC edit file '%s' after "
          "writing '%s'.",
          pSteps->GetFilename().c_str(), sPath.c_str());
      return false;
    }
  }
  pSteps->SetFilename(sPath);
  pSteps->SetSavedToDisk(true);

  return true;
}

/*
 * (c) 2011 Jason Felds
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
