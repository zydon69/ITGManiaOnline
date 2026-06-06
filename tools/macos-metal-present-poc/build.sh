#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build

xcrun clang++ -std=c++17 -fobjc-arc \
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  -framework AppKit \
  -framework QuartzCore \
  -framework Metal \
  MetalPresentPOC.mm \
  -o build/metal_present_poc

echo "Built: $(pwd)/build/metal_present_poc"
