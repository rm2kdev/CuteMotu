#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p build/tests
for sanitizer in address,undefined thread; do
  suffix="${sanitizer//,/}"
  xcrun clang++ -std=c++17 -Wall -Wextra -Werror -g -O1 -fsanitize="$sanitizer" -Isrc/Streaming tests/volume_tests.cpp -o "build/tests/volume-$suffix-tests"
  "build/tests/volume-$suffix-tests"
done
