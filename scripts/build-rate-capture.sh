#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -O2 \
  -Isrc/Core -Isrc/Streaming src/Probe/rate-capture.mm \
  src/Core/MOTUProtocol.cpp src/Streaming/MOTUStream.cpp \
  -framework Foundation -framework IOKit -framework IOUSBHost \
  -o build/motu828x-rate-capture
