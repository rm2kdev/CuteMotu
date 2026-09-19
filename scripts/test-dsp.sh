#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer -Isrc/Core -Isrc/Control src/Core/MOTUProtocol.cpp src/Control/MOTUDSP.cpp tests/dsp_tests.cpp -o build/tests/dsp-tests
build/tests/dsp-tests
