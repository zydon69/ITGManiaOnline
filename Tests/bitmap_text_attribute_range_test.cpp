#include "BitmapTextAttributeRange.h"

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

void Require(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "bitmap text attribute range: " << message << std::endl;
    std::exit(1);
  }
}

}  // namespace

int main() {
  using BitmapTextAttributeRange::Resolve;

  const auto firstLine = Resolve({5, 8}, 13, 0, 5);
  Require(firstLine.valid, "a first-line range must be valid");
  Require(firstLine.start == 0, "a first-line range must start at glyph zero");
  Require(firstLine.length == 5, "a first-line range must retain its length");

  const auto secondLine = Resolve({5, 8}, 13, 6, 8);
  Require(secondLine.valid, "a second-line range must be valid");
  Require(
      secondLine.start == 5,
      "the first newline must be excluded from the glyph offset");
  Require(
      secondLine.length == 8,
      "a complete second line must keep its last glyph");

  const auto thirdLine = Resolve({2, 3, 4}, 9, 7, 4);
  Require(thirdLine.valid, "a third-line range must be valid");
  Require(
      thirdLine.start == 5,
      "all preceding newlines must be excluded from the glyph offset");
  Require(
      thirdLine.length == 4,
      "a complete third line must keep its last glyph");

  const auto spanningLines = Resolve({2, 3, 4}, 9, 1, 8);
  Require(spanningLines.valid, "a multiline range must be valid");
  Require(spanningLines.start == 1, "a multiline range must retain its start");
  Require(
      spanningLines.length == 6,
      "embedded newlines must not count as printable glyphs");

  const auto openEnded = Resolve({2, 3}, 5, 3, -1);
  Require(openEnded.valid, "an open-ended range must be valid");
  Require(
      openEnded.start == 2,
      "an open-ended second-line range must exclude its preceding newline");
  Require(
      openEnded.length == -1,
      "an open-ended attribute must retain its sentinel length");

  const auto outOfRange = Resolve({2, 3}, 5, 7, 1);
  Require(!outOfRange.valid, "an out-of-range source offset must be rejected");

  std::cout << "bitmap text attribute range: ok" << std::endl;
  return 0;
}
