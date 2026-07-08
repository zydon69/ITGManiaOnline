#include "ColumnCues.h"

#include <vector>

#include "GameConstantsAndTypes.h"
#include "GameManager.h"
#include "GameState.h"
#include "NoteData.h"
#include "NoteDataUtil.h"
#include "NoteTypes.h"

namespace {
PlayerNumber SanitizePlayerNumber(PlayerNumber pn) {
  return pn >= 0 && pn < NUM_PLAYERS ? pn : PLAYER_1;
}

bool IsCoupleStepsType(StepsType stepsType) {
  return stepsType >= 0 && stepsType < NUM_StepsType &&
         GAMEMAN->GetStepsTypeInfo(stepsType).m_StepsTypeCategory ==
             StepsTypeCategory_Couple;
}

NoteData GetPlayerNoteData(
    const NoteData& in, PlayerNumber pn, StepsType stepsType) {
  pn = SanitizePlayerNumber(pn);

  if (in.IsComposite()) {
    std::vector<NoteData> parts;
    NoteDataUtil::SplitCompositeNoteData(in, parts);
    if (parts.size() > static_cast<size_t>(pn)) {
      return parts[pn];
    }
    if (!parts.empty()) {
      return parts[PLAYER_1];
    }
    return in;
  }

  if (IsCoupleStepsType(stepsType) && in.GetNumTracks() >= NUM_PLAYERS) {
    const int tracksPerPlayer = in.GetNumTracks() / NUM_PLAYERS;
    NoteData playerNoteData = in;
    if (pn == PLAYER_2) {
      NoteDataUtil::ShiftTracks(playerNoteData, tracksPerPlayer);
    }
    playerNoteData.SetNumTracks(tracksPerPlayer);
    return playerNoteData;
  }

  return in;
}

void CalculateColumnCuesOnePlayer(
    const NoteData& in, TimingData* timing, std::vector<ColumnCue>& out,
    float minDuration) {
  NoteData::all_tracks_const_iterator curr_note =
      in.GetTapNoteRangeAllTracks(0, MAX_NOTE_ROW);
  int curr_row = -1;

  std::vector<ColumnCue> allColumnCues;
  ColumnCue currentCue = ColumnCue();

  while (!curr_note.IsAtEnd()) {
    if (curr_note.Row() != curr_row) {
      if (currentCue.startTime != -1) {
        allColumnCues.push_back(currentCue);
      }
      currentCue = ColumnCue();
      currentCue.startTime =
          timing->GetElapsedTimeFromBeat(NoteRowToBeat(curr_note.Row()));
      curr_row = curr_note.Row();
    }

    if (curr_note->type == TapNoteType_Tap ||
        curr_note->type == TapNoteType_HoldHead ||
        curr_note->type == TapNoteType_Mine ||
        curr_note->type == TapNoteType_Lift) {
      currentCue.columns.push_back(
          ColumnCueColumn(curr_note.Track() + 1, curr_note->type));
    }

    ++curr_note;
  }

  // If there's a remaining columnCue from the last row, add it
  if (currentCue.startTime != -1) {
    allColumnCues.push_back(currentCue);
  }

  float previousCueTime = 0;
  out.clear();
  for (ColumnCue columnCue : allColumnCues) {
    float duration = columnCue.startTime - previousCueTime;
    if (duration > minDuration || previousCueTime == 0) {
      out.push_back(ColumnCue(previousCueTime, duration, columnCue.columns));
    }
    previousCueTime = columnCue.startTime;
  }
}
}

void ColumnCue::CalculateColumnCues(
    const NoteData& in, TimingData* timing, std::vector<ColumnCue>& out,
    PlayerNumber pn, float minDuration, StepsType stepsType) {
  const NoteData playerNoteData = GetPlayerNoteData(in, pn, stepsType);
  CalculateColumnCuesOnePlayer(playerNoteData, timing, out, minDuration);
}
