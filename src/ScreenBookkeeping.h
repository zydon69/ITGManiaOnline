/* ScreenBookkeeping - Show coin drop stats. */

#ifndef ScreenBookkeeping_H
#define ScreenBookkeeping_H

#include <array>
#include <vector>

#include "BitmapText.h"
#include "ScreenWithMenuElements.h"

enum BookkeepingView {
  BookkeepingView_SongPlays,
  BookkeepingView_LastDays,
  BookkeepingView_LastWeeks,
  BookkeepingView_DayOfWeek,
  BookkeepingView_HourOfDay,
  NUM_BookkeepingView,
  BookkeepingView_Invalid,
};

class ScreenBookkeeping : public ScreenWithMenuElements {
 public:
  void Init() override;

  bool MenuLeft(const InputEventPlus& input) override;
  bool MenuRight(const InputEventPlus& input) override;
  bool MenuStart(const InputEventPlus& input) override;
  bool MenuBack(const InputEventPlus& input) override;
  bool MenuCoin(const InputEventPlus& input) override;

 private:
  static constexpr int NUM_BOOKKEEPING_COLS = 4;
  static_assert(NUM_BOOKKEEPING_COLS >= 4);

  void ClampViewIndex();
  bool CanNavigateViews(const InputEventPlus& input);
  bool CanLeaveScreen(const InputEventPlus& input);
  bool StartValidatedTransition(
      ScreenMessage smSendWhenDone, const std::string& targetScreen,
      const char* context);
  void ClearDataText();
  void SetDataText(size_t col, const std::string& text, float align);
  void SetTitleText(const std::string& text);
  void SetAllTimeText(const std::string& text);
  void UpdateView();

  int m_iViewIndex = 0;
  std::vector<BookkeepingView> m_vBookkeepingViews;

  BitmapText m_textAllTime;
  BitmapText m_textTitle;
  std::array<BitmapText, NUM_BOOKKEEPING_COLS> m_textData;
  bool m_bAllTimeLoaded = false;
  bool m_bTitleLoaded = false;
  std::array<bool, NUM_BOOKKEEPING_COLS> m_bDataLoaded{};
};

#endif

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
