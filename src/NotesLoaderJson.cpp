#include "NotesLoaderJson.h"

#include <string>
#include <vector>

#include "BackgroundUtil.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameManager.h"
#include "JsonUtil.h"
#include "NoteData.h"
#include "NoteTypes.h"
#include "PlayerNumber.h"
#include "RadarValues.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Song.h"
#include "StdString.h"
#include "Steps.h"
#include "TimingData.h"
#include "TimingSegments.h"
#include "json/json.h"

void NotesLoaderJson::GetApplicableFiles(
    const std::string& sPath, std::vector<std::string>& out) {
  GetDirListing(sPath + std::string("*.json"), out);
}

static void Deserialize(BPMSegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetBPM((float)root["BPM"].asDouble());
}

static void Deserialize(StopSegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetPause((float)root["Seconds"].asDouble());
}

static void Deserialize(DelaySegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetPause((float)root["Seconds"].asDouble());
}

static void Deserialize(TimeSignatureSegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetNum(root["Numerator"].asInt());
  seg.SetDen(root["Denominator"].asInt());
}

static void Deserialize(WarpSegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetLength((float)root["Length"].asDouble());
}

static void Deserialize(LabelSegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetLabel(root["Label"].asString());
}

static void Deserialize(TickcountSegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetTicks(root["Ticks"].asInt());
}

static void Deserialize(ComboSegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetCombo(root["Combo"].asInt());
  seg.SetMissCombo(root.isMember("MissCombo") ? root["MissCombo"].asInt()
                                              : root["Combo"].asInt());
}

static void Deserialize(SpeedSegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetRatio((float)root["Ratio"].asDouble());
  seg.SetDelay((float)root["Delay"].asDouble());
  seg.SetUnit(
      root["Unit"].asInt() == 0 ? SpeedSegment::UNIT_BEATS
                                : SpeedSegment::UNIT_SECONDS);
}

static void Deserialize(ScrollSegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetRatio((float)root["Ratio"].asDouble());
}

static void Deserialize(FakeSegment& seg, const Json::Value& root) {
  seg.SetBeat((float)root["Beat"].asDouble());
  seg.SetLength((float)root["Length"].asDouble());
}

template <class Segment>
static void DeserializeTimingSegmentArray(
    TimingData& td, const Json::Value& root, const char* key) {
  const Json::Value& segments = root[key];
  if (!segments.isArray()) {
    return;
  }
  for (unsigned i = 0; i < segments.size(); ++i) {
    Segment segment;
    Deserialize(segment, segments[i]);
    td.AddSegment(segment);
  }
}

static void Deserialize(TimingData& td, const Json::Value& root) {
  if (!root.isObject()) {
    LOG->Warn("SRC_AUDIT_FIX JSON TimingData is not an object; ignored.");
    return;
  }
  if (root.isMember("Offset")) {
    td.m_fBeat0OffsetInSeconds = (float)root["Offset"].asDouble();
  }
  DeserializeTimingSegmentArray<BPMSegment>(td, root, "BpmSegments");
  DeserializeTimingSegmentArray<StopSegment>(td, root, "StopSegments");
  DeserializeTimingSegmentArray<DelaySegment>(td, root, "DelaySegments");
  DeserializeTimingSegmentArray<TimeSignatureSegment>(
      td, root, "TimeSignatureSegments");
  DeserializeTimingSegmentArray<WarpSegment>(td, root, "WarpSegments");
  DeserializeTimingSegmentArray<LabelSegment>(td, root, "LabelSegments");
  DeserializeTimingSegmentArray<TickcountSegment>(
      td, root, "TickcountSegments");
  DeserializeTimingSegmentArray<ComboSegment>(td, root, "ComboSegments");
  DeserializeTimingSegmentArray<SpeedSegment>(td, root, "SpeedSegments");
  DeserializeTimingSegmentArray<ScrollSegment>(td, root, "ScrollSegments");
  DeserializeTimingSegmentArray<FakeSegment>(td, root, "FakeSegments");
}

