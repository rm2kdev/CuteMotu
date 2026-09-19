#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/tests
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -g -O1 -fsanitize=thread \
  -Isrc/Core -Isrc/Streaming src/Core/MOTUProtocol.cpp src/Streaming/MOTUStream.cpp tests/stream_tests.cpp \
  -o build/tests/stream-tests-tsan
build/tests/stream-tests-tsan
