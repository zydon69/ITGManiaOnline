#ifndef BITMAP_TEXT_ATTRIBUTE_RANGE_H
#define BITMAP_TEXT_ATTRIBUTE_RANGE_H

#include <algorithm>
#include <cstddef>
#include <vector>

namespace BitmapTextAttributeRange {

struct Resolved {
  bool valid{false};
  size_t start{0};
  int length{0};
  size_t sourceCharacters{0};
};

inline Resolved Resolve(const std::vector<size_t>& lineLengths,
                        size_t printableGlyphs,
                        size_t sourcePosition,
                        int requestedLength) {
  const size_t lineBreaks = lineLengths.empty() ? 0 : lineLengths.size() - 1;
  const size_t sourceCharacters = printableGlyphs + lineBreaks;
  if (sourcePosition > sourceCharacters) {
    return {false, 0, 0, sourceCharacters};
  }

  const auto SourcePositionToGlyphPosition =
      [&lineLengths, sourceCharacters, printableGlyphs](size_t position) {
        position = std::min(position, sourceCharacters);
        size_t sourceCursor = 0;
        size_t glyphCursor = 0;
        for (size_t lineIndex = 0; lineIndex < lineLengths.size();
             ++lineIndex) {
          const size_t lineLength = lineLengths[lineIndex];
          if (position <= sourceCursor + lineLength) {
            return std::min(printableGlyphs,
                            glyphCursor + (position - sourceCursor));
          }
          sourceCursor += lineLength;
          glyphCursor += lineLength;
          if (lineIndex + 1 < lineLengths.size()) {
            ++sourceCursor;
          }
        }
        return printableGlyphs;
      };

  const size_t start = SourcePositionToGlyphPosition(sourcePosition);
  if (requestedLength <= 0) {
    return {true, start, requestedLength, sourceCharacters};
  }

  const size_t clampedLength = std::min(
      static_cast<size_t>(requestedLength), sourceCharacters - sourcePosition);
  const size_t end =
      SourcePositionToGlyphPosition(sourcePosition + clampedLength);
  return {
      true,
      start,
      static_cast<int>(end - start),
      sourceCharacters,
  };
}

}  // namespace BitmapTextAttributeRange

#endif