static void Deserialize(LyricSegment& o, const Json::Value& root) {
  o.m_fStartTime = (float)root["StartTime"].asDouble();
  o.m_sLyric = root["Lyric"].asString();
  o.m_Color.FromString(root["Color"].asString());
}

static void Deserialize(BackgroundDef& o, const Json::Value& root) {
  o.m_sEffect = root["Effect"].asString();
  o.m_sFile1 = root["File1"].asString();
  o.m_sFile2 = root["File2"].asString();
  o.m_sColor1 = root["Color1"].asString();
}

static void Deserialize(BackgroundChange& o, const Json::Value& root) {
  Deserialize(o.m_def, root["Def"]);
  o.m_fStartBeat = (float)root["StartBeat"].asDouble();
  o.m_fRate = (float)root["Rate"].asDouble();
  o.m_sTransition = root["Transition"].asString();
}

static void Deserialize(TapNote& o, const Json::Value& root) {
  if (root.isInt()) {
    o.type = (TapNoteType)root.asInt();
    return;
  }

  if (!root.isObject()) {
    return;
  }

  // NotesWriterJson omits Type for normal taps, so an object without Type
  // still represents a tap rather than an empty note.
  o.type = root.isMember("Type") ? (TapNoteType)root["Type"].asInt()
                                 : TapNoteType_Tap;
  if (o.type < TapNoteType_Empty || o.type >= NUM_TapNoteType) {
    LOG->Warn("SRC_AUDIT_FIX JSON note has invalid TapNoteType %i; treating "
              "it as empty.",
              (int)o.type);
    o = TAP_EMPTY;
    return;
  }

  if (root.isMember("SubType")) {
    o.subType = (TapNoteSubType)root["SubType"].asInt();
  } else if (o.type == TapNoteType_HoldHead) {
    o.subType = TapNoteSubType_Hold;
  }
  if (root.isMember("AttackModifiers")) {
    o.sAttackModifiers = root["AttackModifiers"].asString();
  }
  if (root.isMember("AttackDurationSeconds")) {
    o.fAttackDurationSeconds = (float)root["AttackDurationSeconds"].asDouble();
  }
  if (root.isMember("KeysoundIndex")) {
    o.iKeysoundIndex = root["KeysoundIndex"].asInt();
  }
  if (root.isMember("Duration")) {
    o.iDuration = root["Duration"].asInt();
  }
  if (root.isMember("PlayerNumber")) {
    o.pn = (PlayerNumber)root["PlayerNumber"].asInt();
  }
}

static bool Deserialize(StepsType st, NoteData& nd, const Json::Value& root) {
  if (st == StepsType_Invalid) {
    LOG->Warn("SRC_AUDIT_FIX JSON chart has invalid StepsType; notes ignored.");
    return false;
  }

  const int iTracks = GAMEMAN->GetStepsTypeInfo(st).iNumTracks;
  nd.SetNumTracks(iTracks);
  if (!root.isArray()) {
    LOG->Warn(
        "SRC_AUDIT_FIX JSON chart NoteData is not an array; notes ignored.");
    return false;
  }

  for (unsigned i = 0; i < root.size(); i++) {
    Json::Value root2 = root[i];
    if (!root2.isArray() || root2.size() < 3) {
      LOG->Warn(
          "SRC_AUDIT_FIX JSON chart note entry %u is malformed; skipped.", i);
      continue;
    }
    float fBeat = (float)root2[(unsigned)0].asDouble();
    int iRow = BeatToNoteRow(fBeat);
    int iTrack = root2[1].asInt();
    if (iTrack < 0 || iTrack >= iTracks) {
      LOG->Warn(
          "SRC_AUDIT_FIX JSON chart note entry %u has invalid track %i for %i "
          "tracks; "
          "skipped.",
          i, iTrack, iTracks);
      continue;
    }
    const Json::Value& root3 = root2[2];
    TapNote tn;
    Deserialize(tn, root3);
    nd.SetTapNote(iTrack, iRow, tn);
  }
  return true;
}

