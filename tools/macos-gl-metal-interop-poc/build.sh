#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build

clang++ -std=c++17 -ObjC++ \
  -framework Foundation \
  -framework AppKit \
  -framework IOSurface \
  -framework Metal \
  -framework OpenGL \
  GLMetalInteropPOC.mm \
  -o build/gl_metal_interop_poc

echo "Built tools/macos-gl-metal-interop-poc/build/gl_metal_interop_poc"
