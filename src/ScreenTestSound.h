#ifndef SCREEN_TEST_SOUND_H
#define SCREEN_TEST_SOUND_H

#include <array>
#include <memory>
#include <vector>

#include "BitmapText.h"
#include "RageSound.h"
#include "Screen.h"

/** @brief The number of sounds allowed for testing. */
const int nsounds = 5;

class ScreenTestSound : public Screen {
 public:
  void Init() override;
  ~ScreenTestSound() override;

  bool Input(const InputEventPlus& input) override;
  bool MenuBack(const InputEventPlus& input) override;

  void Update(float f) override;

 private:
  static constexpr int NUM_SOUNDS = 5;
  struct Sound {
    RageSound s;
    BitmapText txt;
  };
  void UpdateText(size_t n);
  bool IsValidSoundIndex(int n) const;

  std::array<Sound, NUM_SOUNDS> m_sounds;
  std::array<std::vector<std::unique_ptr<RageSound>>, NUM_SOUNDS> m_soundCopies;
  BitmapText m_help;
  std::array<bool, NUM_SOUNDS> m_textReady{};
  bool m_helpReady = false;

  int m_selected = 0;
};

#endif

/**
 * @file
 * @author Glenn Maynard (c) 2003
 * @section LICENSE
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