static void Deserialize(RadarValues& o, const Json::Value& root) {
  FOREACH_ENUM(RadarCategory, rc) {
    o[rc] = (float)root[RadarCategoryToString(rc)].asDouble();
  }
}

static void DeserializeRadarValuesByPlayer(
    RadarValues (&rv)[NUM_PLAYERS], const Json::Value& root) {
  if (root.isArray()) {
    FOREACH_PlayerNumber(pn) {
      if ((unsigned)pn < root.size()) {
        Deserialize(rv[pn], root[pn]);
      }
    }
    return;
  }

  // Backward compatibility for JSON written before per-player radar values.
  FOREACH_PlayerNumber(pn) { Deserialize(rv[pn], root); }
}

static DisplayBPM DeserializeDisplayBPM(const Json::Value& root) {
  const std::string sDisplayBPMType = root.asString();
  if (EqualsNoCase(sDisplayBPMType, DisplayBPMToString(DISPLAY_BPM_ACTUAL))) {
    return DISPLAY_BPM_ACTUAL;
  }
  if (EqualsNoCase(
          sDisplayBPMType, DisplayBPMToString(DISPLAY_BPM_SPECIFIED))) {
    return DISPLAY_BPM_SPECIFIED;
  }
  if (EqualsNoCase(sDisplayBPMType, DisplayBPMToString(DISPLAY_BPM_RANDOM)) ||
      sDisplayBPMType == "*") {
    return DISPLAY_BPM_RANDOM;
  }
  LOG->Warn(
      "SRC_AUDIT_FIX JSON has unknown DisplayBpmType '%s'; using Actual.",
      sDisplayBPMType.c_str());
  return DISPLAY_BPM_ACTUAL;
}

static bool Deserialize(Steps& o, const Json::Value& root) {
  o.m_StepsType = GAMEMAN->StringToStepsType(root["StepsType"].asString());
  if (o.m_StepsType == StepsType_Invalid) {
    LOG->Warn(
        "SRC_AUDIT_FIX JSON chart has unknown StepsType '%s'; chart ignored.",
        root["StepsType"].asString().c_str());
    return false;
  }
  o.m_StepsTypeStr = GAMEMAN->GetStepsTypeInfo(o.m_StepsType).szName;

  o.Decompress();

  NoteData nd;
  if (!Deserialize(o.m_StepsType, nd, root["NoteData"])) {
    return false;
  }
  o.SetNoteData(nd);
  // o.SetHash( root["Hash"].asInt() );
  o.SetDescription(root["Description"].asString());
  o.SetDifficulty(StringToDifficulty(root["Difficulty"].asString()));
  o.SetMeter(root["Meter"].asInt());

  RadarValues rv[NUM_PLAYERS];
  DeserializeRadarValuesByPlayer(
      rv, root.isMember("RadarValuesByPlayer") ? root["RadarValuesByPlayer"]
                                               : root["RadarValues"]);
  o.SetRadarValues(rv);
  if (root.isMember("DisplayBpmType")) {
    o.SetDisplayBPM(DeserializeDisplayBPM(root["DisplayBpmType"]));
    if (o.GetDisplayBPM() == DISPLAY_BPM_SPECIFIED) {
      o.SetMinBPM((float)root["SpecifiedBpmMin"].asDouble());
      o.SetMaxBPM((float)root["SpecifiedBpmMax"].asDouble());
    }
  }
  if (root.isMember("TimingData")) {
    Deserialize(o.m_Timing, root["TimingData"]);
  }
  return true;
}

