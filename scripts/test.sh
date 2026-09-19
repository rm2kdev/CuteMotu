#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p build/tests
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -g -O1 \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Isrc/Core src/Core/MOTUProtocol.cpp tests/protocol_tests.cpp \
  -o build/tests/protocol-tests
build/tests/protocol-tests tests/fixtures/828x-config.hex
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -g -O1 \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Isrc/Core -Isrc/Streaming src/Core/MOTUProtocol.cpp src/Streaming/MOTUStream.cpp tests/stream_tests.cpp \
  -o build/tests/stream-tests
build/tests/stream-tests
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -g -O1 \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Isrc/Core tests/shutdown_tests.cpp -o build/tests/shutdown-tests
build/tests/shutdown-tests

./scripts/test-dsp.sh