static bool Deserialize(Song& out, const Json::Value& root) {
  if (!root.isObject()) {
    LOG->Warn("SRC_AUDIT_FIX JSON song root is not an object; load rejected.");
    return false;
  }
  out.SetSongDir(root["SongDir"].asString());
  out.m_sGroupName = root["GroupName"].asString();
  out.m_sMainTitle = root["Title"].asString();
  out.m_sSubTitle = root["SubTitle"].asString();
  out.m_sArtist = root["Artist"].asString();
  out.m_sMainTitleTranslit = root["TitleTranslit"].asString();
  out.m_sSubTitleTranslit = root["SubTitleTranslit"].asString();
  out.m_sGenre = root["Genre"].asString();
  out.m_sCredit = root["Credit"].asString();
  out.m_sBannerFile = root["Banner"].asString();
  out.m_sBackgroundFile = root["Background"].asString();
  out.m_sLyricsFile = root["LyricsFile"].asString();
  out.m_sCDTitleFile = root["CDTitle"].asString();
  out.m_sMusicFile = root["Music"].asString();
  out.m_SongTiming.m_fBeat0OffsetInSeconds = (float)root["Offset"].asDouble();
  out.m_fMusicSampleStartSeconds = (float)root["SampleStart"].asDouble();
  out.m_fMusicSampleLengthSeconds = (float)root["SampleLength"].asDouble();
  std::string sSelectable = root["Selectable"].asString();
  if (EqualsNoCase(sSelectable, "YES")) {
    out.m_SelectionDisplay = out.SHOW_ALWAYS;
  } else if (EqualsNoCase(sSelectable, "NO")) {
    out.m_SelectionDisplay = out.SHOW_NEVER;
  }

  out.m_sSongFileName = root["SongFileName"].asString();
  out.m_bHasMusic = root["HasMusic"].asBool();
  out.m_bHasBanner = root["HasBanner"].asBool();
  out.m_fMusicLengthSeconds = (float)root["MusicLengthSeconds"].asDouble();

  out.m_DisplayBPMType = DeserializeDisplayBPM(root["DisplayBpmType"]);

  if (out.m_DisplayBPMType == DISPLAY_BPM_SPECIFIED) {
    out.m_fSpecifiedBPMMin = (float)root["SpecifiedBpmMin"].asDouble();
    out.m_fSpecifiedBPMMax = (float)root["SpecifiedBpmMax"].asDouble();
  }

  Deserialize(out.m_SongTiming, root["TimingData"]);
  JsonUtil::DeserializeVectorObjects(
      out.m_LyricSegments, Deserialize, root["LyricSegments"]);

  {
    const Json::Value& root2 = root["BackgroundChanges"];
    FOREACH_BackgroundLayer(bl) {
      const Json::Value& root3 = root2[bl];
      std::vector<BackgroundChange>& vBgc = out.GetBackgroundChanges(bl);
      JsonUtil::DeserializeVectorObjects(vBgc, Deserialize, root3);
    }
  }

  {
    std::vector<BackgroundChange>& vBgc = out.GetForegroundChanges();
    JsonUtil::DeserializeVectorObjects(
        vBgc, Deserialize, root["ForegroundChanges"]);
  }

  out.m_vsKeysoundFile = JsonUtil::DeserializeArrayStrings(root["KeySounds"]);

  {
    const Json::Value& charts = root["Charts"];
    for (unsigned i = 0; i < charts.size(); ++i) {
      Steps* step = new Steps(&out);
      if (Deserialize(*step, charts[i])) {
        out.AddSteps(step);
      } else {
        RageUtil::SafeDelete(step);
      }
    }
  }
  if (out.GetAllSteps().empty() && root.isMember("Charts")) {
    LOG->Warn("SRC_AUDIT_FIX JSON song has no loadable charts; load rejected.");
    return false;
  }
  return true;
}

bool NotesLoaderJson::LoadFromJsonFile(const std::string& sPath, Song& out) {
  Json::Value root;
  if (!JsonUtil::LoadFromFileShowErrors(root, sPath)) {
    return false;
  }

  return Deserialize(out, root);
}

bool NotesLoaderJson::LoadFromDir(const std::string& sPath, Song& out) {
  return LoadFromJsonFile(sPath, out);
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
